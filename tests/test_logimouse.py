"""Tests for the HID++ decoding, the report and the DPI command.

They replay replies recorded from an MX Anywhere 3S for Business on a Logi Bolt
receiver (tests/fixtures/mx_anywhere_3s.json), so they run without the hardware. The
same mouse stands in for a directly connected device by answering at index 0xFF,
with its unit ID changed so the two can be told apart.
"""

import json
from pathlib import Path

import pytest

import logimouse as lm

FIXTURE = Path(__file__).parent / "fixtures" / "mx_anywhere_3s.json"
RECORDED_SLOT = 2
RECORDED_UNIT = "829A24C0"
DIRECT_UNIT = "AABBCCDD"
FW_FEATURE_INDEX = 2
DPI_FEATURE_INDEX = 14
GET_FW_INFO = (0 << 4) | lm.SOFTWARE_ID
GET_DPI = (2 << 4) | lm.SOFTWARE_ID
SET_DPI = (3 << 4) | lm.SOFTWARE_ID
BOLT_USB = {"idVendor": "046d", "idProduct": "c548", "manufacturer": "Logitech", "product": "USB Receiver", "bcdDevice": "0503"}
DIRECT_USB = {"idVendor": "046d", "idProduct": "c094", "manufacturer": "Logitech", "product": "PRO X Wireless", "bcdDevice": "0100"}


def recorded_replies() -> dict:
    return {
        tuple(entry["request"]): None if entry["reply"] is None else bytes.fromhex(entry["reply"])
        for entry in json.loads(FIXTURE.read_text())
    }


class FakeReceiverNode(lm.Hidraw):
    """The recorded Bolt receiver, with the mouse in slot 2; keeps the DPI as state so it can be set."""

    usb = BOLT_USB

    def __init__(self, dpi: int = 800):
        super().__init__(-1)
        self.replies = recorded_replies()
        self.dpi = dpi
        self.requests: list[tuple] = []

    def request(self, report_id, index, sub_id, address, *params, timeout=None):
        # The recorded replies were taken with software ID 0x0A; a HID++ 2.0 request
        # now rotates it, so it is normalised back before the lookup.
        if report_id == lm.LONG_REPORT:
            address = (address & 0xF0) | lm.SOFTWARE_ID
        self.requests.append((report_id, index, sub_id, address, *params))
        return self.answer(report_id, index, sub_id, address, *params)

    def answer(self, report_id, index, sub_id, address, *params):
        if index == RECORDED_SLOT and sub_id == DPI_FEATURE_INDEX and address == GET_DPI:
            return bytes([0, self.dpi >> 8, self.dpi & 0xFF, 0x03, 0xE8]).ljust(16, b"\0")
        if index == RECORDED_SLOT and sub_id == DPI_FEATURE_INDEX and address == SET_DPI:
            self.dpi = (params[1] << 8) | params[2]
            return bytes(params).ljust(16, b"\0")
        # Anything not recorded is what an absent slot or feature answers: an error.
        return self.replies.get((report_id, index, sub_id, address, *params))


class FakeDirectNode(FakeReceiverNode):
    """The same mouse connected directly: it answers HID++ 2.0 at 0xFF and has no receiver registers."""

    usb = DIRECT_USB

    def answer(self, report_id, index, sub_id, address, *params):
        if index != lm.DIRECT_INDEX or sub_id in (lm.REGISTER_GET_SHORT, lm.REGISTER_GET_LONG):
            return None
        reply = super().answer(report_id, RECORDED_SLOT, sub_id, address, *params)
        if reply is not None and sub_id == FW_FEATURE_INDEX and address == GET_FW_INFO:
            reply = reply[:1] + bytes.fromhex(DIRECT_UNIT) + reply[5:]
        return reply


def scan_of(nodes: dict, denied: tuple = ()) -> lm.Scan:
    """A Scan over fake nodes, {path: fake}, plus paths that refuse to open."""
    paths = [{"path": path, "name": "Logitech test"} for path in [*nodes, *denied]]

    def opener(path):
        if path in denied:
            raise PermissionError(13, "Permission denied")
        return path

    return lm.Scan(
        paths,
        opener=opener,
        usb_reader=lambda path: nodes[path].usb if path in nodes else DIRECT_USB,
        hidraw_factory=lambda path: nodes[path],
    )


@pytest.fixture
def receiver_node() -> FakeReceiverNode:
    return FakeReceiverNode()


# ── Decoding ────────────────────────────────────────────────────────────────

def test_deviceToDict_givenRecordedMouse_decodesIdentity(receiver_node):
    # Arrange
    device = lm.Device(receiver_node, RECORDED_SLOT)

    # Act
    info = device.to_dict()

    # Assert
    assert info["name"] == "MX Anywhere 3S for Business"
    assert info["slot"] == RECORDED_SLOT
    assert info["type"] == "mouse"
    assert info["friendlyName"] == "MX Anywhere3SB"
    assert info["modelId"] == "B03800000000"
    assert info["unitId"] == RECORDED_UNIT
    assert info["serial"] == "2617ZA20L1R8"
    assert info["firmware"] == [
        {"type": "bootloader", "version": "BL193.01.B0006"},
        {"type": "main", "version": "RBM24.01.B0006"},
        {"type": "softdevice", "version": "00.00.B0126"},
    ]


def test_battery_givenChargingMouse_reportsChargingAndExternalPower(receiver_node):
    # Arrange
    device = lm.Device(receiver_node, RECORDED_SLOT)

    # Act
    battery = device.battery()

    # Assert
    assert battery["charging"] is True
    assert battery["externalPower"] is True
    assert battery["status"] == "charging"
    assert 0 <= battery["percent"] <= 100


def test_dpi_givenStepRange_reportsRangeWithoutValueList(receiver_node):
    # Arrange
    device = lm.Device(receiver_node, RECORDED_SLOT)

    # Act
    dpi = device.dpi()

    # Assert
    assert dpi == {"current": 800, "default": 1000, "min": 200, "max": 8000, "step": 50, "values": None}


def test_settings_givenRecordedMouse_decodesWheelHostsAndButtons(receiver_node):
    # Arrange
    device = lm.Device(receiver_node, RECORDED_SLOT)

    # Act
    smart_shift, wheel, hosts, buttons = device.smart_shift(), device.wheel(), device.hosts(), device.controls()

    # Assert
    assert smart_shift == {"mode": "ratchet", "threshold": 10, "force": 60}
    assert wheel == {"highResolution": False, "inverted": False, "diverted": False, "stepsPerNotch": 15, "ratchet": True}
    assert hosts[0] == {"channel": 1, "paired": True, "name": "Logitech Bolt receiver", "current": True}
    assert [host["paired"] for host in hosts] == [True, False, False]
    assert [button["name"] for button in buttons] == [
        "Left click", "Right click", "Middle click", "Back", "Forward", "SmartShift", "Virtual gesture button",
    ]
    assert all(button["state"] == "default" for button in buttons)


def test_receiverToDict_givenRecordedReceiver_decodesRegistersAndSlots(receiver_node):
    # Arrange
    receiver = lm.Receiver(receiver_node, "/dev/hidraw6", BOLT_USB)

    # Act
    info = receiver.to_dict({RECORDED_SLOT})

    # Assert
    assert info["name"] == "Logi Bolt receiver"
    assert info["uniqueId"] == "C5FB0B58885FB987"
    assert info["pairedCount"] == 1
    assert info["usbId"] == "046d:c548"
    assert info["release"] == "05.03"
    assert info["slots"] == [
        {"slot": 2, "name": "MX Anywhere3S", "kind": "mouse", "wpid": "B038", "unitId": RECORDED_UNIT, "online": True},
    ]


def test_receiverToDict_givenSlotOffline_marksItOffline(receiver_node):
    # Arrange
    receiver = lm.Receiver(receiver_node, "/dev/hidraw6", BOLT_USB)

    # Act
    info = receiver.to_dict(set())

    # Assert
    assert info["slots"][0]["online"] is False


# ── Discovery and report ────────────────────────────────────────────────────

def test_scan_givenReceiverNode_findsItsOnlineDevice(receiver_node):
    # Arrange / Act
    scan = scan_of({"/dev/hidraw6": receiver_node})

    # Assert
    assert [receiver.path for receiver in scan.receivers] == ["/dev/hidraw6"]
    assert [(device.index, connection["type"], connection["slot"]) for device, connection in scan.devices] == [
        (RECORDED_SLOT, "receiver", RECORDED_SLOT),
    ]


def test_scan_givenDirectNode_findsDeviceAtDirectIndex():
    # Arrange / Act
    scan = scan_of({"/dev/hidraw13": FakeDirectNode()})

    # Assert
    assert scan.receivers == []
    assert [(device.index, connection["type"], connection["usbId"]) for device, connection in scan.devices] == [
        (lm.DIRECT_INDEX, "direct", "046d:c094"),
    ]


def test_scan_givenNodeWithoutPermission_listsItAsInaccessible(receiver_node):
    # Arrange / Act
    scan = scan_of({"/dev/hidraw6": receiver_node}, denied=("/dev/hidraw13",))

    # Assert
    assert len(scan.devices) == 1
    assert scan.inaccessible == [
        {"path": "/dev/hidraw13", "name": "Logitech test", "usbId": "046d:c094", "reason": "permission denied"},
    ]


def test_buildReport_givenReceiverAndDirectDevice_reportsBothWithConnections(receiver_node):
    # Arrange
    scan = scan_of({"/dev/hidraw6": receiver_node, "/dev/hidraw13": FakeDirectNode()})

    # Act
    report = lm.build_report(scan)

    # Assert
    assert report["ok"] is True
    assert [device["connection"]["type"] for device in report["devices"]] == ["receiver", "direct"]
    assert [device["unitId"] for device in report["devices"]] == [RECORDED_UNIT, DIRECT_UNIT]
    assert [device["slot"] for device in report["devices"]] == [RECORDED_SLOT, None]
    assert report["devices"][0]["connection"]["receiverName"] == "Logi Bolt receiver"
    assert [receiver["path"] for receiver in report["receivers"]] == ["/dev/hidraw6"]
    assert report["receivers"][0]["slots"][0]["online"] is True
    assert report["inaccessible"] == []


def test_hidrawNumber_givenTwoDigitNode_sortsAfterSingleDigit():
    # Arrange
    paths = ["/dev/hidraw13", "/dev/hidraw6"]

    # Act
    ordered = sorted(paths, key=lm.hidraw_number)

    # Assert
    assert ordered == ["/dev/hidraw6", "/dev/hidraw13"]


# ── DPI ─────────────────────────────────────────────────────────────────────

@pytest.mark.parametrize(("action", "current", "expected"), [
    ("up", 800, 850),
    ("down", 800, 750),
    ("up", 8000, 8000),
    ("down", 200, 200),
    ("1200", 800, 1200),
])
def test_dpiTarget_givenAction_returnsNextSupportedValue(action, current, expected):
    # Arrange
    values = list(range(200, 8001, 50))

    # Act
    target = lm.dpi_target(action, current, values)

    # Assert
    assert target == expected


@pytest.mark.parametrize(("action", "message"), [
    ("1234", "nearest: 1250"),
    ("abc", "use up, down or a number"),
])
def test_dpiTarget_givenInvalidAction_raisesWithReason(action, message):
    # Arrange
    values = list(range(200, 8001, 50))

    # Act / Assert
    with pytest.raises(lm.LogimouseError, match=message):
        lm.dpi_target(action, 800, values)


def test_runDpi_givenUp_setsNextStepAndReadsItBack(receiver_node):
    # Arrange
    scan = scan_of({"/dev/hidraw6": receiver_node})

    # Act
    result = lm.run_dpi(scan, None, None, "up")

    # Assert
    assert result == {"unitId": RECORDED_UNIT, "previous": 800, "current": 850, "changed": True, "dpi": None}
    assert receiver_node.dpi == 850


def test_runDpi_givenDownBySlot_setsPreviousStep(receiver_node):
    # Arrange
    scan = scan_of({"/dev/hidraw6": receiver_node})

    # Act
    result = lm.run_dpi(scan, None, RECORDED_SLOT, "down")

    # Assert
    assert result["current"] == 750
    assert receiver_node.dpi == 750


def test_runDpi_givenUnitIdOfDirectDevice_changesOnlyThatDevice(receiver_node):
    # Arrange
    direct = FakeDirectNode(dpi=1600)
    scan = scan_of({"/dev/hidraw6": receiver_node, "/dev/hidraw13": direct})

    # Act
    result = lm.run_dpi(scan, DIRECT_UNIT.lower(), None, "down")

    # Assert
    assert result["unitId"] == DIRECT_UNIT
    assert direct.dpi == 1550
    assert receiver_node.dpi == 800


def test_runDpi_givenAtLimit_sendsNoSetRequest():
    # Arrange
    node = FakeReceiverNode(dpi=8000)
    scan = scan_of({"/dev/hidraw6": node})

    # Act
    result = lm.run_dpi(scan, None, None, "up")

    # Assert
    assert result["changed"] is False
    assert not any(req[2] == DPI_FEATURE_INDEX and req[3] == SET_DPI for req in node.requests)


def test_runDpi_givenEmptySlot_raises(receiver_node):
    # Arrange
    scan = scan_of({"/dev/hidraw6": receiver_node})

    # Act / Assert
    with pytest.raises(lm.LogimouseError, match="in receiver slot 3"):
        lm.run_dpi(scan, None, 3, "up")


def test_runDpi_givenUnknownUnitId_raises(receiver_node):
    # Arrange
    scan = scan_of({"/dev/hidraw6": receiver_node})

    # Act / Assert
    with pytest.raises(lm.LogimouseError, match="with unit ID DEADBEEF"):
        lm.run_dpi(scan, "DEADBEEF", None, "up")


# ── Entry point ─────────────────────────────────────────────────────────────

def test_main_givenNoDeviceAndJson_printsErrorDocument(monkeypatch, capsys):
    # Arrange
    monkeypatch.setattr(lm, "find_hidpp_nodes", lambda: [])

    # Act
    code = lm.main(["--json"])

    # Assert
    assert code == 1
    assert json.loads(capsys.readouterr().out) == {"ok": False, "error": "No Logitech HID++ device found"}


def test_parseArgs_givenDeviceAndSlot_rejectsBoth():
    # Act / Assert
    with pytest.raises(SystemExit):
        lm.parse_args(["--device", RECORDED_UNIT, "--slot", "2", "dpi", "up"])


def test_deviceInfo_givenSerialOfZeroBytes_reportsNoSerial():
    # Arrange: a device that claims a serial and answers with zero bytes, as the PRO X Wireless does
    node = FakeReceiverNode()
    node.replies[(lm.LONG_REPORT, RECORDED_SLOT, FW_FEATURE_INDEX, (2 << 4) | lm.SOFTWARE_ID)] = bytes(16)
    device = lm.Device(node, RECORDED_SLOT)

    # Act
    info = device.device_info()

    # Assert
    assert info["serial"] is None


def test_reportRate_givenIntervalFeature_reportsHertz():
    # Arrange: the PRO X Wireless's answers, supported mask 0x8B (1, 2, 4, 8 ms) and 1 ms now
    node = FakeReceiverNode()
    index = 0x30
    node.replies[(lm.LONG_REPORT, RECORDED_SLOT, 0, lm.SOFTWARE_ID, 0x80, 0x60)] = bytes([index]).ljust(16, b"\0")
    node.replies[(lm.LONG_REPORT, RECORDED_SLOT, index, lm.SOFTWARE_ID)] = bytes([0x8B]).ljust(16, b"\0")
    node.replies[(lm.LONG_REPORT, RECORDED_SLOT, index, (1 << 4) | lm.SOFTWARE_ID)] = bytes([1]).ljust(16, b"\0")
    device = lm.Device(node, RECORDED_SLOT)

    # Act
    rate = device.report_rate()

    # Assert
    assert rate == {"current": 1000, "supported": [125, 250, 500, 1000]}


def test_reportRate_givenNoFeature_reportsNone(receiver_node):
    # Arrange
    device = lm.Device(receiver_node, RECORDED_SLOT)

    # Act / Assert
    assert device.report_rate() is None


# ── Lightspeed / Unifying receivers ─────────────────────────────────────────

LIGHTSPEED_USB = {"idVendor": "046d", "idProduct": "c547", "manufacturer": "Logitech", "product": "USB Receiver", "bcdDevice": "0402"}
# Replies recorded from a Lightspeed receiver with a PRO X Wireless in slot 1.
LIGHTSPEED_REGISTERS = {
    (lm.SHORT_REPORT, lm.RECEIVER_INDEX, lm.REGISTER_GET_SHORT, lm.REGISTER_CONNECTIONS): "000100",
    (lm.SHORT_REPORT, lm.RECEIVER_INDEX, lm.REGISTER_GET_LONG, lm.REGISTER_RECEIVER_INFO, 0x03): "030e700fe6010207ff00000000000000",
    (lm.SHORT_REPORT, lm.RECEIVER_INDEX, lm.REGISTER_GET_LONG, lm.REGISTER_RECEIVER_INFO, 0x20): "2007084093110002b100000000a40000",
    (lm.SHORT_REPORT, lm.RECEIVER_INDEX, lm.REGISTER_GET_LONG, lm.REGISTER_RECEIVER_INFO, 0x30): "302b1699aa0e00200001000000000000",
    (lm.SHORT_REPORT, lm.RECEIVER_INDEX, lm.REGISTER_GET_LONG, lm.REGISTER_RECEIVER_INFO, 0x40): "400550524f2058000000000000000000",
}


class FakeLightspeedNode(FakeReceiverNode):
    """A Lightspeed receiver: legacy pairing registers, the recorded mouse answering in slot 1."""

    usb = LIGHTSPEED_USB

    def answer(self, report_id, index, sub_id, address, *params):
        if index == lm.RECEIVER_INDEX:
            reply = LIGHTSPEED_REGISTERS.get((report_id, index, sub_id, address, *params))
            return None if reply is None else bytes.fromhex(reply)
        if index == 1:
            return super().answer(report_id, RECORDED_SLOT, sub_id, address, *params)
        return None


def test_receiverToDict_givenLightspeedReceiver_readsLegacyRegisters():
    # Arrange
    receiver = lm.Receiver(FakeLightspeedNode(), "/dev/hidraw16", LIGHTSPEED_USB)

    # Act
    info = receiver.to_dict({1})

    # Assert
    assert info["name"] == "Lightspeed receiver"
    assert info["uniqueId"] == "0E700FE6"
    assert info["maxSlots"] == 2
    assert info["pairedCount"] == 1
    assert info["slots"] == [
        {"slot": 1, "name": "PRO X", "kind": "mouse", "wpid": "4093", "unitId": "2B1699AA", "online": True},
    ]


def test_receiverDevices_givenPairedSlots_pingsOnlyThose():
    # Arrange
    node = FakeLightspeedNode()
    receiver = lm.Receiver(node, "/dev/hidraw16", LIGHTSPEED_USB)

    # Act
    devices = receiver.devices()

    # Assert
    pinged = sorted({req[1] for req in node.requests if req[1] != lm.RECEIVER_INDEX and req[2] == 0 and req[3] == (1 << 4) | lm.SOFTWARE_ID})
    assert [device.index for device in devices] == [1]
    assert pinged == [1]


def test_buildReport_givenSameDeviceTwice_listsItOnce(receiver_node):
    # Arrange: the recorded mouse is reachable through the receiver and as a direct node with the same unit ID
    direct = FakeDirectNode()
    direct.answer = lambda report_id, index, sub_id, address, *params: (
        None if index != lm.DIRECT_INDEX or sub_id in (lm.REGISTER_GET_SHORT, lm.REGISTER_GET_LONG)
        else FakeReceiverNode.answer(direct, report_id, RECORDED_SLOT, sub_id, address, *params))
    scan = scan_of({"/dev/hidraw6": receiver_node, "/dev/hidraw13": direct})

    # Act
    report = lm.build_report(scan)

    # Assert
    assert [device["unitId"] for device in report["devices"]] == [RECORDED_UNIT]


def test_isReceiverChild_givenNodeUnderReceiverHidDevice_isTrue(tmp_path):
    # Arrange: /sys/class/hidraw/hidraw17/device -> .../0003:046D:C547.0018/0003:046D:4093.0019
    child = tmp_path / "0003:046D:C547.0018" / "0003:046D:4093.0019"
    child.mkdir(parents=True)
    node = tmp_path / "hidraw17"
    node.mkdir()
    (node / "device").symlink_to(child)

    # Act / Assert
    assert lm.is_receiver_child(str(node)) is True


def test_isReceiverChild_givenNodeUnderUsbInterface_isFalse(tmp_path):
    # Arrange: /sys/class/hidraw/hidraw16/device -> .../5-2.4.4.1:1.2/0003:046D:C547.0017
    hid = tmp_path / "5-2.4.4.1:1.2" / "0003:046D:C547.0017"
    hid.mkdir(parents=True)
    node = tmp_path / "hidraw16"
    node.mkdir()
    (node / "device").symlink_to(hid)

    # Act / Assert
    assert lm.is_receiver_child(str(node)) is False


def test_deviceCall_givenConsecutiveRequests_rotatesSoftwareId():
    # Arrange
    sent = []

    class Recorder(lm.Hidraw):
        def request(self, *req, timeout=None):
            sent.append(req)
            return None

    device = lm.Device(Recorder(-1), 1)

    # Act
    device.call(0, 0, 0x00, 0x05)
    device.call(0, 0, 0x00, 0x03)

    # Assert: same lookup twice, but a late reply to the first cannot answer the second
    first, second = sent[0][3] & 0x0F, sent[1][3] & 0x0F
    assert first != second
    assert {first, second} <= set(range(2, 16))
    assert sent[0][3] >> 4 == sent[1][3] >> 4 == 0


def test_exclusiveAccess_givenLockHeld_waitsThenFailsAfterTimeout(monkeypatch, tmp_path):
    # Arrange
    import fcntl
    monkeypatch.setenv("XDG_RUNTIME_DIR", str(tmp_path))
    monkeypatch.setattr(lm, "LOCK_TIMEOUT_S", 0.2)
    holder = open(tmp_path / "logimouse.lock", "a")
    fcntl.flock(holder, fcntl.LOCK_EX)

    # Act / Assert
    with pytest.raises(lm.LogimouseError, match="busy"):
        with lm.exclusive_access():
            pass
    holder.close()


def test_exclusiveAccess_givenFreeLock_entersAndReleases(monkeypatch, tmp_path):
    # Arrange
    monkeypatch.setenv("XDG_RUNTIME_DIR", str(tmp_path))

    # Act
    with lm.exclusive_access():
        pass
    with lm.exclusive_access():
        entered_twice = True

    # Assert
    assert entered_twice


# ── Report rate and onboard profiles ────────────────────────────────────────

RATE_INDEX = 0x30
PROFILES_INDEX = 0x31


class FakeGamingNode(FakeDirectNode):
    """A directly connected gaming mouse with report rate (0x8060) and onboard profiles
    (0x8100); like the PRO X Wireless, it refuses a rate change in onboard mode."""

    def __init__(self, interval_ms: int = 1, mode: int = 1):
        super().__init__()
        self.interval_ms = interval_ms
        self.mode = mode

    def answer(self, report_id, index, sub_id, address, *params):
        if index == lm.DIRECT_INDEX and report_id == lm.LONG_REPORT:
            function = address >> 4
            if sub_id == 0 and function == 0 and params[:2] == (0x80, 0x60):
                return bytes([RATE_INDEX]).ljust(16, b"\0")
            if sub_id == 0 and function == 0 and params[:2] == (0x81, 0x00):
                return bytes([PROFILES_INDEX]).ljust(16, b"\0")
            if sub_id == RATE_INDEX:
                if function == 0:
                    return bytes([0x8B]).ljust(16, b"\0")
                if function == 1:
                    return bytes([self.interval_ms]).ljust(16, b"\0")
                if function == 2:
                    if self.mode == 1:
                        return None
                    self.interval_ms = params[0]
                    return bytes(16)
            if sub_id == PROFILES_INDEX:
                if function == 2:
                    return bytes([self.mode]).ljust(16, b"\0")
                if function == 1:
                    self.mode = params[0]
                    return bytes(16)
        return super().answer(report_id, index, sub_id, address, *params)


def test_runRate_givenOnboardMode_refusesAndSaysHowToFix():
    # Arrange
    node = FakeGamingNode(mode=1)
    scan = scan_of({"/dev/hidraw13": node})

    # Act / Assert
    with pytest.raises(lm.LogimouseError, match="switch to host mode first"):
        lm.run_rate(scan, None, None, "down")
    assert node.interval_ms == 1


def test_runRate_givenHostMode_stepsDownToNextRate():
    # Arrange
    node = FakeGamingNode(mode=2)
    scan = scan_of({"/dev/hidraw13": node})

    # Act
    result = lm.run_rate(scan, None, None, "down")

    # Assert
    assert (result["previous"], result["current"], result["changed"]) == (1000, 500, True)
    assert node.interval_ms == 2


@pytest.mark.parametrize(("action", "current", "expected"), [
    ("up", 500, 1000), ("down", 500, 250), ("up", 1000, 1000), ("down", 125, 125), ("250", 1000, 250),
])
def test_rateTarget_givenAction_returnsSupportedRate(action, current, expected):
    # Act / Assert
    assert lm.rate_target(action, current, [125, 250, 500, 1000]) == expected


def test_rateTarget_givenUnsupportedRate_raises():
    # Act / Assert
    with pytest.raises(lm.LogimouseError, match="125, 250, 500, 1000"):
        lm.rate_target("300", 1000, [125, 250, 500, 1000])


def test_runMode_givenHost_switchesAndReadsItBack():
    # Arrange
    node = FakeGamingNode(mode=1)
    scan = scan_of({"/dev/hidraw13": node})

    # Act
    result = lm.run_mode(scan, None, None, "host")

    # Assert
    assert (result["previous"], result["current"], result["changed"]) == ("onboard", "host", True)
    assert node.mode == 2


def test_deviceToDict_givenGamingMouse_reportsRateAndMode():
    # Arrange
    device = lm.Device(FakeGamingNode(mode=1), lm.DIRECT_INDEX)

    # Act
    info = device.to_dict()

    # Assert
    assert info["reportRate"] == {"current": 1000, "supported": [125, 250, 500, 1000]}
    assert info["profileMode"] == "onboard"
