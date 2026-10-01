-- AULA F87S wired controller with one compact matrix output.
local layout = require("lib.layout")
local protocol = require("lib.protocol")
local plugin = {}
local OUTPUT_ID = "keys"
local state = { initialized = false, elapsed = 0, failures = 0 }

function plugin.on_validate()
  device:log("AULA F87S wired: validating...")
  device:set_manufacturer("AULA")
  device:set_model("AULA F87S")
  device:set_device_type("keyboard")
  device:set_description("F87S wired RGB with compact ring and side-bar samples")
  device:set_serial_id(device:serial_id() ~= "" and device:serial_id() or device:controller_port())
  return true
end

function plugin.on_init()
  device:add_output({
    id = OUTPUT_ID, name = "F87S Keyboard + Zones", type = "matrix", size = layout.LED_COUNT,
    matrix = { width = layout.WIDTH, height = layout.HEIGHT, map = layout.MAP },
    capabilities = { editable = false, min_total_leds = layout.LED_COUNT,
      max_total_leds = layout.LED_COUNT, allowed_total_leds = { layout.LED_COUNT } }
  })
  state.initialized = false
  state.elapsed = 0
  state.failures = 0
  if protocol.initialize() then state.initialized = true end
  device:log("AULA F87S wired: initialized; unified compact 101-sample matrix")
end

function plugin.on_tick(dt)
  state.elapsed = state.elapsed + math.max(tonumber(dt) or 0.016, 0)
  local interval = state.failures > 0 and 2 or 1 / 60
  if state.elapsed < interval then return end
  state.elapsed = 0
  if not state.initialized then
    if not protocol.initialize() then state.failures = state.failures + 1; return end
    state.initialized = true
  end
  local rgb = device:get_rgb_bytes(OUTPUT_ID)
  if type(rgb) ~= "string" or #rgb ~= layout.LED_COUNT * 3 then return end
  local keys, ring, side = layout.split_frame(rgb)
  if protocol.update(keys, layout.HARDWARE_IDS, ring, side) then state.failures = 0
  else state.failures = state.failures + 1 end
end

function plugin.on_shutdown()
  protocol.shutdown()
  state.initialized = false
  device:log("AULA F87S wired: original lighting restoration attempted")
end

return plugin
