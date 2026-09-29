# logimouse

Reads everything a Logitech HID++ device reports (name, firmware, battery, DPI, scroll
wheel, Easy-Switch, buttons), for devices on a Logi Bolt receiver and devices
connected directly by USB, plus each receiver's own details, by talking HID++ over
`/dev/hidraw`. It can also change the DPI. No runtime dependencies.

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
logimouse                            # every device and receiver
logimouse --json                     # the same, as JSON (what the Noctalia plugin reads)
logimouse dpi                        # show the current DPI
logimouse dpi up                     # next supported DPI step
logimouse dpi down                   # previous supported DPI step
logimouse dpi 1200                   # set an exact value
logimouse --device 829A24C0 dpi up   # pick a device by the unit ID the report shows
logimouse --slot 2 dpi up            # or by its receiver slot
logimouse rate                       # report rate and profile mode
logimouse rate up|down|<Hz>          # change the report rate
logimouse mode host|onboard          # onboard-profile mode (gaming mice)
```

On a mouse with onboard profiles (such as the PRO X Wireless), the stored profile
sets the report rate and the mouse refuses a change: switch to host mode first.
Host mode turns the profile (its buttons, DPI levels, lighting) off until you switch
back with `logimouse mode onboard`.

Runs are serialized with a lock (`$XDG_RUNTIME_DIR/logimouse.lock`): receivers answer
one request at a time, and concurrent runs would read each other's replies.

Without `--device` or `--slot`, `dpi` and `rate` act on the first device that
supports them.
Every Logitech hidraw node that carries HID++ is read; a node the user cannot open
is listed under "Not accessible" instead of stopping the rest.

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
