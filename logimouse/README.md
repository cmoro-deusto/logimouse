# Logi Mouse

The battery level, charging state and DPI of a Logitech mouse, on a Logi Bolt
receiver or connected directly by USB, in the Noctalia bar. Clicking the widget
opens a panel that lists every device and shows everything the selected one and its
receiver report, and lets you step the DPI up or down.

## Plugin

| Field | Value |
| --- | --- |
| ID | `cmoro-deusto/logimouse` |
| Entries | Bar widget: `bar`; panel: `panel`; service: `reader` |

## Requirements

`logimouse` on `PATH` (or in `~/.local/bin`). It is the command line tool in the
same repository as this plugin, and `install.sh` there installs both. The plugin
cannot read the mouse itself: Noctalia's scripts cannot open `/dev/hidraw*`.

The user running Noctalia needs read/write access to each device's hidraw node.
`grant-access.sh` in the same repository adds a udev rule for the devices you pick.
A device without access is listed in the panel with a lock and the node it needs.
Tested with an MX Anywhere 3S for Business on a Bolt receiver; other HID++ 2.0
devices should work, showing whatever features they have.

## Usage

Add **Logi Mouse** from the bar's widget picker (Settings → Bar). It shows one
device, the one `bar_device` names or the first online one with a battery, with,
each one optional:

- a mouse icon, which turns into a warning sign when the battery is low;
- the battery percentage, amber at or below the warning level and in the theme's
  error colour at or below the low level;
- a bolt while the mouse is charging;
- the current DPI.

When the mouse is asleep or switched off, the widget keeps its last values, dimmed,
and the tooltip says when it was last seen. With no reading at all, it shows a
dash and the tooltip gives the reason.

- **Left click** toggles the panel.
- **Right click** opens the settings.
- **Hover** shows the device, battery, DPI and any error.

The panel's left column lists every device (online or asleep, battery, and how it
is connected), then the devices that cannot be opened, then the receivers. Pick a
device to see its battery and DPI, the scroll wheel (SmartShift and resolution),
the Easy-Switch channels, the buttons, its model, unit ID, serial and firmware, and
its connection: the receiver with its pairing slots, or the USB device. The DPI's
− and + buttons move one supported step; they are disabled while the mouse is
asleep. A mouse with a report rate gets a Report rate card that works the same way.
On a mouse with onboard profiles, its − and + stay disabled while the stored profile
sets the rate; the card's **Use host mode** button hands the rate to the computer
(and turns the profile's buttons, DPI levels and lighting off), and **Back to
onboard profile** restores it. Open the panel from anywhere, including a compositor key binding:

```sh
noctalia msg panel-toggle cmoro-deusto/logimouse:panel
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `show_icon` | `bool` | `true` | Draw the mouse icon in the bar. |
| `show_battery` | `bool` | `true` | Show the battery percentage. |
| `show_charging` | `bool` | `true` | Show a bolt while charging, independently of `show_battery`. |
| `show_dpi` | `bool` | `true` | Show the current DPI. |
| `bar_device` | `string` | empty | Which device the bar shows: part of its name (`PRO X`) or its unit ID from the panel. Empty picks the first online device with a battery. |
| `interval` | `int` | `60` | Seconds between reads, 10–600. |
| `battery_warn` | `int` | `20` | Percentage at or below which the battery is amber, 10–80. |
| `battery_low` | `int` | `10` | Percentage at or below which the battery is in the error colour, 5–50. If it is at or above `battery_warn`, there is no amber band. |

While the mouse is charging, neither colour applies.

## Notes

- **Processes spawned.** The service runs `logimouse --json` once per `interval`,
  when the panel opens, and when you press the panel's refresh button. The DPI
  and report-rate buttons run `logimouse --json --device <unit ID> dpi|rate up|down`,
  and the mode button `logimouse --json --device <unit ID> mode host|onboard`. Only
  one runs at a time, because two processes on the same hidraw node would read each
  other's replies. Only failed reads are logged, prefixed `logimouse:`.
- **Hardware traffic.** Each read sends about 60 small HID++ requests over the
  wireless link, which is why the interval defaults to a minute.
- **DPI changes do not persist.** The mouse keeps the DPI in working memory, so it
  can return to its default after it powers off or reconnects.
- **Files written.** None. The last reading is held in memory only; after a
  restart the widget shows a dash until the first read.
- **Network.** None.
- **Debugging.** The service logs every failed read, prefixed `logimouse:`. Run
  `logimouse` in a terminal to see the same data as text.

## Tests

From this directory:

```sh
lua tests/shared_test.lua        # the model, with a fixed clock and no host
python3 tests/plugin_check.py    # manifest, translations and every API call against Noctalia's definitions
```

`make test` in the repository root runs these and the Python tests of the command
line tool.
