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

local ALL_ON = { showIcon = true, showBattery = true, showCharging = true, showDpi = true, batteryWarn = 20, batteryLow = 10 }

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

-- ── devices ─────────────────────────────────────────────────────────────────

local keyboard = { slot = 1, online = true, info = { slot = 1, name = "Keyboard" } }
local asleep = { slot = 2, online = false, lastSeen = NOW - 600, info = mouse() }
local awake = { slot = 2, online = true, lastSeen = NOW, info = mouse() }
eq(model.primaryDevice({ keyboard, awake }).slot, 2, "an online device with a battery comes first")
eq(model.primaryDevice({ keyboard, asleep }).slot, 1, "then any online device")
eq(model.primaryDevice({ asleep }).slot, 2, "then the first known one")
eq(model.primaryDevice({}), nil, "nothing known")
eq(model.subtitle(awake), "mouse · slot 2 · “MX Anywhere3SB”", "subtitle")
eq(model.firmware(mouse(), "main"), "RBM24.01.B0006", "main firmware")

-- mergeDevices: a device that stops answering keeps its values while it is paired.
local report = { devices = { mouse() }, receiver = { slots = { { slot = 2 } } } }
local merged = model.mergeDevices({}, report, NOW)
eq(#merged, 1, "one device after the first read")
eq(merged[1].online, true, "online after a read that found it")
eq(merged[1].lastSeen, NOW, "last seen is the read time")

merged = model.mergeDevices(merged, { devices = {}, receiver = { slots = { { slot = 2 } } } }, NOW + 300)
eq(#merged, 1, "kept while still paired")
eq(merged[1].online, false, "offline when it did not answer")
eq(merged[1].lastSeen, NOW, "last seen unchanged")
eq(merged[1].info.dpi.current, 800, "last values kept")

merged = model.mergeDevices(merged, { devices = {}, receiver = { slots = {} } }, NOW + 600)
eq(#merged, 0, "dropped once unpaired")

local offline = model.markOffline({ awake })
eq(offline[1].online, false, "markOffline marks offline")
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

local charging = { slot = 2, online = true, lastSeen = NOW, info = mouse({ battery = { percent = 5, status = "charging", charging = true } }) }
bar = model.barModel({ devices = { charging } }, cfg(), NOW)
eq(bar.charging, true, "charging bolt")
eq(bar.icon, "mouse", "charging is not a warning")
eq(bar.battery.color, "on_surface", "charging has no alarm colour")
bar = model.barModel({ devices = { charging } }, cfg({ showCharging = false }), NOW)
eq(bar.charging, false, "bolt hidden by the setting")
bar = model.barModel({ devices = { charging } }, cfg({ showBattery = false }), NOW)
eq(bar.battery, nil, "battery hidden by the setting")
eq(bar.charging, true, "bolt independent of the battery setting")

local low = { slot = 2, online = true, lastSeen = NOW, info = mouse({ battery = { percent = 8, status = "discharging", charging = false } }) }
bar = model.barModel({ devices = { low } }, cfg(), NOW)
eq(bar.icon, "alert-triangle", "low battery swaps the icon")
eq(bar.iconColor, "error", "low battery icon colour")
eq(bar.battery.color, "error", "low battery colour")

local warned = { slot = 2, online = true, lastSeen = NOW, info = mouse({ battery = { percent = 18, charging = false } }) }
eq(model.barModel({ devices = { warned } }, cfg(), NOW).battery.color, model.COLOR_WARN, "warning colour")

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
