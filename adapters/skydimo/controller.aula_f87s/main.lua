---
--- AULA F87S Keyboard — Controller plugin entry
---
--- 把狼蛛 AULA F87S 键盘桥接到 SKYdimo：
--- 通过 MI_03 主配置口，用 cmd36(逐键) + cmd35(custom 模式) 实现逐键 RGB。
---

local layout   = require("lib.layout")
local protocol = require("lib.protocol")

local plugin = {}

local OUTPUT_ID = "keys"

local state = {
  last_frame  = nil,
  initialized = false,
  mode_ready  = false,
  realtime_ready = false,
}

---------------------------------------------------------------------------
-- 生命周期回调
---------------------------------------------------------------------------

function plugin.on_validate()
  device:log("AULA F87S: validating...")
  device:set_manufacturer("AULA")
  device:set_model("AULA F87S")
  device:set_device_type("keyboard")
  device:set_description("AULA F87S RGB keyboard (custom per-key mode via HID)")
  device:set_serial_id(
    device:serial_id() ~= "" and device:serial_id() or device:controller_port()
  )
  device:log("AULA F87S: validated")
  return true
end

function plugin.on_init()
  device:log("AULA F87S: initializing...")

  device:add_output({
    id   = OUTPUT_ID,
    name = "Keyboard",
    type = "matrix",
    size = layout.LED_COUNT,
    matrix = {
      width  = layout.WIDTH,
      height = layout.HEIGHT,
      map    = layout.MAP,
    },
    capabilities = {
      editable       = false,
      min_total_leds = layout.LED_COUNT,
      max_total_leds = layout.LED_COUNT,
    },
  })

  state.last_frame = nil
  protocol.reset_cache()
  -- custom 模式只在初始化设置，第一帧强制同步全部槽位。
  if protocol.set_mode(protocol.CUSTOM_MODE, protocol.BRIGHTNESS, false) then
    state.mode_ready = true
  else
    device:error("AULA F87S: failed to enter custom mode")
  end

  state.initialized = true
  device:log(string.format(
    "AULA F87S: initialized — %d LED slots, %dx%d matrix, custom mode ready=%s",
    layout.LED_COUNT, layout.WIDTH, layout.HEIGHT, tostring(state.mode_ready)
  ))
end

function plugin.on_tick(_dt)
  if not state.initialized then
    return
  end

  local rgb = device:get_rgb_bytes(OUTPUT_ID) or ""
  if #rgb == 0 then
    return
  end

  -- SKYdimo 可能在同一帧回调多次；静态画面不重复写。
  if state.last_frame == rgb then
    return
  end
  -- cmd51 实测确认 cmd36 可直接改变输出；只在初始化切模式。
  -- 不使用尚未在 F87S 上显示生效的 0x08 通道。
  local ok = protocol.write_custom(rgb, false, layout.HARDWARE_IDS)
  if ok then
    state.last_frame = rgb
  end
end

function plugin.on_shutdown()
  if not state.initialized then
    return
  end

  -- 熄灭全部按键；实时通道不依赖 cmd35 状态。
  if state.realtime_ready then
    protocol.write_realtime(string.rep("\0", layout.LED_COUNT * 3), layout.HARDWARE_IDS)
  else
    protocol.write_custom(string.rep("\0", layout.LED_COUNT * 3), false, layout.HARDWARE_IDS)
  end
  device:log("AULA F87S: shutdown, LEDs cleared")
end

return plugin
