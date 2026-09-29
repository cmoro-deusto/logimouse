"""Query a Logi Bolt receiver and its paired HID++ 2.0 devices through /dev/hidraw."""

import argparse
import contextlib
import fcntl
import glob
import itertools
import json
import os
import re
import select
import sys
import time

SHORT_REPORT = 0x10
LONG_REPORT = 0x11
SHORT_LEN = 7
LONG_LEN = 20
SOFTWARE_ID = 0x0A
# HID++ 2.0 replies echo only the feature index, function and software ID. Every
# feature lookup is the same request (index 0, function 0) whatever feature it asks
# for, so a reply that arrives after its request timed out would answer the next
# lookup with the wrong index. Each request therefore takes the next software ID in
# turn, and a late reply carries an old one. 0 is reserved for notifications and 1 is
# the kernel's.
SOFTWARE_IDS = range(2, 16)
ERROR_HIDPP10 = 0x8F
ERROR_HIDPP20 = 0xFF
RECEIVER_INDEX = 0xFF
# A device connected directly (USB cable, or its own receiver handled by the kernel)
# answers HID++ 2.0 at index 0xFF, the index a receiver itself uses.
DIRECT_INDEX = 0xFF
MAX_SLOTS = 6
TIMEOUT_S = 2.0
# The first request to an idle wireless device wakes its radio: measured at 0.7-1.0 s
# for an MX Anywhere 3S on a Bolt receiver, against about 20 ms once it is awake. The
# ping that opens every exchange with a device gets this much longer.
WAKE_TIMEOUT_S = 2.5
# A receiver answers "busy" while it is still handling another request (another
# process's, for instance); such a request is retried after a short pause.
ERROR_BUSY = 0x07
BUSY_RETRIES = 5
BUSY_DELAY_S = 0.05

FEATURE_FEATURE_SET = 0x0001
FEATURE_FW_VERSION = 0x0003
FEATURE_NAME = 0x0005
FEATURE_FRIENDLY_NAME = 0x0007
FEATURE_BATTERY_STATUS = 0x1000
FEATURE_UNIFIED_BATTERY = 0x1004
FEATURE_CHANGE_HOST = 0x1814
FEATURE_HOSTS_INFO = 0x1815
FEATURE_REPROG_CONTROLS = 0x1B04
FEATURE_WIRELESS_STATUS = 0x1D4B
FEATURE_SMART_SHIFT = 0x2111
FEATURE_HIRES_WHEEL = 0x2121
FEATURE_ADJUSTABLE_DPI = 0x2201
FEATURE_REPORT_RATE = 0x8060
FEATURE_ONBOARD_PROFILES = 0x8100
PROFILE_MODES = {1: "onboard", 2: "host"}

REGISTER_GET_SHORT = 0x81
REGISTER_GET_LONG = 0x83
REGISTER_CONNECTIONS = 0x02
REGISTER_RECEIVER_INFO = 0xB5
REGISTER_UNIQUE_ID = 0xFB
# Bolt keeps pairing data in sub-registers 0x50+slot and 0x60+slot; Unifying and
# Lightspeed receivers in 0x20/0x30/0x40 + slot - 1, and their own serial and slot
# count in 0x03.
INFO_PAIRING = 0x50
INFO_NAME = 0x60
INFO_RECEIVER = 0x03
INFO_PAIRING_LEGACY = 0x20
INFO_EXTENDED_LEGACY = 0x30
INFO_NAME_LEGACY = 0x40
BOLT_PRODUCT = "c548"

FW_TYPES = {0: "main", 1: "bootloader", 2: "hardware", 3: "touchpad", 4: "optical sensor", 5: "softdevice"}
BATTERY_LEVELS = {1: "critical", 2: "low", 4: "good", 8: "full"}
CHARGING_STATUS = {0: "discharging", 1: "charging", 2: "charging (slow)", 3: "full", 4: "error"}
DEVICE_TYPES = {
    0: "keyboard", 1: "remote control", 2: "numpad", 3: "mouse", 4: "trackpad", 5: "trackball",
    6: "presenter", 7: "receiver", 8: "headset", 9: "webcam", 10: "steering wheel", 11: "joystick",
    12: "gamepad", 13: "dock", 14: "speaker", 15: "microphone",
}
PAIRED_KINDS = {1: "keyboard", 2: "mouse", 3: "numpad"}
# Receiver names by USB product id. The pairing registers read below are the Bolt
# ones; other receivers are listed, but their slots may come back empty.
RECEIVER_NAMES = {
    "c548": "Logi Bolt", "c52b": "Unifying", "c534": "Nano", "c539": "Lightspeed",
    "c53a": "Lightspeed", "c53f": "Lightspeed", "c545": "Lightspeed", "c547": "Lightspeed",
}
SMART_SHIFT_MODES = {1: "free spin", 2: "ratchet"}
CONTROL_NAMES = {
    0x0050: "Left click", 0x0051: "Right click", 0x0052: "Middle click", 0x0053: "Back",
    0x0056: "Forward", 0x00C3: "Gesture button", 0x00C4: "SmartShift", 0x00D7: "Virtual gesture button",
}


class LogimouseError(Exception):
    """A failure to report to the user, as text or as JSON."""


class Hidraw:
    """Sends HID++ requests on a hidraw node and waits for the matching reply."""

    def __init__(self, fd: int):
        self.fd = fd
        self._software_ids = itertools.cycle(SOFTWARE_IDS)

    def next_software_id(self) -> int:
        return next(self._software_ids)

    def drain(self) -> None:
        """Discard what is already waiting, such as a reply that arrived after its request timed out."""
        while select.select([self.fd], [], [], 0)[0]:
            os.read(self.fd, 64)

    def request(self, report_id: int, index: int, sub_id: int, address: int, *params: int, timeout: float = TIMEOUT_S) -> bytes | None:
        """Return the reply payload (bytes after the address byte), or None on error or timeout."""
        for attempt in range(BUSY_RETRIES):
            busy, reply = self._exchange(report_id, index, sub_id, address, *params, timeout=timeout)
            if not busy:
                return reply
            time.sleep(BUSY_DELAY_S * (attempt + 1))
        return None

    def _exchange(self, report_id: int, index: int, sub_id: int, address: int, *params: int, timeout: float = TIMEOUT_S) -> tuple[bool, bytes | None]:
        """Send one request; return (busy, payload). An error reply only counts when it
        echoes this request's sub ID and address, which carries the software ID: an
        error meant for another process is not ours."""
        length = SHORT_LEN if report_id == SHORT_REPORT else LONG_LEN
        self.drain()
        os.write(self.fd, bytes([report_id, index, sub_id, address, *params]).ljust(length, b"\0"))
        while True:
            ready, _, _ = select.select([self.fd], [], [], timeout)
            if not ready:
                return False, None
            reply = os.read(self.fd, 64)
            if len(reply) < 6 or reply[1] != index:
                continue
            if reply[2] in (ERROR_HIDPP10, ERROR_HIDPP20) and reply[3] == sub_id and reply[4] == address:
                return reply[2] == ERROR_HIDPP10 and reply[5] == ERROR_BUSY, None
            if reply[2] == sub_id and reply[3] == address:
                return False, reply[4:]


class Device:
    """A HID++ 2.0 device paired to the receiver."""

    def __init__(self, hidraw: Hidraw, index: int):
        self.hidraw = hidraw
        self.index = index
        self._features: dict[int, int | None] = {}

    def call(self, feature_index: int, function: int, *params: int, timeout: float = TIMEOUT_S) -> bytes | None:
        address = (function << 4) | self.hidraw.next_software_id()
        return self.hidraw.request(LONG_REPORT, self.index, feature_index, address, *params, timeout=timeout)

    def feature(self, feature_id: int) -> int | None:
        if feature_id not in self._features:
            reply = self.call(0, 0, feature_id >> 8, feature_id & 0xFF)
            self._features[feature_id] = reply[0] if reply and reply[0] else None
        return self._features[feature_id]

    def call_feature(self, feature_id: int, function: int, *params: int) -> bytes | None:
        idx = self.feature(feature_id)
        return None if idx is None else self.call(idx, function, *params)

    def is_online(self) -> bool:
        return self.call(0, 1, timeout=WAKE_TIMEOUT_S) is not None

    def name(self) -> str | None:
        reply = self.call_feature(FEATURE_NAME, 0)
        if reply is None:
            return None
        length = reply[0]
        name = b""
        while len(name) < length:
            name += self.call_feature(FEATURE_NAME, 1, len(name))[:16]
        return name[:length].decode(errors="replace")

    def device_type(self) -> str | None:
        reply = self.call_feature(FEATURE_NAME, 2)
        return None if reply is None else DEVICE_TYPES.get(reply[0], f"type {reply[0]}")

    def friendly_name(self) -> str | None:
        reply = self.call_feature(FEATURE_FRIENDLY_NAME, 0)
        if reply is None:
            return None
        length = reply[0]
        name = b""
        while len(name) < length:
            name += self.call_feature(FEATURE_FRIENDLY_NAME, 1, len(name))[1:16]
        return name[:length].decode(errors="replace")

    def device_info(self) -> dict | None:
        reply = self.call_feature(FEATURE_FW_VERSION, 0)
        if reply is None:
            return None
        info = {"modelId": reply[7:13].hex().upper(), "unitId": reply[1:5].hex().upper(), "serial": None, "firmware": []}
        if reply[14] & 0x01:
            serial = self.call_feature(FEATURE_FW_VERSION, 2)
            # Some devices claim a serial and answer with zero bytes: that is no serial.
            text = serial[:12].rstrip(b"\0").decode(errors="replace").strip() if serial else ""
            info["serial"] = text or None
        for entity in range(reply[0]):
            fw = self.call_feature(FEATURE_FW_VERSION, 1, entity)
            prefix = fw[1:4].decode(errors="replace").strip("\0 ")
            info["firmware"].append({
                "type": FW_TYPES.get(fw[0], f"type {fw[0]}"),
                "version": f"{prefix}{fw[4]:02x}.{fw[5]:02x}.B{fw[6]:02x}{fw[7]:02x}",
            })
        return info

    def battery(self) -> dict | None:
        reply = self.call_feature(FEATURE_UNIFIED_BATTERY, 1)
        if reply is not None:
            return {
                "percent": reply[0],
                "level": BATTERY_LEVELS.get(reply[1], f"level {reply[1]}"),
                "status": CHARGING_STATUS.get(reply[2], f"status {reply[2]}"),
                "charging": reply[2] in (1, 2),
                "externalPower": bool(reply[3]),
            }
        reply = self.call_feature(FEATURE_BATTERY_STATUS, 0)
        if reply is not None:
            return {"percent": reply[0], "level": None, "status": f"status {reply[2]}", "charging": None, "externalPower": None}
        return None

    def has_wireless_status(self) -> bool:
        # 0x1D4B has no getter: the device only broadcasts it as a notification on (re)connect.
        return self.feature(FEATURE_WIRELESS_STATUS) is not None

    def hosts(self) -> list[dict] | None:
        change_host = self.call_feature(FEATURE_CHANGE_HOST, 0)
        if change_host is None:
            return None
        count, current = change_host[0], change_host[1]
        info = self.call_feature(FEATURE_HOSTS_INFO, 0)
        has_names = info is not None and info[0] & 0x01
        hosts = []
        for host in range(count):
            paired = None
            name = None
            if has_names:
                host_info = self.call_feature(FEATURE_HOSTS_INFO, 1, host)
                paired, name_len = bool(host_info[1]), host_info[4]
                raw = b""
                while len(raw) < name_len:
                    raw += self.call_feature(FEATURE_HOSTS_INFO, 3, host, len(raw))[2:16]
                name = raw[:name_len].decode(errors="replace") or None
            hosts.append({"channel": host + 1, "paired": paired, "name": name, "current": host == current})
        return hosts

    def dpi_values(self) -> tuple[list[int], int | None] | None:
        """Return every supported DPI value, and the step when the device reports a range."""
        dpi_list = self.call_feature(FEATURE_ADJUSTABLE_DPI, 1, 0)
        if dpi_list is None:
            return None
        values = []
        step = None
        for offset in range(1, len(dpi_list) - 1, 2):
            value = (dpi_list[offset] << 8) | dpi_list[offset + 1]
            if value == 0:
                break
            if value >> 13 == 0b111:
                step = value & 0x1FFF
            else:
                values.append(value)
        if step and len(values) == 2:
            return list(range(values[0], values[1] + 1, step)), step
        return values, None

    def current_dpi(self) -> tuple[int, int] | None:
        """Return (current, default) DPI of sensor 0."""
        reply = self.call_feature(FEATURE_ADJUSTABLE_DPI, 2, 0)
        if reply is None:
            return None
        return (reply[1] << 8) | reply[2], (reply[3] << 8) | reply[4]

    def set_dpi(self, value: int) -> bool:
        return self.call_feature(FEATURE_ADJUSTABLE_DPI, 3, 0, value >> 8, value & 0xFF) is not None

    def dpi(self) -> dict | None:
        current = self.current_dpi()
        supported = self.dpi_values()
        if current is None or supported is None:
            return None
        values, step = supported
        return {
            "current": current[0],
            "default": current[1],
            "min": min(values),
            "max": max(values),
            "step": step,
            "values": None if step else values,
        }

    def report_rate(self) -> dict | None:
        """The polling rate in Hz: 0x8060 reports it as an interval, bit n of the
        supported mask meaning n + 1 ms."""
        supported = self.call_feature(FEATURE_REPORT_RATE, 0)
        current = self.call_feature(FEATURE_REPORT_RATE, 1)
        if supported is None or current is None or current[0] == 0:
            return None
        rates = sorted(1000 // (bit + 1) for bit in range(8) if supported[0] & (1 << bit))
        return {"current": 1000 // current[0], "supported": rates}

    def set_report_rate(self, hz: int) -> bool:
        return self.call_feature(FEATURE_REPORT_RATE, 2, 1000 // hz) is not None

    def profile_mode(self) -> str | None:
        """"onboard" when the profile stored on the mouse sets its report rate, DPI
        levels, buttons and lighting; "host" when the computer does. None without
        onboard profiles."""
        reply = self.call_feature(FEATURE_ONBOARD_PROFILES, 2)
        return None if reply is None else PROFILE_MODES.get(reply[0], f"mode {reply[0]}")

    def set_profile_mode(self, mode: str) -> bool:
        value = next(key for key, name in PROFILE_MODES.items() if name == mode)
        return self.call_feature(FEATURE_ONBOARD_PROFILES, 1, value) is not None

    def smart_shift(self) -> dict | None:
        reply = self.call_feature(FEATURE_SMART_SHIFT, 1)
        if reply is None:
            return None
        return {"mode": SMART_SHIFT_MODES.get(reply[0], f"mode {reply[0]}"), "threshold": reply[1], "force": reply[2]}

    def wheel(self) -> dict | None:
        caps = self.call_feature(FEATURE_HIRES_WHEEL, 0)
        mode = self.call_feature(FEATURE_HIRES_WHEEL, 1)
        if caps is None or mode is None:
            return None
        ratchet = self.call_feature(FEATURE_HIRES_WHEEL, 3) if caps[1] & 0x04 else None
        return {
            "highResolution": bool(mode[0] & 0x02),
            "inverted": bool(mode[0] & 0x04),
            "diverted": bool(mode[0] & 0x01),
            "stepsPerNotch": caps[0],
            "ratchet": None if ratchet is None else bool(ratchet[0] & 0x01),
        }

    def controls(self) -> list[dict] | None:
        count = self.call_feature(FEATURE_REPROG_CONTROLS, 0)
        if count is None:
            return None
        controls = []
        for n in range(count[0]):
            info = self.call_feature(FEATURE_REPROG_CONTROLS, 1, n)
            cid = (info[0] << 8) | info[1]
            flags = info[4]
            reporting = self.call_feature(FEATURE_REPROG_CONTROLS, 2, info[0], info[1])
            state = "default"
            remapped_to = None
            if reporting is not None:
                remap = (reporting[3] << 8) | reporting[4]
                if reporting[2] & 0x01:
                    state = "diverted"
                elif remap and remap != cid:
                    state = "remapped"
                    remapped_to = CONTROL_NAMES.get(remap, f"0x{remap:04X}")
            controls.append({
                "cid": cid,
                "name": CONTROL_NAMES.get(cid, f"control 0x{cid:04X}"),
                "remappable": bool(flags & 0x10),
                "divertable": bool(flags & 0x20),
                "virtual": bool(flags & 0x80),
                "state": state,
                "remappedTo": remapped_to,
            })
        return controls

    def unit_id(self) -> str | None:
        reply = self.call_feature(FEATURE_FW_VERSION, 0)
        return None if reply is None else reply[1:5].hex().upper()

    def to_dict(self) -> dict:
        info = self.device_info() or {}
        return {
            "slot": None if self.index == DIRECT_INDEX else self.index,
            "name": self.name(),
            "type": self.device_type(),
            "friendlyName": self.friendly_name(),
            "modelId": info.get("modelId"),
            "unitId": info.get("unitId"),
            "serial": info.get("serial"),
            "firmware": info.get("firmware", []),
            "battery": self.battery(),
            "wirelessStatus": self.has_wireless_status(),
            "dpi": self.dpi(),
            "reportRate": self.report_rate(),
            "profileMode": self.profile_mode(),
            "smartShift": self.smart_shift(),
            "wheel": self.wheel(),
            "hosts": self.hosts(),
            "buttons": self.controls(),
        }


def usb_info(path: str) -> dict[str, str]:
    """USB descriptor strings of the device a hidraw node belongs to, read from sysfs."""
    usb_dir = os.path.realpath(f"/sys/class/hidraw/{os.path.basename(path)}/device/../..")
    info = {}
    for attr in ("idVendor", "idProduct", "manufacturer", "product", "bcdDevice"):
        try:
            with open(f"{usb_dir}/{attr}") as f:
                info[attr] = f.read().strip()
        except OSError:
            pass
    return info


def usb_id(usb: dict[str, str]) -> str | None:
    if "idVendor" in usb and "idProduct" in usb:
        return f"{usb['idVendor']}:{usb['idProduct']}"
    return None


class Receiver:
    """A receiver, queried through HID++ 1.0 registers."""

    def __init__(self, hidraw: Hidraw, path: str, usb: dict[str, str] | None = None):
        self.hidraw = hidraw
        self.path = path
        self.usb = usb if usb is not None else usb_info(path)
        self._slots: list[dict] | None = None

    def read_short(self, register: int, *params: int) -> bytes | None:
        return self.hidraw.request(SHORT_REPORT, RECEIVER_INDEX, REGISTER_GET_SHORT, register, *params)

    def read_long(self, register: int, *params: int) -> bytes | None:
        return self.hidraw.request(SHORT_REPORT, RECEIVER_INDEX, REGISTER_GET_LONG, register, *params)

    def is_receiver(self) -> bool:
        """A receiver answers the connections register; a device on its own does not."""
        return self.paired_count() is not None

    def name(self) -> str:
        return RECEIVER_NAMES.get(self.usb.get("idProduct", "").lower(), "Logitech") + " receiver"

    def is_bolt(self) -> bool:
        return self.usb.get("idProduct", "").lower() == BOLT_PRODUCT

    def unique_id(self) -> str | None:
        if self.is_bolt():
            reply = self.read_long(REGISTER_UNIQUE_ID)
            return None if reply is None else reply.rstrip(b"\0").decode(errors="replace")
        reply = self.read_long(REGISTER_RECEIVER_INFO, INFO_RECEIVER)
        return None if reply is None else reply[1:5].hex().upper()

    def max_slots(self) -> int:
        if not self.is_bolt():
            reply = self.read_long(REGISTER_RECEIVER_INFO, INFO_RECEIVER)
            if reply is not None and 1 <= reply[6] <= MAX_SLOTS:
                return reply[6]
        return MAX_SLOTS

    def paired_count(self) -> int | None:
        reply = self.read_short(REGISTER_CONNECTIONS)
        return None if reply is None else reply[1]

    def slot(self, n: int) -> dict | None:
        if self.is_bolt():
            return self._bolt_slot(n)
        return self._legacy_slot(n)

    def _bolt_slot(self, n: int) -> dict | None:
        pairing = self.read_long(REGISTER_RECEIVER_INFO, INFO_PAIRING + n)
        if pairing is None:
            return None
        slot = {
            "slot": n,
            "name": None,
            "kind": PAIRED_KINDS.get(pairing[1] & 0x0F, f"kind {pairing[1] & 0x0F}"),
            "wpid": f"{(pairing[3] << 8) | pairing[2]:04X}",
            "unitId": pairing[4:8].hex().upper(),
        }
        name = self.read_long(REGISTER_RECEIVER_INFO, INFO_NAME + n, 0x01)
        if name is not None:
            slot["name"] = name[3:3 + name[2]].decode(errors="replace")
        return slot

    def _legacy_slot(self, n: int) -> dict | None:
        pairing = self.read_long(REGISTER_RECEIVER_INFO, INFO_PAIRING_LEGACY + n - 1)
        if pairing is None:
            return None
        slot = {
            "slot": n,
            "name": None,
            "kind": PAIRED_KINDS.get(pairing[7] & 0x0F, f"kind {pairing[7] & 0x0F}"),
            "wpid": pairing[3:5].hex().upper(),
            "unitId": None,
        }
        extended = self.read_long(REGISTER_RECEIVER_INFO, INFO_EXTENDED_LEGACY + n - 1)
        if extended is not None:
            slot["unitId"] = extended[1:5].hex().upper()
        name = self.read_long(REGISTER_RECEIVER_INFO, INFO_NAME_LEGACY + n - 1)
        if name is not None:
            slot["name"] = name[2:2 + name[1]].decode(errors="replace")
        return slot

    def slots(self) -> list[dict]:
        if self._slots is None:
            self._slots = [slot for slot in (self.slot(n) for n in range(1, self.max_slots() + 1)) if slot is not None]
        return self._slots

    def devices(self) -> list[Device]:
        """The online devices: only the paired slots are pinged, since an empty slot on
        some receivers answers nothing and costs a timeout. With no pairing data, all."""
        indexes = [slot["slot"] for slot in self.slots()] or range(1, self.max_slots() + 1)
        return [device for device in (Device(self.hidraw, i) for i in indexes) if device.is_online()]

    def to_dict(self, online_slots: set[int]) -> dict:
        release = self.usb.get("bcdDevice")
        slots = [{**slot, "online": slot["slot"] in online_slots} for slot in self.slots()]
        return {
            "path": self.path,
            "name": self.name(),
            "usbId": usb_id(self.usb),
            "product": f"{self.usb.get('manufacturer', '')} {self.usb['product']}".strip() if "product" in self.usb else None,
            "release": f"{release[:2]}.{release[2:]}" if release else None,
            "uniqueId": self.unique_id(),
            "pairedCount": self.paired_count(),
            "maxSlots": self.max_slots(),
            "slots": slots,
        }


# ── Discovery ───────────────────────────────────────────────────────────────

def hidraw_number(path: str) -> int:
    digits = "".join(ch for ch in os.path.basename(path) if ch.isdigit())
    return int(digits) if digits else 0


HID_DEVICE_NAME = re.compile(r"^[0-9A-F]{4}:[0-9A-F]{4}:[0-9A-F]{4}\.[0-9A-F]{4}$", re.IGNORECASE)


def is_receiver_child(sys_path: str) -> bool:
    """True for a node the kernel's Logitech receiver driver creates per paired device.

    Its HID device sits under the receiver's HID device instead of a USB interface.
    The device is already reached through the receiver, and requests on this node
    get their device index rewritten, so reading it would duplicate the device and
    time out.
    """
    parent = os.path.basename(os.path.realpath(f"{sys_path}/device/.."))
    return bool(HID_DEVICE_NAME.match(parent))


def find_hidpp_nodes() -> list[dict]:
    """Every Logitech hidraw node that carries HID++ long reports, in numeric order.

    Reading sysfs needs no access to the node itself, so this also finds the nodes
    the user cannot open.
    """
    nodes = []
    for path in glob.glob("/sys/class/hidraw/hidraw*"):
        try:
            with open(f"{path}/device/uevent") as f:
                uevent = f.read()
            with open(f"{path}/device/report_descriptor", "rb") as f:
                descriptor = f.read()
        except OSError:
            continue
        if "0000046D" not in uevent.upper() or b"\x85\x11" not in descriptor:
            continue
        if is_receiver_child(path):
            continue
        name = next((line.split("=", 1)[1] for line in uevent.splitlines() if line.startswith("HID_NAME=")), None)
        nodes.append({"path": "/dev/" + os.path.basename(path), "name": name})
    return sorted(nodes, key=lambda node: hidraw_number(node["path"]))


def open_node(path: str) -> int:
    return os.open(path, os.O_RDWR)



class Scan:
    """Every reachable HID++ device: those on receivers, those connected directly, and
    the nodes that could not be opened. Holds the nodes open until closed."""

    def __init__(self, nodes: list[dict], opener=open_node, usb_reader=usb_info, hidraw_factory=Hidraw):
        self.fds: list[int] = []
        self.receivers: list[Receiver] = []
        self.devices: list[tuple[Device, dict]] = []
        self.inaccessible: list[dict] = []
        for node in nodes:
            path = node["path"]
            usb = usb_reader(path)
            try:
                fd = opener(path)
            except PermissionError:
                self.inaccessible.append({"path": path, "name": node.get("name"), "usbId": usb_id(usb), "reason": "permission denied"})
                continue
            except OSError as error:
                self.inaccessible.append({"path": path, "name": node.get("name"), "usbId": usb_id(usb), "reason": error.strerror or str(error)})
                continue
            self.fds.append(fd)
            hidraw = hidraw_factory(fd)
            receiver = Receiver(hidraw, path, usb)
            if receiver.is_receiver():
                self.receivers.append(receiver)
                for device in receiver.devices():
                    self.devices.append((device, {"type": "receiver", "receiver": path, "receiverName": receiver.name(), "slot": device.index}))
                continue
            device = Device(hidraw, DIRECT_INDEX)
            if device.is_online():
                self.devices.append((device, {"type": "direct", "path": path, "usbId": usb_id(usb), "product": usb.get("product")}))

    def close(self) -> None:
        for fd in self.fds:
            if isinstance(fd, int) and fd >= 0:
                os.close(fd)
        self.fds = []

    def __enter__(self) -> "Scan":
        return self

    def __exit__(self, *exc) -> None:
        self.close()


def build_report(scan: Scan) -> dict:
    devices = []
    online_by_receiver: dict[str, set[int]] = {}
    seen: set[str] = set()
    for device, connection in scan.devices:
        info = device.to_dict()
        # The same device can be reachable twice (a receiver and a cable at once); list it once.
        if info["unitId"] is not None and info["unitId"] in seen:
            continue
        if info["unitId"] is not None:
            seen.add(info["unitId"])
        info["connection"] = connection
        devices.append(info)
        if connection["type"] == "receiver":
            online_by_receiver.setdefault(connection["receiver"], set()).add(connection["slot"])
    return {
        "ok": True,
        "error": None,
        "devices": devices,
        "receivers": [receiver.to_dict(online_by_receiver.get(receiver.path, set())) for receiver in scan.receivers],
        "inaccessible": scan.inaccessible,
    }


# ── Text output ─────────────────────────────────────────────────────────────

def field(label: str, value: object) -> None:
    if value is not None:
        print(f"  {label + ':':<18}{value}")


def field_list(label: str, values: list[str] | None) -> None:
    if values:
        print(f"  {label}:")
        for value in values:
            print(f"    {value}")


def format_battery(battery: dict | None) -> str:
    if battery is None:
        return "not reported"
    if battery["level"] is None:
        return f"{battery['percent']}%, {battery['status']}"
    power = "yes" if battery["externalPower"] else "no"
    return f"{battery['percent']}% ({battery['level']}), {battery['status']}, external power: {power}"


def format_dpi(dpi: dict | None) -> str | None:
    if dpi is None:
        return None
    if dpi["step"]:
        supported = f"{dpi['min']}–{dpi['max']} in steps of {dpi['step']}"
    else:
        supported = ", ".join(str(v) for v in dpi["values"])
    return f"{dpi['current']} (default {dpi['default']}; supported {supported})"


def format_report_rate(rate: dict | None) -> str | None:
    if rate is None:
        return None
    return f"{rate['current']} Hz (supported {', '.join(str(hz) for hz in rate['supported'])} Hz)"


def format_profile_mode(mode: str | None) -> str | None:
    if mode == "onboard":
        return "onboard (the mouse's stored profile sets report rate, DPI levels, buttons and lighting)"
    if mode == "host":
        return "host (the onboard profile is off; settings come from this computer)"
    return mode


def format_smart_shift(smart_shift: dict | None) -> str | None:
    if smart_shift is None:
        return None
    return f"{smart_shift['mode']}, auto-switch threshold {smart_shift['threshold']}, ratchet force {smart_shift['force']}%"


def format_wheel(wheel: dict | None) -> str | None:
    if wheel is None:
        return None
    parts = [
        f"{'high' if wheel['highResolution'] else 'low'} resolution ({wheel['stepsPerNotch']} steps/notch available)",
        f"{'inverted' if wheel['inverted'] else 'normal'} direction",
        f"reports via {'HID++ (diverted)' if wheel['diverted'] else 'HID'}",
    ]
    if wheel["ratchet"] is not None:
        parts.append("ratchet engaged" if wheel["ratchet"] else "free spin")
    return ", ".join(parts)


def format_hosts(hosts: list[dict] | None) -> list[str] | None:
    if hosts is None:
        return None
    lines = []
    for host in hosts:
        label = (host["name"] or "paired") if host["paired"] else "empty"
        marker = " (current)" if host["current"] else ""
        lines.append(f"channel {host['channel']}: {label}{marker}")
    return lines


def format_buttons(buttons: list[dict] | None) -> list[str] | None:
    if buttons is None:
        return None
    lines = []
    for button in buttons:
        abilities = [name for name in ("remappable", "divertable", "virtual") if button[name]]
        ability_text = f" [{', '.join(abilities)}]" if abilities else ""
        state = {"diverted": "diverted to software", "remapped": f"remapped to {button['remappedTo']}"}.get(
            button["state"], button["state"])
        lines.append(f"{button['name']} (0x{button['cid']:04X}){ability_text}: {state}")
    return lines


def connection_text(connection: dict) -> str:
    if connection["type"] == "receiver":
        return f"{connection['receiverName']}, slot {connection['slot']} ({connection['receiver']})"
    return f"direct, USB {connection['usbId']} ({connection['path']})"


def print_device(device: dict) -> None:
    print(f"\n{device['name'] or 'Unknown device'}")
    field("Connection", connection_text(device["connection"]))
    field("Type", device["type"])
    field("Friendly name", device["friendlyName"])
    field("Model ID", device["modelId"])
    field("Unit ID", device["unitId"])
    field("Serial", device["serial"])
    for fw in device["firmware"]:
        field("Firmware", f"{fw['type']}: {fw['version']}")
    field("Battery", format_battery(device["battery"]))
    if device["wirelessStatus"]:
        field("Wireless status", "online (reconnect events only; no current value to query)")
    field("DPI", format_dpi(device["dpi"]))
    field("Report rate", format_report_rate(device["reportRate"]))
    field("Profile mode", format_profile_mode(device["profileMode"]))
    field("SmartShift", format_smart_shift(device["smartShift"]))
    field("Wheel", format_wheel(device["wheel"]))
    field_list("Easy-Switch", format_hosts(device["hosts"]))
    field_list("Buttons", format_buttons(device["buttons"]))


def print_receiver(receiver: dict) -> None:
    print(f"\n{receiver['name']}")
    field("Device node", receiver["path"])
    field("USB ID", receiver["usbId"])
    field("USB product", receiver["product"])
    field("USB release", receiver["release"])
    field("Unique ID", receiver["uniqueId"])
    if receiver["pairedCount"] is not None:
        field("Paired devices", f"{receiver['pairedCount']} of {receiver['maxSlots']}")
    for slot in receiver["slots"]:
        state = "online" if slot["online"] else "offline"
        field(f"Slot {slot['slot']}", f"{slot['name'] or 'unknown'} ({slot['kind']}, WPID {slot['wpid']}, unit ID {slot['unitId']}, {state})")


def print_report(report: dict) -> None:
    if not report["devices"]:
        print("No online devices")
    for device in report["devices"]:
        print_device(device)
    for receiver in report["receivers"]:
        print_receiver(receiver)
    if report["inaccessible"]:
        print("\nNot accessible (see grant-access.sh)")
        for node in report["inaccessible"]:
            field(node["path"], f"{node['name'] or 'unknown'} ({node['usbId'] or '?'}): {node['reason']}")


# ── DPI command ─────────────────────────────────────────────────────────────

def select_device(scan: Scan, feature_id: int, unit_id: str | None, slot: int | None) -> Device | None:
    """The device a command addresses: by unit ID, by receiver slot, or the first one
    with the feature."""
    for device, connection in scan.devices:
        if device.feature(feature_id) is None:
            continue
        if unit_id is not None:
            if (device.unit_id() or "").upper() == unit_id.upper():
                return device
        elif slot is not None:
            if connection["type"] == "receiver" and connection["slot"] == slot:
                return device
        else:
            return device
    return None


def require_device(scan: Scan, feature_id: int, what: str, unit_id: str | None, slot: int | None) -> Device:
    device = select_device(scan, feature_id, unit_id, slot)
    if device is None:
        if unit_id is not None:
            where = f"with unit ID {unit_id}"
        elif slot is not None:
            where = f"in receiver slot {slot}"
        else:
            where = "connected"
        raise LogimouseError(f"No online device with {what} {where}")
    return device


def dpi_target(action: str, current: int, values: list[int]) -> int:
    """Return the DPI an action asks for, or raise LogimouseError when it is not valid."""
    if action == "up":
        higher = [v for v in values if v > current]
        return higher[0] if higher else current
    if action == "down":
        lower = [v for v in values if v < current]
        return lower[-1] if lower else current
    if action.isdigit():
        target = int(action)
        if target not in values:
            nearest = min(values, key=lambda v: abs(v - target))
            raise LogimouseError(f"{target} is not supported (supported: {min(values)}–{max(values)}; nearest: {nearest})")
        return target
    raise LogimouseError(f"Invalid DPI action '{action}': use up, down or a number")


def run_dpi(scan: Scan, unit_id: str | None, slot: int | None, action: str | None) -> dict:
    """Show or change the DPI; return {"unitId", "previous", "current", "changed", "dpi"}."""
    device = require_device(scan, FEATURE_ADJUSTABLE_DPI, "adjustable DPI", unit_id, slot)
    current, _ = device.current_dpi()
    selected = device.unit_id()
    if action is None:
        return {"unitId": selected, "previous": current, "current": current, "changed": False, "dpi": device.dpi()}
    values, _ = device.dpi_values()
    target = dpi_target(action, current, values)
    if target != current and not device.set_dpi(target):
        raise LogimouseError(f"Failed to set DPI to {target}")
    now = device.current_dpi()[0] if target != current else current
    return {"unitId": selected, "previous": current, "current": now, "changed": now != current, "dpi": None}


def rate_target(action: str, current: int, rates: list[int]) -> int:
    """The report rate in Hz an action asks for; "up" is the next higher rate."""
    if action == "up":
        higher = [hz for hz in rates if hz > current]
        return higher[0] if higher else current
    if action == "down":
        lower = [hz for hz in rates if hz < current]
        return lower[-1] if lower else current
    if action.isdigit() and int(action) in rates:
        return int(action)
    supported = ", ".join(str(hz) for hz in rates)
    raise LogimouseError(f"Invalid report rate '{action}': use up, down or one of {supported} (Hz)")


def run_rate(scan: Scan, unit_id: str | None, slot: int | None, action: str | None) -> dict:
    """Show or change the report rate; return {"unitId", "previous", "current", "changed", "reportRate", "profileMode"}."""
    device = require_device(scan, FEATURE_REPORT_RATE, "an adjustable report rate", unit_id, slot)
    rate = device.report_rate()
    mode = device.profile_mode()
    result = {"unitId": device.unit_id(), "previous": rate["current"], "current": rate["current"],
              "changed": False, "reportRate": rate, "profileMode": mode}
    if action is None:
        return result
    target = rate_target(action, rate["current"], rate["supported"])
    if target == rate["current"]:
        return result
    if mode == "onboard":
        raise LogimouseError("The report rate is set by the onboard profile: switch to host mode first (logimouse mode host)")
    if not device.set_report_rate(target):
        raise LogimouseError(f"The device refused a report rate of {target} Hz")
    now = device.report_rate()["current"]
    return {**result, "current": now, "changed": now != rate["current"], "reportRate": None}


def run_mode(scan: Scan, unit_id: str | None, slot: int | None, action: str | None) -> dict:
    """Show or change the onboard-profile mode; return {"unitId", "previous", "current", "changed"}."""
    device = require_device(scan, FEATURE_ONBOARD_PROFILES, "onboard profiles", unit_id, slot)
    mode = device.profile_mode()
    result = {"unitId": device.unit_id(), "previous": mode, "current": mode, "changed": False}
    if action is None or action == mode:
        return result
    if action not in PROFILE_MODES.values():
        raise LogimouseError(f"Invalid mode '{action}': use onboard or host")
    if not device.set_profile_mode(action):
        raise LogimouseError(f"The device refused to switch to {action} mode")
    now = device.profile_mode()
    return {**result, "current": now, "changed": now != mode}


def print_rate_result(result: dict, action: str | None) -> None:
    if action is None:
        print(format_report_rate(result["reportRate"]))
        print(f"Profile mode: {format_profile_mode(result['profileMode']) or 'none'}")
    elif not result["changed"]:
        print(f"Report rate: {result['current']} Hz (unchanged)")
    else:
        print(f"Report rate: {result['previous']} Hz -> {result['current']} Hz")


def print_mode_result(result: dict, action: str | None) -> None:
    if action is None or not result["changed"]:
        print(f"Profile mode: {format_profile_mode(result['current'])}")
    else:
        print(f"Profile mode: {result['previous']} -> {result['current']}")


def print_dpi_result(result: dict, action: str | None) -> None:
    if action is None:
        print(format_dpi(result["dpi"]))
    elif not result["changed"]:
        limit = "the limit" if action in ("up", "down") else "that value"
        print(f"DPI: {result['current']} (already at {limit})")
    else:
        print(f"DPI: {result['previous']} -> {result['current']}")


# ── Entry point ─────────────────────────────────────────────────────────────

def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="logimouse", description="Query Logitech HID++ devices on receivers or connected directly.")
    target = parser.add_mutually_exclusive_group()
    target.add_argument("--device", metavar="UNIT_ID", help="unit ID of the device to change (see the report)")
    target.add_argument("--slot", type=int, choices=range(1, MAX_SLOTS + 1), help="receiver slot of the device to change")
    parser.add_argument("--json", action="store_true", help="print the result as JSON")
    commands = parser.add_subparsers(dest="command")
    dpi = commands.add_parser("dpi", help="show or change the DPI")
    dpi.add_argument("action", nargs="?", help="'up', 'down' or a DPI value; omit to show the current DPI")
    rate = commands.add_parser("rate", help="show or change the report rate (needs host mode on mice with onboard profiles)")
    rate.add_argument("action", nargs="?", help="'up', 'down' or a rate in Hz; omit to show the current rate")
    mode = commands.add_parser("mode", help="show or change the onboard-profile mode")
    mode.add_argument("action", nargs="?", choices=["onboard", "host"], help="omit to show the current mode")
    return parser.parse_args(argv)


LOCK_TIMEOUT_S = 60


def lock_path() -> str:
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    return os.path.join(runtime, "logimouse.lock") if runtime else f"/tmp/logimouse-{os.getuid()}.lock"


@contextlib.contextmanager
def exclusive_access():
    """Only one logimouse talks to the devices at a time.

    Receivers answer one request at a time, and HID++ replies carry too little to
    tell whose request they answer, so two concurrent runs corrupt each other's reads
    (a device read with another request's replies). A second run waits here instead.
    """
    with open(lock_path(), "a") as lock:
        deadline = time.monotonic() + LOCK_TIMEOUT_S
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() > deadline:
                    raise LogimouseError("Another logimouse has been busy for over a minute") from None
                time.sleep(0.05)
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def run(args: argparse.Namespace) -> dict:
    nodes = find_hidpp_nodes()
    if not nodes:
        raise LogimouseError("No Logitech HID++ device found")
    with exclusive_access(), Scan(nodes) as scan:
        commands = {"dpi": run_dpi, "rate": run_rate, "mode": run_mode}
        if args.command in commands:
            if not scan.devices and scan.inaccessible:
                paths = ", ".join(node["path"] for node in scan.inaccessible)
                raise LogimouseError(f"No accessible device (no access to {paths})")
            return commands[args.command](scan, args.device, args.slot, args.action)
        return build_report(scan)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        result = run(args)
    except LogimouseError as error:
        if args.json:
            print(json.dumps({"ok": False, "error": str(error)}))
        else:
            print(error, file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(result if args.command is None else {"ok": True, "error": None, **result}))
    elif args.command == "dpi":
        print_dpi_result(result, args.action)
    elif args.command == "rate":
        print_rate_result(result, args.action)
    elif args.command == "mode":
        print_mode_result(result, args.action)
    else:
        print_report(result)
    return 0
