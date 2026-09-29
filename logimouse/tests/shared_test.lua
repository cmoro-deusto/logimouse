--!nonstrict
-- Tests for shared.luau: the model, under a fixed clock and with no host at all.
--
--   lua tests/shared_test.lua

local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
local model = dofile(here .. "/../shared.luau")

local checks, failures = 0, {}

local function check(ok, what)
  checks = checks + 1
  if not ok then
    failures[#failures + 1] = what
  end
end

local function eq(got, want, what)
  check(got == want, string.format("%s: got %s, want %s", what, tostring(got), tostring(want)))
end

local NOW = 1790000000

local function mouse(overrides)
  local info = {
    slot = 2,
    unitId = "829A24C0",
    connection = { type = "receiver", receiver = "/dev/hidraw6", receiverName = "Logi Bolt receiver", slot = 2 },
    name = "MX Anywhere 3S for Business",
    type = "mouse",
    friendlyName = "MX Anywhere3SB",
    battery = { percent = 75, level = "full", status = "discharging", charging = false, externalPower = false },
    dpi = { current = 800, default = 1000, min = 200, max = 8000, step = 50 },
    firmware = { { type = "bootloader", version = "BL193.01.B0006" }, { type = "main", version = "RBM24.01.B0006" } },
  }
  for key, value in pairs(overrides or {}) do
    info[key] = value
  end
  return info
end

local ALL_ON = { showIcon = true, showBattery = true, showCharging = true, showDpi = true, barDevice = "", batteryWarn = 20, batteryLow = 10 }

local function cfg(overrides)
  local out = {}
  for key, value in pairs(ALL_ON) do
    out[key] = value
  end
  for key, value in pairs(overrides or {}) do
    out[key] = value
  end
  return out
end

-- ── thresholds and levels ───────────────────────────────────────────────────

local warn, low = model.thresholds(20, 10)
eq(warn, 20, "warn kept when above low")
eq(low, 10, "low kept")
warn, low = model.thresholds(20, 25)
eq(warn, 25, "warn at or below low collapses onto low")
warn, low = model.thresholds(nil, nil)
eq(warn, 20, "warn default")
eq(low, 10, "low default")

eq(model.batteryLevel({ percent = 75 }, 20, 10), "ok", "75% is ok")
eq(model.batteryLevel({ percent = 20 }, 20, 10), "warn", "at the warning level is warn")
eq(model.batteryLevel({ percent = 11 }, 20, 10), "warn", "between the levels is warn")
eq(model.batteryLevel({ percent = 10 }, 20, 10), "low", "at the low level is low")
eq(model.batteryLevel({ percent = 3, charging = true }, 20, 10), "charging", "charging wins over low")
eq(model.batteryLevel({ percent = 22 }, 20, 25), "low", "low wins when the levels are inverted")
eq(model.batteryLevel(nil, 20, 10), "unknown", "no battery")

eq(model.levelColor("low"), "error", "low colour")
eq(model.levelColor("warn"), model.COLOR_WARN, "warn colour")
eq(model.levelColor("charging"), "on_surface", "charging has no alarm colour")
eq(model.percentText({ percent = 75 }), "75%", "percent text")
eq(model.percentText(nil), "—", "percent text without a battery")

-- ── time ────────────────────────────────────────────────────────────────────

eq(model.agoText(30), "just now", "under a minute")
eq(model.agoText(12 * 60 + 5), "12 min ago", "minutes")
eq(model.agoText(3 * 3600), "3 h ago", "hours")
eq(model.agoText(2 * 86400 + 5), "2 d ago", "days")
eq(model.agoText(-5), "just now", "clock skew floors at zero")

-- ── DPI ─────────────────────────────────────────────────────────────────────

local dpi = { current = 800, default = 1000, min = 200, max = 8000, step = 50 }
eq(model.dpiText(dpi), "800", "dpi text")
eq(model.dpiText(nil), "—", "dpi text without dpi")
eq(model.dpiRangeText(dpi), "200–8000 · step 50", "range text")
eq(model.dpiFraction({ current = 4100, min = 200, max = 8000 }), 0.5, "fraction midway")
eq(model.dpiFraction(nil), 0, "fraction without dpi")
eq(model.canDpiDown({ current = 200, min = 200, max = 8000 }), false, "no step down at the minimum")
eq(model.canDpiUp({ current = 8000, min = 200, max = 8000 }), false, "no step up at the maximum")
eq(model.canDpiUp(dpi), true, "step up in range")
eq(model.reportRateText({ current = 1000, supported = { 125, 250, 500, 1000 } }), "1000 Hz", "report rate")
eq(model.reportRateText(nil), "", "no report rate")
local RATE = { current = 500, supported = { 125, 250, 500, 1000 } }
eq(model.rateFraction(RATE), 2 / 3, "rate position among the supported ones")
eq(model.canRateUp(RATE), true, "a higher rate exists")
eq(model.canRateDown({ current = 125, supported = { 125, 250, 500, 1000 } }), false, "no rate below the lowest")
eq(model.canRateUp({ current = 1000, supported = { 125, 250, 500, 1000 } }), false, "no rate above the highest")
eq(model.ratesText(RATE), "125 · 250 · 500 · 1000 Hz", "supported rates")
eq(model.rateSettable({ reportRate = RATE, profileMode = "onboard" }), false, "the onboard profile owns the rate")
eq(model.rateSettable({ reportRate = RATE, profileMode = "host" }), true, "host mode can change it")
eq(model.rateSettable({ reportRate = RATE }), true, "no onboard profiles: always settable")
eq(model.rateSettable({}), false, "no report rate feature")

local full = model.sections({ smartShift = {}, hosts = { {} }, buttons = { {} } })
eq(full.wheel and full.hosts and full.buttons, true, "every section for a device that has them")
local gaming = model.sections({ smartShift = nil, wheel = nil, hosts = nil, buttons = nil })
eq(gaming.wheel or gaming.hosts or gaming.buttons, false, "no optional section for a device without them")
eq(model.sections({ wheel = {} }).wheel, true, "the wheel section needs only one of the two features")
eq(model.sections({ hosts = {} }).hosts, false, "an empty host list is no section")

-- ── devices ─────────────────────────────────────────────────────────────────

local BOLT = { type = "receiver", receiver = "/dev/hidraw6", receiverName = "Logi Bolt receiver", slot = 2 }
local USB = { type = "direct", path = "/dev/hidraw13", usbId = "046d:c094", product = "PRO X Wireless" }

eq(model.deviceKey(mouse()), "829A24C0", "the unit ID is the key")
eq(model.deviceKey({ connection = BOLT }), "/dev/hidraw6#2", "without a unit ID, the receiver slot")
eq(model.deviceKey({ connection = USB }), "/dev/hidraw13", "without a unit ID, the node")
eq(model.shortReceiver("Logi Bolt receiver"), "Bolt", "short receiver name")
eq(model.connectionShort({ connection = BOLT }), "Bolt · 2", "receiver connection")
eq(model.connectionShort({ connection = USB }), "USB", "direct connection")

local keyboard = { key = "K1", online = true, info = { name = "Keyboard", unitId = "K1", connection = { type = "receiver", receiver = "/dev/hidraw6", slot = 1 } } }
local asleep = { key = "829A24C0", online = false, lastSeen = NOW - 600, info = mouse() }
local awake = { key = "829A24C0", online = true, lastSeen = NOW, info = mouse() }
local prox = { key = "AABBCCDD", online = true, lastSeen = NOW, info = mouse({ name = "PRO X Wireless", unitId = "AABBCCDD", connection = USB }) }
eq(model.primaryDevice({ keyboard, awake }).key, "829A24C0", "an online device with a battery comes first")
eq(model.primaryDevice({ keyboard, asleep }).key, "K1", "then any online device")
eq(model.primaryDevice({ asleep }).key, "829A24C0", "then the first known one")
eq(model.primaryDevice({}), nil, "nothing known")

eq(model.barDevice({ awake, prox }, "").key, "829A24C0", "no bar_device picks automatically")
eq(model.barDevice({ awake, prox }, "pro x").key, "AABBCCDD", "bar_device matches part of the name")
eq(model.barDevice({ awake, prox }, "aabbccdd").key, "AABBCCDD", "bar_device matches the unit ID")
eq(model.barDevice({ awake, prox }, "  "), awake, "a blank bar_device picks automatically")
eq(model.barDevice({ awake, prox }, "G502"), nil, "bar_device with no match")

local ordered = model.sortDevices({ prox, awake, keyboard })
eq(ordered[1].key, "K1", "receiver slot 1 first")
eq(ordered[2].key, "829A24C0", "then receiver slot 2")
eq(ordered[3].key, "AABBCCDD", "direct devices last")

eq(model.subtitle(awake), "mouse · Bolt slot 2 · “MX Anywhere3SB”", "subtitle on a receiver")
eq(model.subtitle(prox), "mouse · USB · “MX Anywhere3SB”", "subtitle for a direct device")
eq(model.firmware(mouse(), "main"), "RBM24.01.B0006", "main firmware")

-- mergeDevices: a device on a receiver keeps its values while its slot is paired;
-- a direct device goes when it does.
local PAIRED = { { path = "/dev/hidraw6", slots = { { slot = 2 } } } }
local report = { devices = { mouse(), prox.info }, receivers = PAIRED }
local merged = model.mergeDevices({}, report, NOW)
eq(#merged, 2, "two devices after the first read")
eq(merged[1].key, "829A24C0", "the receiver device first")
eq(merged[1].online, true, "online after a read that found it")
eq(merged[1].lastSeen, NOW, "last seen is the read time")

merged = model.mergeDevices(merged, { devices = {}, receivers = PAIRED }, NOW + 300)
eq(#merged, 1, "the direct device is dropped once gone")
eq(merged[1].online, false, "the receiver device is offline when it did not answer")
eq(merged[1].lastSeen, NOW, "last seen unchanged")
eq(merged[1].info.dpi.current, 800, "last values kept")

merged = model.mergeDevices(merged, { devices = {}, receivers = { { path = "/dev/hidraw6", slots = {} } } }, NOW + 600)
eq(#merged, 0, "dropped once unpaired")

-- A remembered entry in a slot where a fresh read finds another device is replaced:
-- the ghost of a bad read (no unit ID, garbled name) must not linger as "asleep".
local ghost = { key = "/dev/hidraw6#2", online = false, lastSeen = NOW, info = mouse({ unitId = nil, name = "\1BL1" }) }
merged = model.mergeDevices({ ghost }, { devices = { mouse() }, receivers = PAIRED }, NOW + 60)
eq(#merged, 1, "the fresh device replaces the one remembered in its slot")
eq(merged[1].key, "829A24C0", "and it is the fresh one")

local offline = model.markOffline({ awake })
eq(offline[1].online, false, "markOffline marks offline")
eq(offline[1].key, "829A24C0", "markOffline keeps the key")
eq(offline[1].info.name, "MX Anywhere 3S for Business", "markOffline keeps the values")

-- ── bar ─────────────────────────────────────────────────────────────────────

local bar = model.barModel(nil, cfg(), NOW)
eq(bar.empty, true, "no data is empty")
eq(bar.icon, "mouse-off", "no data shows mouse-off")
eq(bar.tooltip[1].value, "waiting for the first reading", "no data tooltip")

bar = model.barModel({ devices = {}, error = "logimouse not found on PATH — run install.sh" }, cfg(), NOW)
eq(bar.tooltip[1].value, "logimouse not found on PATH — run install.sh", "the error is the tooltip")

bar = model.barModel({ devices = { awake } }, cfg(), NOW)
eq(bar.empty, false, "a device is not empty")
eq(bar.icon, "mouse", "mouse icon")
eq(bar.battery.text, "75%", "battery text")
eq(bar.battery.color, "on_surface", "healthy battery keeps the theme colour")
eq(bar.charging, false, "not charging")
eq(bar.dpi, "800", "dpi")
eq(bar.dim, false, "online is not dimmed")

local charging = { key = "829A24C0", online = true, lastSeen = NOW, info = mouse({ battery = { percent = 5, status = "charging", charging = true } }) }
bar = model.barModel({ devices = { charging } }, cfg(), NOW)
eq(bar.charging, true, "charging bolt")
eq(bar.icon, "mouse", "charging is not a warning")
eq(bar.battery.color, "on_surface", "charging has no alarm colour")
bar = model.barModel({ devices = { charging } }, cfg({ showCharging = false }), NOW)
eq(bar.charging, false, "bolt hidden by the setting")
bar = model.barModel({ devices = { charging } }, cfg({ showBattery = false }), NOW)
eq(bar.battery, nil, "battery hidden by the setting")
eq(bar.charging, true, "bolt independent of the battery setting")

local low = { key = "829A24C0", online = true, lastSeen = NOW, info = mouse({ battery = { percent = 8, status = "discharging", charging = false } }) }
bar = model.barModel({ devices = { low } }, cfg(), NOW)
eq(bar.icon, "alert-triangle", "low battery swaps the icon")
eq(bar.iconColor, "error", "low battery icon colour")
eq(bar.battery.color, "error", "low battery colour")

local warned = { key = "829A24C0", online = true, lastSeen = NOW, info = mouse({ battery = { percent = 18, charging = false } }) }
eq(model.barModel({ devices = { warned } }, cfg(), NOW).battery.color, model.COLOR_WARN, "warning colour")

bar = model.barModel({ devices = { awake, prox } }, cfg({ barDevice = "PRO X" }), NOW)
eq(bar.tooltip[1].key, "PRO X Wireless", "the bar follows bar_device")
bar = model.barModel({ devices = { awake } }, cfg({ barDevice = "G502" }), NOW)
eq(bar.empty, true, "bar_device with no match shows a dash")
eq(bar.tooltip[1].value, "no device matches “G502”", "and says why")

bar = model.barModel({ devices = { awake } }, cfg({ showDpi = false }), NOW)
eq(bar.dpi, nil, "dpi hidden by the setting")

bar = model.barModel({ devices = { asleep } }, cfg(), NOW)
eq(bar.dim, true, "asleep is dimmed")
local lastSeen = nil
for _, row in ipairs(bar.tooltip) do
  if row.key == "Last seen" then
    lastSeen = row.value
  end
end
eq(lastSeen, "10 min ago", "asleep tooltip says when it was last seen")

-- ── result ──────────────────────────────────────────────────────────────────

if #failures > 0 then
  for _, failure in ipairs(failures) do
    print("FAIL " .. failure)
  end
  print(string.format("%d of %d checks failed", #failures, checks))
  os.exit(1)
end
print(string.format("ok: %d checks", checks))
