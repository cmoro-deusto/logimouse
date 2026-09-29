"""Tests for the HID++ decoding, the report and the DPI command.

They replay replies recorded from an MX Anywhere 3S for Business on a Logi Bolt
receiver (tests/fixtures/mx_anywhere_3s.json), so they run without the hardware.
"""

import json
from pathlib import Path

import pytest

import logimouse as lm

FIXTURE = Path(__file__).parent / "fixtures" / "mx_anywhere_3s.json"
DPI_FEATURE_INDEX = 14
GET_DPI = (2 << 4) | lm.SOFTWARE_ID
SET_DPI = (3 << 4) | lm.SOFTWARE_ID


class FakeHidraw(lm.Hidraw):
    """Answers each request with its recorded reply; keeps the DPI as state so it can be set."""

    def __init__(self, dpi: int = 800):
        super().__init__(-1)
        self.replies = {
            tuple(entry["request"]): None if entry["reply"] is None else bytes.fromhex(entry["reply"])
            for entry in json.loads(FIXTURE.read_text())
        }
        self.dpi = dpi
        self.requests: list[tuple] = []

    def request(self, report_id, index, sub_id, address, *params):
        self.requests.append((report_id, index, sub_id, address, *params))
        if sub_id == DPI_FEATURE_INDEX and address == GET_DPI:
            return bytes([0, self.dpi >> 8, self.dpi & 0xFF, 0x03, 0xE8]).ljust(16, b"\0")
        if sub_id == DPI_FEATURE_INDEX and address == SET_DPI:
            self.dpi = (params[1] << 8) | params[2]
            return bytes(params).ljust(16, b"\0")
        # Anything not recorded is what an absent slot or feature answers: an error.
        return self.replies.get((report_id, index, sub_id, address, *params))


@pytest.fixture
def hidraw() -> FakeHidraw:
    return FakeHidraw()


@pytest.fixture
def no_sysfs(monkeypatch):
    usb = {"idVendor": "046d", "idProduct": "c548", "manufacturer": "Logitech", "product": "USB Receiver", "bcdDevice": "0503"}
    monkeypatch.setattr(lm.Receiver, "usb_info", lambda self: usb)


def test_buildReport_givenRecordedMouse_listsOnlyTheOnlineSlot(hidraw, no_sysfs):
    # Arrange / Act
    report = lm.build_report(hidraw, "/dev/hidraw6")

    # Assert
    assert report["ok"] is True
    assert [device["slot"] for device in report["devices"]] == [2]


def test_deviceToDict_givenRecordedMouse_decodesIdentity(hidraw):
    # Arrange
    device = lm.Device(hidraw, 2)

    # Act
    info = device.to_dict()

    # Assert
    assert info["name"] == "MX Anywhere 3S for Business"
    assert info["type"] == "mouse"
    assert info["friendlyName"] == "MX Anywhere3SB"
    assert info["modelId"] == "B03800000000"
    assert info["unitId"] == "829A24C0"
    assert info["serial"] == "2617ZA20L1R8"
    assert info["firmware"] == [
        {"type": "bootloader", "version": "BL193.01.B0006"},
        {"type": "main", "version": "RBM24.01.B0006"},
        {"type": "softdevice", "version": "00.00.B0126"},
    ]


def test_battery_givenChargingMouse_reportsChargingAndExternalPower(hidraw):
    # Arrange
    device = lm.Device(hidraw, 2)

    # Act
    battery = device.battery()

    # Assert
    assert battery["charging"] is True
    assert battery["externalPower"] is True
    assert battery["status"] == "charging"
    assert 0 <= battery["percent"] <= 100


def test_dpi_givenStepRange_reportsRangeWithoutValueList(hidraw):
    # Arrange
    device = lm.Device(hidraw, 2)

    # Act
    dpi = device.dpi()

    # Assert
    assert dpi == {"current": 800, "default": 1000, "min": 200, "max": 8000, "step": 50, "values": None}


def test_settings_givenRecordedMouse_decodesWheelHostsAndButtons(hidraw):
    # Arrange
    device = lm.Device(hidraw, 2)

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


def test_receiverToDict_givenRecordedReceiver_decodesRegistersAndSlots(hidraw, no_sysfs):
    # Arrange
    receiver = lm.Receiver(hidraw, "/dev/hidraw6")

    # Act
    info = receiver.to_dict({2})

    # Assert
    assert info["uniqueId"] == "C5FB0B58885FB987"
    assert info["pairedCount"] == 1
    assert info["usbId"] == "046d:c548"
    assert info["release"] == "05.03"
    assert info["slots"] == [
        {"slot": 2, "name": "MX Anywhere3S", "kind": "mouse", "wpid": "B038", "unitId": "829A24C0", "online": True},
    ]


def test_receiverToDict_givenSlotOffline_marksItOffline(hidraw, no_sysfs):
    # Arrange
    receiver = lm.Receiver(hidraw, "/dev/hidraw6")

    # Act
    info = receiver.to_dict(set())

    # Assert
    assert info["slots"][0]["online"] is False


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


def test_runDpi_givenUp_setsNextStepAndReadsItBack(hidraw):
    # Arrange / Act
    result = lm.run_dpi(hidraw, None, "up")

    # Assert
    assert result == {"slot": 2, "previous": 800, "current": 850, "changed": True, "dpi": None}
    assert hidraw.dpi == 850


def test_runDpi_givenAtLimit_sendsNoSetRequest():
    # Arrange
    hidraw = FakeHidraw(dpi=8000)

    # Act
    result = lm.run_dpi(hidraw, None, "up")

    # Assert
    assert result["changed"] is False
    assert not any(req[2] == DPI_FEATURE_INDEX and req[3] == SET_DPI for req in hidraw.requests)


def test_runDpi_givenEmptySlot_raises(hidraw):
    # Act / Assert
    with pytest.raises(lm.LogimouseError, match="in slot 3"):
        lm.run_dpi(hidraw, 3, "up")


def test_main_givenNoReceiverAndJson_printsErrorDocument(monkeypatch, capsys):
    # Arrange
    monkeypatch.setattr(lm, "find_hidpp_node", lambda: None)

    # Act
    code = lm.main(["--json"])

    # Assert
    assert code == 1
    assert json.loads(capsys.readouterr().out) == {"ok": False, "error": "No Logitech HID++ receiver found"}

