--!nonstrict
-- The reader: the one part of this plugin that runs `logimouse`.
--
-- It runs `logimouse --json` once per interval and publishes the result on the
-- plugin's shared state under "data". The bar widget and the panel only read that.
-- It also runs the panel's changes (DPI, report rate, profile mode), published under
-- "change_request", so that only
-- one `logimouse` process talks to the receiver at a time: two processes reading
-- the same hidraw node would each see the other's replies.
--
-- Devices on a receiver that stop answering (a mouse asleep or switched off) keep
-- their last values, marked offline, for as long as the receiver lists them as paired.
-- Nothing is written to disk, so after a restart the widget shows a dash until the
-- first reading.

local shared = require("./shared.luau")

local DATA_KEY = "data"
local REFRESH_KEY = "refresh"
local CHANGE_KEY = "change_request"
-- The commands a change request may run: `logimouse <command> <action>`.
local COMMANDS = { dpi = true, rate = true, mode = true }

local TIMEOUT_MS = 20000
local FALLBACK_PATH = "~/.local/bin/logimouse"

local state = {
  devices = {},
  receivers = {},
  inaccessible = {},
  error = "",
  notice = nil,
  fetchedAt = nil,
  busy = false,
}

local running = false
local refreshQueued = false
local changeQueued = nil

local function publish()
  -- A new table every time, so the host sees a change and notifies the watchers.
  noctalia.state.set(DATA_KEY, {
    devices = state.devices,
    receivers = state.receivers,
    inaccessible = state.inaccessible,
    error = state.error,
    notice = state.notice,
    fetchedAt = state.fetchedAt,
    busy = running,
  })
end

-- The command to run, or nil. Noctalia's PATH may not include ~/.local/bin when the
-- shell was started by the compositor, so that location is tried too.
local function command()
  if noctalia.commandExists("logimouse") then
    return "logimouse"
  end
  local fallback = noctalia.expandPath(FALLBACK_PATH)
  if noctalia.fileExists(fallback) then
    return fallback
  end
  return nil
end

local function intervalMs()
  local seconds = tonumber(noctalia.getConfig("interval")) or 60
  return math.max(10, math.min(600, seconds)) * 1000
end

local nextJob

-- Decode what the CLI printed. It prints a JSON document on success and on its own
-- errors; anything else (a crash, a missing interpreter) is reported from stderr.
local function decode(result)
  if result.timedOut then
    return nil, "logimouse timed out"
  end
  local document = noctalia.json.decode(result.stdout or "")
  if type(document) ~= "table" then
    local reason = noctalia.string.trim(result.stderr or "")
    if reason == "" then
      reason = "logimouse exited with code " .. tostring(result.exitCode)
    end
    return nil, reason
  end
  if document.ok ~= true then
    return nil, tostring(document.error or "logimouse failed")
  end
  return document, nil
end

local function run(argv, onDone)
  running = true
  publish()
  local started = noctalia.runAsync(argv, function(result)
    running = false
    onDone(result)
    nextJob()
  end, TIMEOUT_MS)
  if started == false then
    running = false
    onDone({ exitCode = -1, stdout = "", stderr = "could not start " .. argv[1], timedOut = false })
    nextJob()
  end
end

local function read()
  local cmd = command()
  if cmd == nil then
    state.error = "logimouse not found on PATH — run install.sh"
    state.devices = shared.markOffline(state.devices)
    publish()
    return
  end
  run({ cmd, "--json" }, function(result)
    local report, reason = decode(result)
    if report == nil then
      state.error = reason
      state.devices = shared.markOffline(state.devices)
      noctalia.log("logimouse: " .. reason)
    else
      state.error = ""
      state.devices = shared.mergeDevices(state.devices, report, os.time())
      state.receivers = report.receivers or {}
      state.inaccessible = report.inaccessible or {}
      state.fetchedAt = os.time()
    end
    publish()
  end)
end

local function change(request)
  local cmd = command()
  if cmd == nil then
    state.notice = { key = request.key, command = request.command, text = "logimouse not found on PATH" }
    publish()
    return
  end
  -- A device is addressed by its unit ID, which works for one on a receiver and one
  -- connected directly alike.
  local argv = { cmd, "--json" }
  if type(request.unitId) == "string" and request.unitId ~= "" then
    argv[#argv + 1] = "--device"
    argv[#argv + 1] = request.unitId
  end
  argv[#argv + 1] = request.command
  argv[#argv + 1] = tostring(request.action)
  run(argv, function(result)
    local _, reason = decode(result)
    -- The failure belongs to the device it was for, so the panel shows it only there.
    state.notice = reason and { key = request.key, command = request.command, text = reason } or nil
    -- Read everything again, so the new value shows as the mouse reports it.
    refreshQueued = true
    publish()
  end)
end

-- One job at a time: a queued change first, then a queued read.
nextJob = function()
  if running then
    return
  end
  if changeQueued ~= nil then
    local request = changeQueued
    changeQueued = nil
    change(request)
  elseif refreshQueued then
    refreshQueued = false
    read()
  end
end

local function requestRead()
  refreshQueued = true
  nextJob()
end

noctalia.state.watch(REFRESH_KEY, function()
  requestRead()
end)

noctalia.state.watch(CHANGE_KEY, function(request)
  if type(request) ~= "table" or request.action == nil or not COMMANDS[request.command] then
    return
  end
  changeQueued = request
  nextJob()
end)

function onConfigChanged()
  noctalia.setUpdateInterval(intervalMs())
end

function update()
  noctalia.setUpdateInterval(intervalMs())
  requestRead()
end

publish()
noctalia.setUpdateInterval(intervalMs())
requestRead()
