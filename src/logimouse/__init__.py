"""Query a Logi Bolt receiver and its paired HID++ 2.0 devices through /dev/hidraw."""

import argparse
import glob
import json
import os
import select
import sys

SHORT_REPORT = 0x10
LONG_REPORT = 0x11
SHORT_LEN = 7
LONG_LEN = 20
SOFTWARE_ID = 0x0A
ERROR_HIDPP10 = 0x8F
ERROR_HIDPP20 = 0xFF
RECEIVER_INDEX = 0xFF
MAX_SLOTS = 6
TIMEOUT_S = 1.0

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

REGISTER_GET_SHORT = 0x81
REGISTER_GET_LONG = 0x83
REGISTER_CONNECTIONS = 0x02
REGISTER_RECEIVER_INFO = 0xB5
REGISTER_UNIQUE_ID = 0xFB
INFO_PAIRING = 0x50
INFO_NAME = 0x60

FW_TYPES = {0: "main", 1: "bootloader", 2: "hardware", 3: "touchpad", 4: "optical sensor", 5: "softdevice"}
BATTERY_LEVELS = {1: "critical", 2: "low", 4: "good", 8: "full"}
CHARGING_STATUS = {0: "discharging", 1: "charging", 2: "charging (slow)", 3: "full", 4: "error"}
DEVICE_TYPES = {
    0: "keyboard", 1: "remote control", 2: "numpad", 3: "mouse", 4: "trackpad", 5: "trackball",
    6: "presenter", 7: "receiver", 8: "headset", 9: "webcam", 10: "steering wheel", 11: "joystick",
    12: "gamepad", 13: "dock", 14: "speaker", 15: "microphone",
}
PAIRED_KINDS = {1: "keyboard", 2: "mouse", 3: "numpad"}
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

    def request(self, report_id: int, index: int, sub_id: int, address: int, *params: int) -> bytes | None:
        """Return the reply payload (bytes after the address byte), or None on error or timeout."""
        length = SHORT_LEN if report_id == SHORT_REPORT else LONG_LEN
        os.write(self.fd, bytes([report_id, index, sub_id, address, *params]).ljust(length, b"\0"))
        while True:
            ready, _, _ = select.select([self.fd], [], [], TIMEOUT_S)
            if not ready:
                return None
            reply = os.read(self.fd, 64)
            if len(reply) < 5 or reply[1] != index:
                continue
            if reply[2] == ERROR_HIDPP10 and reply[3] == sub_id:
                return None
            if reply[2] == ERROR_HIDPP20 and reply[3] == sub_id:
                return None
            if reply[2] == sub_id and reply[3] == address:
                return reply[4:]


class Device:
    """A HID++ 2.0 device paired to the receiver."""

    def __init__(self, hidraw: Hidraw, index: int):
        self.hidraw = hidraw
        self.index = index
        self._features: dict[int, int | None] = {}

    def call(self, feature_index: int, function: int, *params: int) -> bytes | None:
        return self.hidraw.request(LONG_REPORT, self.index, feature_index, (function << 4) | SOFTWARE_ID, *params)

    def feature(self, feature_id: int) -> int | None:
        if feature_id not in self._features:
            reply = self.call(0, 0, feature_id >> 8, feature_id & 0xFF)
            self._features[feature_id] = reply[0] if reply and reply[0] else None
        return self._features[feature_id]

    def call_feature(self, feature_id: int, function: int, *params: int) -> bytes | None:
        idx = self.feature(feature_id)
        return None if idx is None else self.call(idx, function, *params)

    def is_online(self) -> bool:
        return self.call(0, 1) is not None

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
            if serial:
                info["serial"] = serial[:12].decode(errors="replace")
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

    def to_dict(self) -> dict:
        info = self.device_info() or {}
        return {
            "slot": self.index,
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
            "smartShift": self.smart_shift(),
            "wheel": self.wheel(),
            "hosts": self.hosts(),
            "buttons": self.controls(),
        }


class Receiver:
    """The Bolt receiver itself, queried through HID++ 1.0 registers."""

    def __init__(self, hidraw: Hidraw, path: str):
        self.hidraw = hidraw
        self.path = path

    def read_short(self, register: int, *params: int) -> bytes | None:
        return self.hidraw.request(SHORT_REPORT, RECEIVER_INDEX, REGISTER_GET_SHORT, register, *params)

    def read_long(self, register: int, *params: int) -> bytes | None:
        return self.hidraw.request(SHORT_REPORT, RECEIVER_INDEX, REGISTER_GET_LONG, register, *params)

    def usb_info(self) -> dict[str, str]:
        usb_dir = os.path.realpath(f"/sys/class/hidraw/{os.path.basename(self.path)}/device/../..")
        info = {}
        for attr in ("idVendor", "idProduct", "manufacturer", "product", "bcdDevice"):
            try:
                with open(f"{usb_dir}/{attr}") as f:
                    info[attr] = f.read().strip()
            except OSError:
                pass
        return info

    def unique_id(self) -> str | None:
        reply = self.read_long(REGISTER_UNIQUE_ID)
        return None if reply is None else reply.rstrip(b"\0").decode(errors="replace")

    def paired_count(self) -> int | None:
        reply = self.read_short(REGISTER_CONNECTIONS)
        return None if reply is None else reply[1]

    def slot(self, n: int) -> dict | None:
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

    def to_dict(self, online_slots: set[int]) -> dict:
        usb = self.usb_info()
        release = usb.get("bcdDevice")
        slots = []
        for n in range(1, MAX_SLOTS + 1):
            slot = self.slot(n)
            if slot is not None:
                slot["online"] = n in online_slots
                slots.append(slot)
        return {
            "path": self.path,
            "usbId": f"{usb['idVendor']}:{usb['idProduct']}" if "idVendor" in usb and "idProduct" in usb else None,
            "product": f"{usb.get('manufacturer', '')} {usb['product']}".strip() if "product" in usb else None,
            "release": f"{release[:2]}.{release[2:]}" if release else None,
            "uniqueId": self.unique_id(),
            "pairedCount": self.paired_count(),
            "maxSlots": MAX_SLOTS,
            "slots": slots,
        }


def find_hidpp_node() -> str | None:
    """Return the hidraw node of the Logitech receiver interface that carries HID++ long reports."""
    for path in sorted(glob.glob("/sys/class/hidraw/hidraw*")):
        with open(f"{path}/device/uevent") as f:
            uevent = f.read()
        if "0000046D" not in uevent.upper():
            continue
        with open(f"{path}/device/report_descriptor", "rb") as f:
            if b"\x85\x11" in f.read():
                return "/dev/" + os.path.basename(path)
    return None


def online_devices(hidraw: Hidraw) -> list[Device]:
    return [device for device in (Device(hidraw, i) for i in range(1, MAX_SLOTS + 1)) if device.is_online()]


def build_report(hidraw: Hidraw, path: str) -> dict:
    devices = online_devices(hidraw)
    return {
        "ok": True,
        "error": None,
        "devices": [device.to_dict() for device in devices],
        "receiver": Receiver(hidraw, path).to_dict({device.index for device in devices}),
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


def print_device(device: dict) -> None:
    print(f"\nSlot {device['slot']}: {device['name'] or 'unknown'}")
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
    field("SmartShift", format_smart_shift(device["smartShift"]))
    field("Wheel", format_wheel(device["wheel"]))
    field_list("Easy-Switch", format_hosts(device["hosts"]))
    field_list("Buttons", format_buttons(device["buttons"]))


def print_receiver(receiver: dict) -> None:
    print("\nReceiver")
    field("Device node", receiver["path"])
    field("USB ID", receiver["usbId"])
    field("USB product", receiver["product"])
    field("USB release", receiver["release"])
    field("Unique ID", receiver["uniqueId"])
    if receiver["pairedCount"] is not None:
        field("Paired devices", f"{receiver['pairedCount']} of {receiver['maxSlots']}")
    for slot in receiver["slots"]:
        field(f"Slot {slot['slot']}", f"{slot['name'] or 'unknown'} ({slot['kind']}, WPID {slot['wpid']}, unit ID {slot['unitId']})")


def print_report(report: dict) -> None:
    if not report["devices"]:
        print("No online devices on this receiver")
    for device in report["devices"]:
        print_device(device)
    print_receiver(report["receiver"])


# ── DPI command ─────────────────────────────────────────────────────────────

def select_dpi_device(online: list[Device], slot: int | None) -> Device | None:
    for device in online:
        if (slot is None or device.index == slot) and device.feature(FEATURE_ADJUSTABLE_DPI) is not None:
            return device
    return None


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


def run_dpi(hidraw: Hidraw, slot: int | None, action: str | None) -> dict:
    """Show or change the DPI; return {"slot", "previous", "current", "changed"}."""
    device = select_dpi_device(online_devices(hidraw), slot)
    if device is None:
        where = f"in slot {slot}" if slot is not None else "on this receiver"
        raise LogimouseError(f"No online device with adjustable DPI {where}")
    current, _ = device.current_dpi()
    if action is None:
        return {"slot": device.index, "previous": current, "current": current, "changed": False, "dpi": device.dpi()}
    values, _ = device.dpi_values()
    target = dpi_target(action, current, values)
    if target != current and not device.set_dpi(target):
        raise LogimouseError(f"Failed to set DPI to {target}")
    now = device.current_dpi()[0] if target != current else current
    return {"slot": device.index, "previous": current, "current": now, "changed": now != current, "dpi": None}


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
    parser = argparse.ArgumentParser(prog="logimouse", description="Query Logitech devices on a Logi Bolt receiver.")
    parser.add_argument("--slot", type=int, choices=range(1, MAX_SLOTS + 1), help="receiver slot of the device to change")
    parser.add_argument("--json", action="store_true", help="print the result as JSON")
    commands = parser.add_subparsers(dest="command")
    dpi = commands.add_parser("dpi", help="show or change the DPI")
    dpi.add_argument("action", nargs="?", help="'up', 'down' or a DPI value; omit to show the current DPI")
    return parser.parse_args(argv)


def open_receiver() -> tuple[int, str]:
    path = find_hidpp_node()
    if path is None:
        raise LogimouseError("No Logitech HID++ receiver found")
    try:
        return os.open(path, os.O_RDWR), path
    except PermissionError:
        raise LogimouseError(f"Permission denied on {path}") from None


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        fd, path = open_receiver()
        try:
            hidraw = Hidraw(fd)
            if args.command == "dpi":
                result = run_dpi(hidraw, args.slot, args.action)
            else:
                result = build_report(hidraw, path)
        finally:
            os.close(fd)
    except LogimouseError as error:
        if args.json:
            print(json.dumps({"ok": False, "error": str(error)}))
        else:
            print(error, file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps({"ok": True, "error": None, **result} if args.command == "dpi" else result))
    elif args.command == "dpi":
        print_dpi_result(result, args.action)
    else:
        print_report(result)
    return 0
