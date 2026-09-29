# Logi Mouse

The battery level, charging state and DPI of a Logitech mouse on a Logi Bolt
receiver, in the Noctalia bar. Clicking the widget opens a panel with everything
the mouse and the receiver report, and lets you step the DPI up or down.

## Plugin

| Field | Value |
| --- | --- |
| ID | `cmoro-deusto/logimouse` |
| Entries | Bar widget: `bar`; panel: `panel`; service: `reader` |

## Requirements

`logimouse` on `PATH` (or in `~/.local/bin`). It is the command line tool in the
same repository as this plugin, and `install.sh` there installs both. The plugin
cannot read the mouse itself: Noctalia's scripts cannot open `/dev/hidraw*`.

The user running Noctalia needs read/write access to the receiver's hidraw node.
Desktop sessions grant this through a uaccess ACL, so there is usually nothing to
do. Tested with an MX Anywhere 3S for Business; other HID++ 2.0 devices on a Bolt
receiver should work, showing whatever features they have.

## Usage

Add **Logi Mouse** from the bar's widget picker (Settings → Bar). It shows, each
one optional:

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

The panel shows battery and DPI, the scroll wheel (SmartShift and resolution),
the Easy-Switch channels, the buttons, the device's model, serial and firmware,
and the receiver with its six pairing slots. The DPI's − and + buttons move one
supported step; they are disabled while the mouse is asleep. Open the panel from
anywhere, including a compositor key binding:

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
| `interval` | `int` | `60` | Seconds between reads, 10–600. |
| `battery_warn` | `int` | `20` | Percentage at or below which the battery is amber, 10–80. |
| `battery_low` | `int` | `10` | Percentage at or below which the battery is in the error colour, 5–50. If it is at or above `battery_warn`, there is no amber band. |

While the mouse is charging, neither colour applies.

## Notes

- **Processes spawned.** The service runs `logimouse --json` once per `interval`,
  when the panel opens, and when you press the panel's refresh button. The DPI
  buttons run `logimouse --json --slot <n> dpi up|down`. Only one runs at a time,
  because two processes on the same hidraw node would read each other's replies.
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
