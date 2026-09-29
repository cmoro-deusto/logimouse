--!nonstrict
-- The bar widget: the mouse icon, battery, charging bolt and DPI, each one optional.
--
-- It holds no logic of its own. service.luau runs `logimouse` and publishes what it
-- read; shared.luau turns that into what this file paints. Left click toggles the
-- panel, right click opens the plugin's settings.

local shared = require("./shared.luau")

local PANEL_ID = "cmoro-deusto/logimouse:panel"

local ICON_SIZE = 15
local BOLT_SIZE = 12
local SIZE_VALUE = 11
local SIZE_UNIT = 9
local MUTED = "on_surface_variant"
local DIM_OPACITY = 0.55

-- Read per paint, so a change in the settings page lands without a reload. `~= false`
-- because every one of these defaults to true in the manifest.
local function config()
  return {
    showIcon = noctalia.getConfig("show_icon") ~= false,
    showBattery = noctalia.getConfig("show_battery") ~= false,
    showCharging = noctalia.getConfig("show_charging") ~= false,
    showDpi = noctalia.getConfig("show_dpi") ~= false,
    batteryWarn = noctalia.getConfig("battery_warn"),
    batteryLow = noctalia.getConfig("battery_low"),
  }
end

local function container(props, children)
  if barWidget.isVertical() then
    return ui.column(props, children)
  end
  return ui.row(props, children)
end

local function nodesFor(model, cfg)
  local nodes = {}
  if model.empty then
    if cfg.showIcon then
      nodes[#nodes + 1] = ui.glyph({ name = model.icon, size = ICON_SIZE, color = MUTED })
    end
    nodes[#nodes + 1] = ui.label({ text = "—", fontSize = SIZE_VALUE, color = MUTED })
    return nodes
  end
  if cfg.showIcon then
    nodes[#nodes + 1] = ui.glyph({ name = model.icon, size = ICON_SIZE, color = model.iconColor })
  end
  if model.battery then
    nodes[#nodes + 1] = ui.label({
      text = model.battery.text,
      fontSize = SIZE_VALUE,
      fontWeight = "semibold",
      color = model.battery.color,
      maxLines = 1,
    })
  end
  if model.charging then
    nodes[#nodes + 1] = ui.glyph({ name = "bolt", size = BOLT_SIZE, color = "primary" })
  end
  if model.dpi then
    nodes[#nodes + 1] = container({ gap = 2, align = "center" }, {
      ui.label({ text = model.dpi, fontSize = SIZE_VALUE, fontWeight = "semibold", color = "on_surface", maxLines = 1 }),
      ui.label({ text = noctalia.tr("bar.dpi_unit"), fontSize = SIZE_UNIT, color = MUTED, maxLines = 1 }),
    })
  end
  if #nodes == 0 then
    -- Everything switched off: keep something to click.
    nodes[#nodes + 1] = ui.glyph({ name = "mouse", size = ICON_SIZE, color = "on_surface" })
  end
  return nodes
end

local function repaint(data)
  local cfg = config()
  local model = shared.barModel(data, cfg, os.time())
  barWidget.render(container({
    gap = 5,
    align = "center",
    opacity = model.dim and DIM_OPACITY or 1,
  }, nodesFor(model, cfg)))
  barWidget.setTooltip(model.tooltip)
end

noctalia.state.watch("data", repaint)

-- The data only changes when the service publishes, but "last seen" in the tooltip
-- moves with the clock, and a settings change has to repaint.
function update()
  noctalia.setUpdateInterval(30000)
  repaint(noctalia.state.get("data"))
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
  noctalia.openSettings()
end

repaint(noctalia.state.get("data"))
