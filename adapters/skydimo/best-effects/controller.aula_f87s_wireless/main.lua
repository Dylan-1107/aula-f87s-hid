-- Independent F87S 2.4G controller; never matches the wired keyboard.
local layout = require("lib.layout")
local protocol = require("lib.protocol")
local plugin = {}
local OUTPUT_ID = "keys"
local IDENTIFY_INTERVAL = 2
local PROBE_INTERVAL = 2
local state = {
  identified = false, rejected = false, asleep = false,
  initialized = false, elapsed = 0, failures = 0,
  identify_elapsed = 0, probe_elapsed = 0,
}

-- 只按 manifest 的 VID/PID/接口号认领，不在这里发任何命令。
-- 2.4G 接收器是常驻 USB 端点，键盘本体休眠时对 cmd16 完全不应答；
-- 旧实现把校验放在 on_validate，超时即 return false，设备被永久丢弃。
function plugin.on_validate()
  device:set_manufacturer("AULA")
  device:set_model("AULA F87S 2.4G")
  device:set_device_type("keyboard")
  device:set_description("F87S wireless RGB with volume ring and side light zones via 0C45:FEF9 MI_03")
  local serial = device:serial_id()
  if not serial or serial == "" then serial = device:controller_port() end
  device:set_serial_id("F87S-24G-" .. tostring(serial))
  return true
end

function plugin.on_init()
  device:add_output({
    id = OUTPUT_ID, name = "F87S 2.4G Keyboard + Zones", type = "matrix", size = layout.LED_COUNT,
    matrix = { width = layout.WIDTH, height = layout.HEIGHT, map = layout.MAP },
    capabilities = {
      editable = false, min_total_leds = layout.LED_COUNT,
      max_total_leds = layout.LED_COUNT, allowed_total_leds = { layout.LED_COUNT }
    }
  })
  state.initialized = false
  state.elapsed = 0
  state.failures = 0
  state.identify_elapsed = 0
  state.probe_elapsed = 0
  state.asleep = false
  if protocol.identify() == "f87s" then state.identified = true end
  if state.identified and protocol.initialize() then state.initialized = true end
  device:log(state.identified
    and "F87S 2.4G: initialized; unified compact 101-sample matrix (87 keys + ring + side bars)"
    or "F87S 2.4G: receiver found; waiting for the keyboard to wake")
end

function plugin.on_tick(dt)
  local step = math.max(tonumber(dt) or 0.016, 0)
  state.elapsed = state.elapsed + step

  -- 本体校验独立节流：未识别时每 2 秒试一次，按一下键盘即可恢复。
  if not state.identified then
    if state.rejected then return end
    state.identify_elapsed = state.identify_elapsed + step
    if state.identify_elapsed < IDENTIFY_INTERVAL then return end
    state.identify_elapsed = 0
    local verdict = protocol.identify()
    if verdict == "other" then
      state.rejected = true
      device:error("F87S 2.4G: receiver is not connected to an F87S; skipping")
      return
    end
    if verdict ~= "f87s" then return end
    state.identified = true
    protocol.resync()
    device:log("F87S 2.4G: keyboard awake; identity confirmed")
  end

  -- 心跳独立节流。必须有心跳，不能只靠 update() 的返回值：
  -- 2.4G 接收器是常驻端点，键盘本体睡掉后 device.write 照样返回成功，
  -- 于是差分基线会在「什么都没点亮」的情况下被一路推进；唤醒后
  -- rgb == last_rgb 命中 update() 的早退分支，灯效就永远回不来了。
  state.probe_elapsed = state.probe_elapsed + step
  if state.probe_elapsed >= PROBE_INTERVAL then
    state.probe_elapsed = 0
    if protocol.ping() then
      if state.asleep then
        state.asleep = false
        protocol.resync()
        device:log("F87S 2.4G: keyboard awake; relighting the current preset")
      end
    elseif not state.asleep then
      state.asleep = true
      device:log("F87S 2.4G: keyboard asleep; lighting frames paused")
    end
  end
  -- 休眠期间只发心跳，不推灯效帧，避免把差分基线推成「已同步」的假象。
  if state.asleep then return end

  local interval = state.failures > 0 and 2 or 1 / 60
  if state.elapsed < interval then return end
  -- Keep the remainder so a 16 ms host tick does not collapse 60 Hz into 30 Hz.
  -- Discard missed frames after a stall; send at most one frame per callback.
  state.elapsed = state.elapsed % interval
  if not state.initialized then
    if not protocol.initialize() then
      state.failures = state.failures + 1
      state.elapsed = 0
      return
    end
    state.initialized = true
    state.failures = 0
  end
  local rgb = device:get_rgb_bytes(OUTPUT_ID)
  if type(rgb) ~= "string" or #rgb ~= layout.LED_COUNT * 3 then return end
  local keys, ring, side = layout.split_frame(rgb)
  if protocol.update(keys, layout.HARDWARE_IDS, ring, side) then
    if state.failures > 0 then state.elapsed = 0 end
    state.failures = 0
  else
    state.failures = state.failures + 1
    state.elapsed = 0
  end
end

function plugin.on_shutdown()
  if state.identified then protocol.shutdown() end
  state.initialized = false
  device:log("F87S 2.4G: original lighting restoration attempted")
end

return plugin
