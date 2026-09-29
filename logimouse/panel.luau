--!nonstrict
-- The panel: everything `logimouse` knows about the mouse and the receiver.
--
-- Layout, top to bottom: a header with the device and the refresh and settings
-- buttons; battery and DPI side by side; the scroll wheel and Easy-Switch; the
-- buttons as chips; and the device's identity next to the receiver's. The only
-- control that changes anything is the DPI's − and +, which the service runs, so
-- that one `logimouse` process talks to the receiver at a time.

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

local isOpen = false
local selectedSlot = nil

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

local function tabs(devices)
  local buttons = {}
  for _, entry in ipairs(devices) do
    local slot = entry.slot
    local function select()
      selectedSlot = slot
      render()
    end
    buttons[#buttons + 1] = ui.button({
      key = "tab" .. tostring(slot),
      text = (entry.info and entry.info.name) or ("Slot " .. tostring(slot)),
      variant = "ghost",
      controlSize = "sm",
      selected = slot == selectedSlot,
      onClick = select,
    })
  end
  return ui.row({ gap = 6 }, buttons)
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

local function dpiCard(entry, data)
  local dpi = entry.info.dpi
  local usable = entry.online and data.busy ~= true
  local function change(action)
    return function()
      noctalia.state.set("dpi_request", { slot = entry.slot, action = action, id = noctalia.nowMs() })
    end
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
  if data.notice and data.notice ~= "" then
    children[#children + 1] = ui.label({ text = data.notice, fontSize = 11, color = "error", maxLines = 2 })
  elseif not entry.online then
    children[#children + 1] = ui.label({ text = tr("panel.dpi_asleep"), fontSize = 11, color = MUTED, maxLines = 1 })
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

local function receiverCard(receiver)
  if type(receiver) ~= "table" then
    return card({ caption(tr("panel.receiver"), "usb"), ui.label({ text = tr("panel.no_receiver"), fontSize = 12, color = MUTED }) }, { flexGrow = 1 })
  end
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
  local rows = {
    caption(tr("panel.receiver") .. " · Logi Bolt", "usb"),
    keyValue(tr("panel.usb_id"), receiver.usbId),
    keyValue(tr("panel.release"), receiver.release),
    keyValue(tr("panel.unique_id"), receiver.uniqueId),
    keyValue(tr("panel.node"), receiver.path),
    ui.row({ gap = 6, align = "center", paddingV = 4 }, dots),
  }
  for _, slot in ipairs(receiver.slots or {}) do
    rows[#rows + 1] = keyValue(tr("panel.slot", { n = tostring(slot.slot) }), string.format("%s · %s · WPID %s", slot.name or "?", slot.kind or "?", slot.wpid or "?"), "pairing" .. tostring(slot.slot))
  end
  return card(rows, { flexGrow = 1 })
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
  local entry = selectedSlot and shared.findDevice(devices, selectedSlot) or nil
  if entry == nil then
    entry = shared.primaryDevice(devices)
    selectedSlot = entry and entry.slot or nil
  end
  if entry == nil or entry.info == nil then
    panel.render(ui.column({ padding = 16, flexGrow = 1 }, { emptyView(data) }))
    return
  end

  local info = entry.info
  local body = {}
  if #devices > 1 then
    body[#body + 1] = tabs(devices)
  end
  body[#body + 1] = header(entry, data)
  if data.error and data.error ~= "" then
    body[#body + 1] = ui.row({ gap = 8, align = "center", padding = 10, radius = 10, fill = "error/0.12" }, {
      ui.glyph({ name = "alert-triangle", size = 14, color = "error" }),
      ui.label({ text = data.error, fontSize = 12, color = "on_surface", flexGrow = 1, maxLines = 2 }),
    })
  end
  body[#body + 1] = ui.row({ gap = 12 }, { batteryCard(info), dpiCard(entry, data) })
  body[#body + 1] = ui.row({ gap = 12 }, { wheelCard(info), hostsCard(info) })
  body[#body + 1] = buttonsCard(info)
  body[#body + 1] = ui.row({ gap = 12 }, { deviceCard(info), receiverCard(data.receiver) })

  panel.render(ui.scroll({ padding = 16, gap = 12, flexGrow = 1 }, body))
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
