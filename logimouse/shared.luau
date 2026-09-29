--!nonstrict
-- The model: what `logimouse --json` reports in, what the bar widget and the panel
-- paint out.
--
-- Pure: it calls nothing on `noctalia.*` and reads no clock. Anything that depends
-- on the time takes it as an argument, in whole seconds, so tests/shared_test.lua
-- can run this file under plain Lua 5.4 with a fixed clock. That is also why it is
-- written in the subset of Luau that Lua accepts: no type annotations, no
-- `continue`, no compound assignment.

local M = {}

-- The amber the warning level draws in. The theme has an error role but no warning
-- role, so this one is fixed; it is the same amber other plugins use.
M.COLOR_WARN = "#ff7800"
M.COLOR_LOW = "error"
M.COLOR_NORMAL = "on_surface"

M.DEFAULT_WARN = 20
M.DEFAULT_LOW = 10

-- ── Battery ─────────────────────────────────────────────────────────────────

-- The two thresholds as the widget applies them. The settings page cannot keep one
-- below the other, so when warn is at or below low, low wins and there is no amber
-- band at all.
function M.thresholds(warn, low)
  warn = tonumber(warn) or M.DEFAULT_WARN
  low = tonumber(low) or M.DEFAULT_LOW
  if warn <= low then
    warn = low
  end
  return warn, low
end

-- "charging" | "low" | "warn" | "ok" | "unknown". Charging wins over the thresholds:
-- the value is going up, so it is not a warning.
function M.batteryLevel(battery, warn, low)
  if type(battery) ~= "table" or tonumber(battery.percent) == nil then
    return "unknown"
  end
  if battery.charging == true then
    return "charging"
  end
  warn, low = M.thresholds(warn, low)
  local percent = tonumber(battery.percent)
  if percent <= low then
    return "low"
  end
  if percent <= warn then
    return "warn"
  end
  return "ok"
end

function M.levelColor(level)
  if level == "low" then
    return M.COLOR_LOW
  end
  if level == "warn" then
    return M.COLOR_WARN
  end
  return M.COLOR_NORMAL
end

function M.percentText(battery)
  if type(battery) ~= "table" or tonumber(battery.percent) == nil then
    return "—"
  end
  return string.format("%d%%", tonumber(battery.percent))
end

-- ── Time ────────────────────────────────────────────────────────────────────

-- How long ago, in the words the tooltip and the panel header use.
function M.agoText(seconds)
  seconds = math.max(0, math.floor(tonumber(seconds) or 0))
  if seconds < 60 then
    return "just now"
  end
  if seconds < 3600 then
    return string.format("%d min ago", seconds // 60)
  end
  if seconds < 86400 then
    return string.format("%d h ago", seconds // 3600)
  end
  return string.format("%d d ago", seconds // 86400)
end

-- ── DPI ─────────────────────────────────────────────────────────────────────

function M.dpiText(dpi)
  if type(dpi) ~= "table" or tonumber(dpi.current) == nil then
    return "—"
  end
  return tostring(math.floor(tonumber(dpi.current)))
end

function M.dpiRangeText(dpi)
  if type(dpi) ~= "table" or dpi.min == nil or dpi.max == nil then
    return ""
  end
  local text = string.format("%d–%d", dpi.min, dpi.max)
  if tonumber(dpi.step) then
    text = text .. string.format(" · step %d", dpi.step)
  end
  return text
end

-- Where the current value sits in the supported range, 0..1, for the panel's bar.
function M.dpiFraction(dpi)
  if type(dpi) ~= "table" then
    return 0
  end
  local low, high, current = tonumber(dpi.min), tonumber(dpi.max), tonumber(dpi.current)
  if low == nil or high == nil or current == nil or high <= low then
    return 0
  end
  return math.max(0, math.min(1, (current - low) / (high - low)))
end

function M.canDpiDown(dpi)
  return type(dpi) == "table" and tonumber(dpi.current) ~= nil and tonumber(dpi.min) ~= nil
    and tonumber(dpi.current) > tonumber(dpi.min)
end

function M.canDpiUp(dpi)
  return type(dpi) == "table" and tonumber(dpi.current) ~= nil and tonumber(dpi.max) ~= nil
    and tonumber(dpi.current) < tonumber(dpi.max)
end

-- ── Devices ─────────────────────────────────────────────────────────────────

-- The device the bar reflects: the first online one with a battery, then the first
-- online one, then the first known one. `devices` is the service's list of
-- { slot, online, lastSeen, info }.
function M.primaryDevice(devices)
  if type(devices) ~= "table" then
    return nil
  end
  for _, entry in ipairs(devices) do
    if entry.online and entry.info and entry.info.battery then
      return entry
    end
  end
  for _, entry in ipairs(devices) do
    if entry.online then
      return entry
    end
  end
  return devices[1]
end

function M.findDevice(devices, slot)
  if type(devices) ~= "table" then
    return nil
  end
  for _, entry in ipairs(devices) do
    if entry.slot == slot then
      return entry
    end
  end
  return nil
end

-- The firmware entry of the given type ("main"), or nil.
function M.firmware(info, kind)
  if type(info) ~= "table" or type(info.firmware) ~= "table" then
    return nil
  end
  for _, fw in ipairs(info.firmware) do
    if fw.type == kind then
      return fw.version
    end
  end
  return nil
end

-- "mouse · slot 2 · “MX Anywhere3SB”"
function M.subtitle(entry)
  local info = entry and entry.info or {}
  local parts = {}
  if info.type then
    parts[#parts + 1] = info.type
  end
  if entry and entry.slot then
    parts[#parts + 1] = "slot " .. tostring(entry.slot)
  end
  if info.friendlyName and info.friendlyName ~= "" and info.friendlyName ~= info.name then
    parts[#parts + 1] = "“" .. info.friendlyName .. "”"
  end
  return table.concat(parts, " · ")
end

-- ── Bar ─────────────────────────────────────────────────────────────────────

-- What the bar widget paints, from the service's data and the settings:
--
--   { empty, icon, iconColor, battery = { text, color }?, charging, dpi?, dim, tooltip }
--
-- `empty` means there is nothing to show but the icon and a dash. `dim` means the
-- values are the last ones seen, from a device that is asleep or unreachable.
function M.barModel(data, cfg, now)
  local model = { empty = true, icon = "mouse-off", iconColor = M.COLOR_NORMAL, charging = false, dim = false, tooltip = {} }
  data = data or {}
  local entry = M.primaryDevice(data.devices)

  if entry == nil or entry.info == nil then
    local reason = data.error
    if reason == nil or reason == "" then
      reason = "waiting for the first reading"
    end
    model.tooltip = { { key = "logimouse", value = reason } }
    return model
  end

  local info = entry.info
  local level = M.batteryLevel(info.battery, cfg.batteryWarn, cfg.batteryLow)
  model.empty = false
  model.dim = entry.online ~= true
  model.icon = "mouse"
  if level == "low" then
    model.icon = "alert-triangle"
    model.iconColor = M.COLOR_LOW
  end
  if cfg.showBattery and info.battery then
    model.battery = { text = M.percentText(info.battery), color = M.levelColor(level) }
  end
  model.charging = cfg.showCharging and level == "charging"
  if cfg.showDpi and info.dpi then
    model.dpi = M.dpiText(info.dpi)
  end

  local rows = { { key = info.name or "Mouse", value = entry.online and "online" or "asleep" } }
  if info.battery then
    local value = M.percentText(info.battery)
    if info.battery.status then
      value = value .. " · " .. info.battery.status
    end
    rows[#rows + 1] = { key = "Battery", value = value }
  end
  if info.dpi then
    rows[#rows + 1] = { key = "DPI", value = M.dpiText(info.dpi) }
  end
  if not entry.online and entry.lastSeen then
    rows[#rows + 1] = { key = "Last seen", value = M.agoText(now - entry.lastSeen) }
  end
  if data.error and data.error ~= "" then
    rows[#rows + 1] = { key = "Error", value = data.error }
  end
  model.tooltip = rows
  return model
end

-- ── Service ─────────────────────────────────────────────────────────────────

-- Merge a fresh report into the devices already known. A device the receiver still
-- lists as paired but that did not answer keeps its last values, marked offline;
-- one that is no longer paired is dropped. Returns a new list sorted by slot.
function M.mergeDevices(known, report, now)
  local bySlot = {}
  for _, entry in ipairs(known or {}) do
    bySlot[entry.slot] = { slot = entry.slot, online = false, lastSeen = entry.lastSeen, info = entry.info }
  end
  for _, info in ipairs(report.devices or {}) do
    bySlot[info.slot] = { slot = info.slot, online = true, lastSeen = now, info = info }
  end
  local paired = {}
  local receiver = report.receiver
  if type(receiver) == "table" and type(receiver.slots) == "table" then
    for _, slot in ipairs(receiver.slots) do
      paired[slot.slot] = true
    end
  end
  local out = {}
  for slot, entry in pairs(bySlot) do
    if entry.online or paired[slot] then
      out[#out + 1] = entry
    end
  end
  table.sort(out, function(a, b)
    return a.slot < b.slot
  end)
  return out
end

-- Every device marked offline, values kept: what a failed read leaves behind.
function M.markOffline(known)
  local out = {}
  for _, entry in ipairs(known or {}) do
    out[#out + 1] = { slot = entry.slot, online = false, lastSeen = entry.lastSeen, info = entry.info }
  end
  return out
end

return M
