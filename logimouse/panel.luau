--!nonstrict
-- The panel: everything `logimouse` knows about the mouse and the receiver.
--
-- Layout: a column on the left lists every device (then the ones that cannot be
-- opened, then the receivers); the right side describes the selected device, top to
-- bottom: a header with the refresh and settings buttons; battery and DPI side by
-- side; the scroll wheel and Easy-Switch; the buttons as chips; and the device's
-- identity next to how it is connected. The only control that changes anything is
-- the DPI's − and +, which the service runs, so that one `logimouse` process talks to
-- the devices at a time.

local shared = require("./shared.luau")

local CARD = {
  fill = "surface_variant/0.30", radius = 14, padding = 14, gap = 8,
  border = "outline/0.10", borderWidth = 1,
}
local MUTED = "on_surface_variant"
local TRACK = "on_surface/0.10"
local ACCENT = "primary"
local CHIP_FILL = "on_surface/0.06"
local CHIP_BORDER = "outline/0.12"
local CHIPS_PER_ROW = 4
local CLEAR = "#00000000"
local SIDEBAR_WIDTH = 236

local isOpen = false
local selectedKey = nil

local render

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function merge(base, extra)
  local out = {}
  for key, value in pairs(base) do
    out[key] = value
  end
  for key, value in pairs(extra or {}) do
    out[key] = value
  end
  return out
end

local function config()
  return {
    batteryWarn = noctalia.getConfig("battery_warn"),
    batteryLow = noctalia.getConfig("battery_low"),
  }
end

-- ── Building blocks ─────────────────────────────────────────────────────────

local function card(children, extra)
  return ui.column(merge(CARD, extra), children)
end

local function caption(text, glyph)
  return ui.row({ gap = 6, align = "center" }, {
    ui.glyph({ name = glyph, size = 13, color = ACCENT }),
    ui.label({ text = string.upper(text), fontSize = 10, fontWeight = "semibold", color = MUTED }),
  })
end

local function keyValue(label, value, key)
  return ui.row({ key = key, gap = 8, align = "center" }, {
    -- A label sizes to its text, so the fixed column is a row around it.
    ui.row({ width = 92 }, { ui.label({ text = label, fontSize = 11, color = MUTED, maxLines = 1 }) }),
    ui.label({ text = value or "—", fontSize = 12, color = "on_surface", flexGrow = 1, maxLines = 1 }),
  })
end

local function chip(text, extra, key)
  local props = merge({ key = key, gap = 5, align = "center", paddingH = 10, paddingV = 4, radius = 999, fill = CHIP_FILL, border = CHIP_BORDER, borderWidth = 1 }, extra)
  return ui.row(props, { ui.label({ text = text, fontSize = 11, color = "on_surface", maxLines = 1 }) })
end

local function dot(size, fill, border, key)
  return ui.box({ key = key, width = size, height = size, radius = size / 2, fill = fill, border = border or fill, borderWidth = 1 })
end

-- ── Cards ───────────────────────────────────────────────────────────────────

local function header(entry, data)
  local info = entry.info or {}
  local status
  if entry.online then
    status = chip(tr("panel.online"), { fill = "primary/0.14", border = "primary/0.40" })
  else
    local ago = entry.lastSeen and shared.agoText(os.time() - entry.lastSeen) or ""
    status = chip(tr("panel.asleep", { ago = ago }), { fill = "on_surface/0.06" })
  end
  return ui.row({ gap = 12, align = "center" }, {
    ui.row({ padding = 10, radius = 14, fill = "primary/0.14", align = "center" }, {
      ui.glyph({ name = "mouse", size = 26, color = ACCENT }),
    }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = info.name or tr("panel.unknown_device"), fontSize = 17, fontWeight = "bold", color = "on_surface", maxLines = 1 }),
      ui.label({ text = shared.subtitle(entry), fontSize = 11, color = MUTED, maxLines = 1 }),
    }),
    status,
    ui.button({
      glyph = "refresh", variant = "ghost", controlSize = "sm", tooltip = tr("panel.refresh"),
      enabled = data.busy ~= true, onClick = function()
        noctalia.state.set("refresh", noctalia.nowMs())
      end,
    }),
    ui.button({
      glyph = "settings", variant = "ghost", controlSize = "sm", tooltip = tr("panel.settings"),
      onClick = function()
        noctalia.openSettings()
      end,
    }),
  })
end

local function batteryCard(info)
  local battery = info.battery
  local cfg = config()
  local level = shared.batteryLevel(battery, cfg.batteryWarn, cfg.batteryLow)
  local color = shared.levelColor(level)
  local percent = battery and tonumber(battery.percent) or 0
  local statusRow = {}
  if level == "charging" then
    statusRow[#statusRow + 1] = ui.glyph({ name = "bolt", size = 14, color = ACCENT })
  elseif level == "low" then
    statusRow[#statusRow + 1] = ui.glyph({ name = "alert-triangle", size = 14, color = color })
  end
  statusRow[#statusRow + 1] = ui.label({ text = battery and battery.status or tr("panel.not_reported"), fontSize = 12, color = MUTED })

  local details = {}
  if battery and battery.level then
    details[#details + 1] = tr("panel.battery_level", { level = battery.level })
  end
  if battery and battery.externalPower ~= nil then
    details[#details + 1] = battery.externalPower and tr("panel.external_power") or tr("panel.on_battery")
  end

  return card({
    caption(tr("panel.battery"), "battery"),
    ui.row({ gap = 10, align = "end" }, {
      ui.label({ text = shared.percentText(battery), fontSize = 32, fontWeight = "bold", color = color }),
      ui.row({ gap = 4, align = "center", paddingV = 6 }, statusRow),
    }),
    ui.progress({ progress = percent / 100, fill = level == "charging" and ACCENT or (level == "ok" and "on_surface" or color), track = TRACK, height = 8, radius = 4 }),
    ui.label({ text = table.concat(details, " · "), fontSize = 11, color = MUTED, maxLines = 1 }),
  }, { flexGrow = 1 })
end

-- A click handler that asks the service to run `logimouse <command> <action>` on this device.
local function requestChange(entry, command, action)
  return function()
    noctalia.state.set("change_request", { key = entry.key, unitId = entry.info.unitId, command = command, action = action, id = noctalia.nowMs() })
  end
end

-- The failure of the last change on this device, when it was one of these commands.
local function noticeFor(entry, data, commands)
  local notice = data.notice
  if type(notice) ~= "table" or notice.key ~= entry.key or not commands[notice.command] then
    return nil
  end
  return notice.text
end

local function dpiCard(entry, data)
  local dpi = entry.info.dpi
  local usable = entry.online and data.busy ~= true
  local function change(action)
    return requestChange(entry, "dpi", action)
  end
  local defaultText = dpi and dpi.default and tr("panel.dpi_default", { value = tostring(dpi.default) }) or ""
  local children = {
    caption(tr("panel.dpi"), "crosshair"),
    ui.row({ gap = 12, align = "center" }, {
      ui.button({ glyph = "minus", variant = "outline", controlSize = "sm", tooltip = tr("panel.dpi_down"), enabled = usable and shared.canDpiDown(dpi), onClick = change("down") }),
      ui.label({ text = shared.dpiText(dpi), fontSize = 32, fontWeight = "bold", color = "on_surface", textAlign = "center", flexGrow = 1 }),
      ui.button({ glyph = "plus", variant = "outline", controlSize = "sm", tooltip = tr("panel.dpi_up"), enabled = usable and shared.canDpiUp(dpi), onClick = change("up") }),
    }),
    ui.progress({ progress = shared.dpiFraction(dpi), fill = ACCENT, track = TRACK, height = 8, radius = 4 }),
    ui.label({ text = table.concat({ defaultText, shared.dpiRangeText(dpi) }, " · "), fontSize = 11, color = MUTED, maxLines = 1 }),
  }
  local notice = noticeFor(entry, data, { dpi = true })
  if notice then
    children[#children + 1] = ui.label({ text = notice, fontSize = 11, color = "error", maxLines = 2 })
  elseif not entry.online then
    children[#children + 1] = ui.label({ text = tr("panel.dpi_asleep"), fontSize = 11, color = MUTED, maxLines = 1 })
  end
  return card(children, { flexGrow = 1 })
end

-- The report rate, stepped like the DPI. On a mouse whose onboard profile sets it,
-- the − and + stay disabled until you switch to host mode here, and the card says
-- what host mode turns off.
local function rateCard(entry, data)
  local info = entry.info
  local rate = info.reportRate
  local usable = entry.online and data.busy ~= true
  local settable = shared.rateSettable(info)
  local children = {
    caption(tr("panel.rate_title"), "activity"),
    ui.row({ gap = 12, align = "center" }, {
      ui.button({ glyph = "minus", variant = "outline", controlSize = "sm", tooltip = tr("panel.rate_down"), enabled = usable and settable and shared.canRateDown(rate), onClick = requestChange(entry, "rate", "down") }),
      ui.label({ text = shared.reportRateText(rate), fontSize = 32, fontWeight = "bold", color = "on_surface", textAlign = "center", flexGrow = 1 }),
      ui.button({ glyph = "plus", variant = "outline", controlSize = "sm", tooltip = tr("panel.rate_up"), enabled = usable and settable and shared.canRateUp(rate), onClick = requestChange(entry, "rate", "up") }),
    }),
    ui.progress({ progress = shared.rateFraction(rate), fill = ACCENT, track = TRACK, height = 8, radius = 4 }),
    ui.label({ text = shared.ratesText(rate), fontSize = 11, color = MUTED, maxLines = 1 }),
  }
  if info.profileMode == "onboard" or info.profileMode == "host" then
    local onboard = info.profileMode == "onboard"
    children[#children + 1] = ui.row({ gap = 8, align = "center" }, {
      chip(onboard and tr("panel.mode_onboard") or tr("panel.mode_host"), onboard and nil or { fill = "primary/0.14", border = "primary/0.40" }),
      ui.spacer({ flexGrow = 1 }),
      ui.button({
        text = onboard and tr("panel.use_host") or tr("panel.use_onboard"),
        variant = "outline", controlSize = "sm", enabled = usable,
        onClick = requestChange(entry, "mode", onboard and "host" or "onboard"),
      }),
    })
    children[#children + 1] = ui.label({ text = onboard and tr("panel.onboard_note") or tr("panel.host_note"), fontSize = 11, color = MUTED, maxLines = 3 })
  end
  local notice = noticeFor(entry, data, { rate = true, mode = true })
  if notice then
    children[#children + 1] = ui.label({ text = notice, fontSize = 11, color = "error", maxLines = 2 })
  end
  return card(children, { flexGrow = 1 })
end

local function wheelCard(info)
  local rows = { caption(tr("panel.wheel"), "adjustments") }
  local smartShift = info.smartShift
  if smartShift then
    rows[#rows + 1] = keyValue(tr("panel.smartshift"), smartShift.mode)
    rows[#rows + 1] = keyValue(tr("panel.threshold"), tostring(smartShift.threshold))
    rows[#rows + 1] = keyValue(tr("panel.force"), tostring(smartShift.force) .. "%")
  end
  local wheel = info.wheel
  if wheel then
    rows[#rows + 1] = keyValue(tr("panel.resolution"), wheel.highResolution and tr("panel.high") or tr("panel.low"))
    rows[#rows + 1] = keyValue(tr("panel.direction"), wheel.inverted and tr("panel.inverted") or tr("panel.normal"))
    if wheel.ratchet ~= nil then
      rows[#rows + 1] = keyValue(tr("panel.ratchet"), wheel.ratchet and tr("panel.engaged") or tr("panel.free_spin"))
    end
  end
  if #rows == 1 then
    rows[#rows + 1] = ui.label({ text = tr("panel.not_reported"), fontSize = 12, color = MUTED })
  end
  return card(rows, { flexGrow = 1 })
end

local function hostsCard(info)
  local rows = { caption(tr("panel.easy_switch"), "switch-horizontal") }
  for _, host in ipairs(info.hosts or {}) do
    local name = host.paired and (host.name or tr("panel.paired")) or tr("panel.empty")
    local line = {
      dot(10, host.current and ACCENT or (host.paired and "on_surface/0.35" or CLEAR), host.current and ACCENT or "outline/0.5"),
      ui.label({ text = tostring(host.channel), fontSize = 12, fontWeight = "semibold", color = host.current and ACCENT or MUTED, width = 14 }),
      ui.label({ text = name, fontSize = 12, color = host.paired and "on_surface" or MUTED, flexGrow = 1, maxLines = 1 }),
    }
    if host.current then
      line[#line + 1] = chip(tr("panel.current"), { fill = "primary/0.14", border = "primary/0.40" })
    end
    rows[#rows + 1] = ui.row({ key = "host" .. tostring(host.channel), gap = 8, align = "center", minHeight = 26 }, line)
  end
  if #rows == 1 then
    rows[#rows + 1] = ui.label({ text = tr("panel.not_reported"), fontSize = 12, color = MUTED })
  end
  return card(rows, { flexGrow = 1 })
end

local function buttonsCard(info)
  local lines = {}
  local current = {}
  for _, button in ipairs(info.buttons or {}) do
    local text = button.name
    local extra = nil
    if button.state == "remapped" then
      text = text .. " → " .. tostring(button.remappedTo)
      extra = { fill = "primary/0.14", border = "primary/0.40" }
    elseif button.state == "diverted" then
      text = text .. " · " .. tr("panel.diverted")
      extra = { fill = "primary/0.14", border = "primary/0.40" }
    end
    current[#current + 1] = chip(text, extra, "button" .. tostring(button.cid))
    if #current == CHIPS_PER_ROW then
      lines[#lines + 1] = ui.row({ gap = 6 }, current)
      current = {}
    end
  end
  if #current > 0 then
    lines[#lines + 1] = ui.row({ gap = 6 }, current)
  end
  local children = { caption(tr("panel.buttons"), "list") }
  if #lines == 0 then
    children[#children + 1] = ui.label({ text = tr("panel.not_reported"), fontSize = 12, color = MUTED })
  else
    children[#children + 1] = ui.column({ gap = 6 }, lines)
  end
  return card(children)
end

local function deviceCard(info)
  local rows = {
    caption(tr("panel.device"), "info-circle"),
    keyValue(tr("panel.model"), info.modelId),
    keyValue(tr("panel.unit"), info.unitId),
    keyValue(tr("panel.serial"), info.serial),
  }
  for _, fw in ipairs(info.firmware or {}) do
    rows[#rows + 1] = keyValue((fw.type:gsub("^%l", string.upper)), fw.version, "fw" .. fw.type)
  end
  return card(rows, { flexGrow = 1 })
end

local function slotDots(receiver)
  local occupied = {}
  for _, slot in ipairs(receiver.slots or {}) do
    occupied[slot.slot] = slot
  end
  local dots = {}
  for n = 1, receiver.maxSlots or 6 do
    local slot = occupied[n]
    local fill = CLEAR
    local border = "outline/0.5"
    if slot and slot.online then
      fill, border = ACCENT, ACCENT
    elseif slot then
      fill, border = "on_surface/0.35", "on_surface/0.35"
    end
    dots[#dots + 1] = dot(12, fill, border, "slot" .. tostring(n))
  end
  dots[#dots + 1] = ui.label({
    text = tr("panel.slots_used", { used = tostring(receiver.pairedCount or #(receiver.slots or {})), total = tostring(receiver.maxSlots or 6) }),
    fontSize = 11, color = MUTED,
  })
  return ui.row({ gap = 6, align = "center", paddingV = 4 }, dots)
end

-- How the selected device is connected: its receiver, with the six pairing slots, or
-- the USB device it is.
local function connectionCard(info, data)
  local connection = info.connection or {}
  if connection.type == "direct" then
    return card({
      caption(tr("panel.connection") .. " · " .. tr("panel.direct"), "usb"),
      keyValue(tr("panel.usb_product"), connection.product),
      keyValue(tr("panel.usb_id"), connection.usbId),
      keyValue(tr("panel.node"), connection.path),
    }, { flexGrow = 1 })
  end
  local receiver = shared.findReceiver(data.receivers, connection.receiver)
  if receiver == nil then
    return card({ caption(tr("panel.connection"), "usb"), ui.label({ text = tr("panel.no_receiver"), fontSize = 12, color = MUTED }) }, { flexGrow = 1 })
  end
  local rows = {
    caption(tr("panel.connection") .. " · " .. tostring(receiver.name), "usb"),
    keyValue(tr("panel.usb_id"), receiver.usbId),
    keyValue(tr("panel.release"), receiver.release),
    keyValue(tr("panel.unique_id"), receiver.uniqueId),
    keyValue(tr("panel.node"), receiver.path),
    slotDots(receiver),
  }
  for _, slot in ipairs(receiver.slots or {}) do
    rows[#rows + 1] = keyValue(tr("panel.slot", { n = tostring(slot.slot) }), string.format("%s · %s · WPID %s", slot.name or "?", slot.kind or "?", slot.wpid or "?"), "pairing" .. tostring(slot.slot))
  end
  return card(rows, { flexGrow = 1 })
end

-- ── Device list ─────────────────────────────────────────────────────────────

local function sectionTitle(text)
  return ui.label({ text = string.upper(text), fontSize = 10, fontWeight = "semibold", color = MUTED })
end

local function deviceRow(entry, selected)
  local info = entry.info or {}
  local cfg = config()
  local level = shared.batteryLevel(info.battery, cfg.batteryWarn, cfg.batteryLow)
  local key = entry.key
  local function pick()
    selectedKey = key
    render()
  end
  local status = {
    dot(8, entry.online and ACCENT or CLEAR, entry.online and ACCENT or "outline/0.6"),
  }
  if info.battery then
    status[#status + 1] = ui.label({ text = shared.percentText(info.battery), fontSize = 11, fontWeight = "semibold", color = shared.levelColor(level) })
  end
  if level == "charging" then
    status[#status + 1] = ui.glyph({ name = "bolt", size = 11, color = ACCENT })
  end
  status[#status + 1] = ui.label({ text = shared.connectionShort(info), fontSize = 11, color = MUTED, maxLines = 1 })
  return ui.row({
    key = "device" .. tostring(key), gap = 10, align = "center", padding = 8, radius = 10,
    fill = selected and "primary/0.10" or CLEAR, border = selected and "primary/0.45" or CLEAR, borderWidth = 1,
    onClick = pick,
  }, {
    ui.box({ width = 3, height = 34, radius = 2, fill = selected and ACCENT or CLEAR }),
    ui.column({ gap = 3, flexGrow = 1 }, {
      ui.label({ text = info.name or tr("panel.unknown_device"), fontSize = 12, fontWeight = "semibold", color = "on_surface", maxLines = 1 }),
      ui.row({ gap = 5, align = "center" }, status),
    }),
  })
end

local function lockedRow(node)
  return ui.row({ key = "locked" .. tostring(node.path), gap = 10, align = "center", padding = 8, opacity = 0.75 }, {
    ui.glyph({ name = "lock", size = 14, color = MUTED }),
    ui.column({ gap = 3, flexGrow = 1 }, {
      ui.label({ text = node.name or tr("panel.unknown_device"), fontSize = 12, fontWeight = "semibold", color = "on_surface", maxLines = 1 }),
      ui.label({ text = tr("panel.no_access", { path = tostring(node.path) }), fontSize = 11, color = MUTED, maxLines = 1 }),
    }),
  })
end

local function receiverRow(receiver)
  local used = receiver.pairedCount or #(receiver.slots or {})
  return ui.row({ key = "receiver" .. tostring(receiver.path), gap = 10, align = "center", padding = 8 }, {
    ui.glyph({ name = "usb", size = 14, color = MUTED }),
    ui.column({ gap = 3, flexGrow = 1 }, {
      ui.label({ text = receiver.name or tr("panel.receiver"), fontSize = 12, color = "on_surface", maxLines = 1 }),
      ui.label({ text = tr("panel.slots_used", { used = tostring(used), total = tostring(receiver.maxSlots or 6) }), fontSize = 11, color = MUTED, maxLines = 1 }),
    }),
  })
end

local function sidebar(data, selected)
  local rows = { sectionTitle(tr("panel.devices")) }
  for _, entry in ipairs(data.devices or {}) do
    rows[#rows + 1] = deviceRow(entry, selected ~= nil and entry.key == selected.key)
  end
  for _, node in ipairs(data.inaccessible or {}) do
    rows[#rows + 1] = lockedRow(node)
  end
  if #rows == 1 then
    rows[#rows + 1] = ui.label({ text = tr("panel.none_found"), fontSize = 11, color = MUTED })
  end
  if #(data.receivers or {}) > 0 then
    rows[#rows + 1] = ui.spacer({ height = 8 })
    rows[#rows + 1] = sectionTitle(tr("panel.receivers"))
    for _, receiver in ipairs(data.receivers) do
      rows[#rows + 1] = receiverRow(receiver)
    end
  end
  return ui.scroll({ width = SIDEBAR_WIDTH, gap = 4, padding = 12, radius = 14, fill = "surface_variant/0.20" }, rows)
end

-- ── Render ──────────────────────────────────────────────────────────────────

local function emptyView(data)
  local reason = data and data.error or ""
  if reason == "" then
    reason = tr("panel.waiting")
  end
  return ui.column({ gap = 12, padding = 24, align = "center", justify = "center", flexGrow = 1 }, {
    ui.glyph({ name = "mouse-off", size = 42, color = MUTED }),
    ui.label({ text = tr("panel.no_data"), fontSize = 16, fontWeight = "semibold", color = "on_surface" }),
    ui.label({ text = reason, fontSize = 12, color = MUTED, textAlign = "center", maxLines = 3 }),
    ui.button({ text = tr("panel.refresh"), glyph = "refresh", variant = "outline", onClick = function()
      noctalia.state.set("refresh", noctalia.nowMs())
    end }),
  })
end

render = function()
  if not isOpen then
    return
  end
  local data = noctalia.state.get("data") or {}
  local devices = data.devices or {}
  local entry = selectedKey and shared.findDevice(devices, selectedKey) or nil
  if entry == nil then
    entry = shared.primaryDevice(devices)
    selectedKey = entry and entry.key or nil
  end

  local body = {}
  -- Only errors that stop everything get the banner; a device that cannot be
  -- opened is its own row in the list.
  if data.error and data.error ~= "" then
    body[#body + 1] = ui.row({ gap = 8, align = "center", padding = 10, radius = 10, fill = "error/0.12" }, {
      ui.glyph({ name = "alert-triangle", size = 14, color = "error" }),
      ui.label({ text = data.error, fontSize = 12, color = "on_surface", flexGrow = 1, maxLines = 2 }),
    })
  end
  if entry == nil or entry.info == nil then
    body[#body + 1] = emptyView(data)
  else
    local info = entry.info
    table.insert(body, 1, header(entry, data))
    body[#body + 1] = ui.row({ gap = 12 }, { batteryCard(info), dpiCard(entry, data) })
    -- Cards for features the device does not have are left out, not shown empty.
    local sections = shared.sections(info)
    local middle = {}
    if info.reportRate then
      middle[#middle + 1] = rateCard(entry, data)
    end
    if sections.wheel then
      middle[#middle + 1] = wheelCard(info)
    end
    if sections.hosts then
      middle[#middle + 1] = hostsCard(info)
    end
    if #middle > 0 then
      body[#body + 1] = ui.row({ gap = 12 }, middle)
    end
    if sections.buttons then
      body[#body + 1] = buttonsCard(info)
    end
    body[#body + 1] = ui.row({ gap = 12 }, { deviceCard(info), connectionCard(info, data) })
  end

  panel.render(ui.row({ gap = 12, padding = 16, flexGrow = 1 }, {
    sidebar(data, entry),
    ui.scroll({ gap = 12, flexGrow = 1 }, body),
  }))
end

noctalia.state.watch("data", function()
  render()
end)

function onOpen()
  isOpen = true
  render()
  -- Opening is a good moment for fresh numbers; the service ignores it while busy.
  noctalia.state.set("refresh", noctalia.nowMs())
end

function onClose()
  isOpen = false
end
