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

-- "1000 Hz", or "" when the device does not report its rate.
function M.reportRateText(rate)
  if type(rate) ~= "table" or tonumber(rate.current) == nil then
    return ""
  end
  return string.format("%d Hz", tonumber(rate.current))
end

-- Where the current rate sits among the supported ones, 0..1: the rates are powers
-- of two apart, so the bar moves by position in the list rather than by Hz.
function M.rateFraction(rate)
  if type(rate) ~= "table" or type(rate.supported) ~= "table" or #rate.supported < 2 then
    return 0
  end
  for i, hz in ipairs(rate.supported) do
    if hz == rate.current then
      return (i - 1) / (#rate.supported - 1)
    end
  end
  return 0
end

function M.canRateDown(rate)
  return type(rate) == "table" and type(rate.supported) == "table" and #rate.supported > 0
    and tonumber(rate.current) ~= nil and tonumber(rate.current) > rate.supported[1]
end

function M.canRateUp(rate)
  return type(rate) == "table" and type(rate.supported) == "table" and #rate.supported > 0
    and tonumber(rate.current) ~= nil and tonumber(rate.current) < rate.supported[#rate.supported]
end

-- "125 · 250 · 500 · 1000 Hz"
function M.ratesText(rate)
  if type(rate) ~= "table" or type(rate.supported) ~= "table" or #rate.supported == 0 then
    return ""
  end
  local parts = {}
  for _, hz in ipairs(rate.supported) do
    parts[#parts + 1] = tostring(hz)
  end
  return table.concat(parts, " · ") .. " Hz"
end

-- Whether the report rate can be changed now: not while the onboard profile sets it.
function M.rateSettable(info)
  return type(info) == "table" and type(info.reportRate) == "table" and info.profileMode ~= "onboard"
end

-- Which of the optional cards a device has anything for: a gaming mouse such as the
-- PRO X has no SmartShift, no Easy-Switch and keeps its buttons elsewhere.
function M.sections(info)
  info = info or {}
  return {
    wheel = info.smartShift ~= nil or info.wheel ~= nil,
    hosts = type(info.hosts) == "table" and #info.hosts > 0,
    buttons = type(info.buttons) == "table" and #info.buttons > 0,
  }
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

-- A device's identity across reads: its unit ID, which survives a move to another
-- receiver slot or node, or where it is connected when it has none.
function M.deviceKey(info)
  if type(info) ~= "table" then
    return nil
  end
  if info.unitId and info.unitId ~= "" then
    return info.unitId
  end
  local connection = info.connection or {}
  if connection.type == "receiver" then
    return tostring(connection.receiver) .. "#" .. tostring(connection.slot)
  end
  return tostring(connection.path)
end

-- "Logi Bolt receiver" -> "Bolt": the short form the device list has room for.
function M.shortReceiver(name)
  local short = tostring(name or "receiver"):gsub("^Logi ", ""):gsub(" receiver$", "")
  return short
end

-- "Bolt · 2" or "USB".
function M.connectionShort(info)
  local connection = info and info.connection or {}
  if connection.type == "receiver" then
    return M.shortReceiver(connection.receiverName) .. " · " .. tostring(connection.slot)
  end
  if connection.type == "direct" then
    return "USB"
  end
  return ""
end

-- The number in /dev/hidrawN, so hidraw13 sorts after hidraw6.
local function nodeNumber(path)
  return tonumber(tostring(path or ""):match("(%d+)$")) or 0
end

-- Devices on receivers first, by receiver node and slot, then direct ones by node.
-- It depends only on where a device is connected, so rows do not move when a
-- device sleeps or wakes.
local function sortKey(entry)
  local connection = entry.info and entry.info.connection or {}
  if connection.type == "receiver" then
    return 0, nodeNumber(connection.receiver), tonumber(connection.slot) or 0
  end
  return 1, nodeNumber(connection.path), 0
end

function M.sortDevices(devices)
  table.sort(devices, function(a, b)
    local a1, a2, a3 = sortKey(a)
    local b1, b2, b3 = sortKey(b)
    if a1 ~= b1 then
      return a1 < b1
    end
    if a2 ~= b2 then
      return a2 < b2
    end
    if a3 ~= b3 then
      return a3 < b3
    end
    return tostring(a.key) < tostring(b.key)
  end)
  return devices
end

-- The device the bar reflects when none is chosen: the first online one with a
-- battery, then the first online one, then the first known one. `devices` is the
-- service's list of { key, online, lastSeen, info }.
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

-- The device named by the bar_device setting: part of its name, case-insensitive,
-- or its unit ID. Empty means primaryDevice. Returns nil when nothing matches.
function M.barDevice(devices, wanted)
  wanted = tostring(wanted or ""):match("^%s*(.-)%s*$")
  if wanted == "" then
    return M.primaryDevice(devices)
  end
  local lower = wanted:lower()
  for _, entry in ipairs(devices or {}) do
    local info = entry.info or {}
    if tostring(info.unitId or ""):lower() == lower then
      return entry
    end
  end
  for _, entry in ipairs(devices or {}) do
    local info = entry.info or {}
    if tostring(info.name or ""):lower():find(lower, 1, true) then
      return entry
    end
  end
  return nil
end

function M.findDevice(devices, key)
  if type(devices) ~= "table" then
    return nil
  end
  for _, entry in ipairs(devices) do
    if entry.key == key then
      return entry
    end
  end
  return nil
end

function M.findReceiver(receivers, path)
  for _, receiver in ipairs(receivers or {}) do
    if receiver.path == path then
      return receiver
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

-- "mouse · Bolt slot 2 · “MX Anywhere3SB”", or "mouse · USB".
function M.subtitle(entry)
  local info = entry and entry.info or {}
  local parts = {}
  if info.type then
    parts[#parts + 1] = info.type
  end
  local connection = info.connection or {}
  if connection.type == "receiver" then
    parts[#parts + 1] = M.shortReceiver(connection.receiverName) .. " slot " .. tostring(connection.slot)
  elseif connection.type == "direct" then
    parts[#parts + 1] = "USB"
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
  local entry = M.barDevice(data.devices, cfg.barDevice)

  if entry == nil or entry.info == nil then
    local reason = data.error
    local wanted = tostring(cfg.barDevice or ""):match("^%s*(.-)%s*$")
    if (reason == nil or reason == "") and wanted ~= "" and #(data.devices or {}) > 0 then
      reason = "no device matches “" .. wanted .. "”"
    end
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

-- Merge a fresh report into the devices already known. A device on a receiver that
-- still lists its slot as paired keeps its last values, marked offline, when it does
-- not answer; a device connected directly is dropped once it is gone, since its node
-- goes with it. Returns a new list in display order.
function M.mergeDevices(known, report, now)
  local byKey = {}
  for _, entry in ipairs(known or {}) do
    byKey[entry.key] = { key = entry.key, online = false, lastSeen = entry.lastSeen, info = entry.info }
  end
  local fresh = {}
  local freshSlots = {}
  for _, info in ipairs(report.devices or {}) do
    local key = M.deviceKey(info)
    byKey[key] = { key = key, online = true, lastSeen = now, info = info }
    fresh[key] = true
    local connection = info.connection or {}
    if connection.type == "receiver" then
      freshSlots[tostring(connection.receiver) .. "#" .. tostring(connection.slot)] = true
    end
  end
  local paired = {}
  for _, receiver in ipairs(report.receivers or {}) do
    for _, slot in ipairs(receiver.slots or {}) do
      paired[tostring(receiver.path) .. "#" .. tostring(slot.slot)] = true
    end
  end
  local out = {}
  for key, entry in pairs(byKey) do
    local connection = entry.info and entry.info.connection or {}
    local slotKey = tostring(connection.receiver) .. "#" .. tostring(connection.slot)
    -- A remembered device keeps its slot only while nothing else has been read there:
    -- a fresh device in the same slot replaces it (a re-pairing, or a bad read).
    local stillPaired = connection.type == "receiver" and paired[slotKey] and not freshSlots[slotKey]
    if fresh[key] or stillPaired then
      out[#out + 1] = entry
    end
  end
  return M.sortDevices(out)
end

-- Every device marked offline, values kept: what a failed read leaves behind.
function M.markOffline(known)
  local out = {}
  for _, entry in ipairs(known or {}) do
    out[#out + 1] = { key = entry.key, online = false, lastSeen = entry.lastSeen, info = entry.info }
  end
  return out
end

return M
