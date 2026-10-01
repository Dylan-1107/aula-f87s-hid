-- Independent F87S 2.4G controller; never matches the wired keyboard.
local layout = require("lib.layout")
local protocol = require("lib.protocol")
local plugin = {}
local state = { initialized = false, elapsed = 0, failures = 0 }

function plugin.on_validate()
  if not protocol.probe() then return false end
  device:set_manufacturer("AULA")
  device:set_model("AULA F87S 2.4G")
  device:set_device_type("keyboard")
  device:set_description("F87S wireless per-key RGB via 0C45:FEF9 MI_03")
  local serial = device:serial_id()
  if not serial or serial == "" then serial = device:controller_port() end
  device:set_serial_id("F87S-24G-" .. tostring(serial))
  return true
end

function plugin.on_init()
  device:add_output({
    id = "keys", name = "F87S 2.4G Keyboard", type = "matrix", size = layout.LED_COUNT,
    matrix = { width = layout.WIDTH, height = layout.HEIGHT, map = layout.MAP },
    capabilities = {
      editable = false, min_total_leds = layout.LED_COUNT,
      max_total_leds = layout.LED_COUNT, allowed_total_leds = { layout.LED_COUNT }
    }
  })
  state.initialized = false
  state.elapsed = 0
  state.failures = 0
  -- Retry snapshot initialization in on_tick if the keyboard is asleep.
  if protocol.initialize() then state.initialized = true end
  device:log("F87S 2.4G: initialized; calibrated 87-key matrix")
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
  local rgb = device:get_rgb_bytes("keys")
  if type(rgb) ~= "string" or #rgb ~= layout.LED_COUNT * 3 then return end
  if protocol.update(rgb, layout.HARDWARE_IDS) then
    state.failures = 0
  else
    state.failures = state.failures + 1
  end
end

function plugin.on_shutdown()
  protocol.shutdown()
  state.initialized = false
  device:log("F87S 2.4G: original lighting restoration attempted")
end

return plugin
