--!nonstrict
-- The reader: the one part of this plugin that runs `logimouse`.
--
-- It runs `logimouse --json` once per interval and publishes the result on the
-- plugin's shared state under "data". The bar widget and the panel only read that.
-- It also runs the panel's DPI changes, published under "dpi_request", so that only
-- one `logimouse` process talks to the receiver at a time: two processes reading
-- the same hidraw node would each see the other's replies.
--
-- Devices that stop answering (a mouse asleep or switched off) keep their last
-- values, marked offline, for as long as the receiver still lists them as paired.
-- Nothing is written to disk, so after a restart the widget shows a dash until the
-- first reading.

local shared = require("./shared.luau")

local DATA_KEY = "data"
local REFRESH_KEY = "refresh"
local DPI_KEY = "dpi_request"

local TIMEOUT_MS = 20000
local FALLBACK_PATH = "~/.local/bin/logimouse"

local state = {
  devices = {},
  receiver = nil,
  error = "",
  notice = "",
  fetchedAt = nil,
  busy = false,
}

local running = false
local refreshQueued = false
local dpiQueued = nil

local function publish()
  -- A new table every time, so the host sees a change and notifies the watchers.
  noctalia.state.set(DATA_KEY, {
    devices = state.devices,
    receiver = state.receiver,
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
      state.receiver = report.receiver
      state.fetchedAt = os.time()
    end
    publish()
  end)
end

local function changeDpi(request)
  local cmd = command()
  if cmd == nil then
    state.notice = "logimouse not found on PATH"
    publish()
    return
  end
  local argv = { cmd, "--json" }
  if tonumber(request.slot) then
    argv[#argv + 1] = "--slot"
    argv[#argv + 1] = tostring(math.floor(tonumber(request.slot)))
  end
  argv[#argv + 1] = "dpi"
  argv[#argv + 1] = tostring(request.action)
  local startedMs = noctalia.nowMs()
  run(argv, function(result)
    local _, reason = decode(result)
    noctalia.log(string.format("logimouse: ran [%s] in %d ms: exit %s, stdout %s, stderr %s",
      table.concat(argv, " "), noctalia.nowMs() - startedMs, tostring(result.exitCode),
      noctalia.string.trim(result.stdout or ""), noctalia.string.trim(result.stderr or "")))
    state.notice = reason or ""
    -- Read everything again, so the new value shows as the mouse reports it.
    refreshQueued = true
    publish()
  end)
end

-- One job at a time: a queued DPI change first, then a queued read.
nextJob = function()
  if running then
    return
  end
  if dpiQueued ~= nil then
    local request = dpiQueued
    dpiQueued = nil
    changeDpi(request)
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

noctalia.state.watch(DPI_KEY, function(request)
  if type(request) ~= "table" or request.action == nil then
    return
  end
  dpiQueued = request
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
