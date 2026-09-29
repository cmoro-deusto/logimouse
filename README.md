# logimouse

Reads everything a Logitech device on a Logi Bolt receiver reports (name, firmware,
battery, DPI, scroll wheel, Easy-Switch, buttons) and the receiver's own details, by
talking HID++ directly over `/dev/hidraw`. It can also change the DPI. No runtime
dependencies.

The repository also holds **Logi Mouse**, a [Noctalia](https://noctalia.dev) plugin
built on it: battery, charging state and DPI in the bar, and a panel with everything
else. See [`logimouse/README.md`](logimouse/README.md).

## Install

```sh
./install.sh      # the logimouse and logi commands, plus the Noctalia plugin if Noctalia is installed
./uninstall.sh    # removes all of it
```

The commands go to `~/.local/bin` through `uv tool install --editable`, so edits to
the source take effect without reinstalling. When `noctalia` is on `PATH`, the script
also registers this directory as the plugin source `logimouse` and enables
`cmoro-deusto/logimouse`. Add the widget to the bar yourself, from Settings → Bar.

## Usage

```sh
logimouse                    # device and receiver info
logimouse --json             # the same, as JSON (what the Noctalia plugin reads)
logimouse dpi                # show the current DPI
logimouse dpi up             # next supported DPI step
logimouse dpi down           # previous supported DPI step
logimouse dpi 1200           # set an exact value
logimouse --slot 2 dpi up    # pick a device when several are paired
```

`logi` is the same command. With `--json`, errors are printed as
`{"ok": false, "error": "..."}` with exit code 1.

DPI changes are held in the device's working memory and can revert to the default
after the device powers off or reconnects.

The current user needs read/write access to the device's hidraw nodes. For a device
without it, run `./grant-access.sh`: it lists the Logitech devices with their access
and any udev rule covering them, and adds a persistent rule
(`/etc/udev/rules.d/70-logimouse.rules`) or a temporary ACL for the ones you pick,
asking before each `sudo` step. It can remove its rules too.

## Tests

```sh
make test
```

That runs the Python tests (`uv run pytest`), which replay HID++ replies recorded from
an MX Anywhere 3S for Business in `tests/fixtures/`, then the plugin's model tests
(`lua`) and its static check against Noctalia's API definitions (`python3` 3.11+,
needs the network for that part).
