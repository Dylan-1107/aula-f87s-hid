-- F87S receiver 0C45:FEF9 MI_03 / FF60:0061.
-- Output: reportId 0 + 64-byte body. Input: 64-byte body.
-- 首次同步等待 ACK，后续 RGB888 差分块使用 last=0 写入。
local protocol = {}
local allowed = { [16] = true, [19] = true, [20] = true, [27] = true, [29] = true, [35] = true, [36] = true, [43] = true, [45] = true }
local last_rgb, last_table, last_box, last_side = nil, nil, nil, nil
local saved = nil
local zeros = string.rep("\0", 56)

local function report(cmd, chunk, address, last)
  return string.char(0, 0xAA, cmd, #chunk, address % 256,
    math.floor(address / 256) % 256, 0, last and 1 or 0, 0)
    .. chunk .. zeros:sub(1, 56 - #chunk)
end

local function body(raw)
  if type(raw) ~= "string" then return nil end
  -- Accommodate hosts that preserve the zero Report ID slot on reads.
  if #raw == 65 and raw:byte(1) == 0 then raw = raw:sub(2) end
  return raw
end

local function drain()
  for _ = 1, 32 do
    local ok, raw = pcall(device.read, device, 65, 0)
    if not ok then return false end
    if type(raw) ~= "string" or #raw == 0 then return true end
  end
  return false
end

local function ack(cmd, address, length, attempts, timeout_ms)
  for _ = 1, (attempts or 8) do
    local ok, raw = pcall(device.read, device, 65, timeout_ms or 200)
    if not ok then return nil end
    local r = body(raw)
    if not r or #r == 0 then return nil end
    if #r >= 8 + length and r:byte(1) == 0x55 and r:byte(2) == cmd
      and r:byte(3) == length and r:byte(4) + r:byte(5) * 256 == address then
      return r:sub(9, 8 + length)
    end
  end
  return nil
end

local function write_result(packet)
  local ok, count = pcall(device.write, device, packet)
  return ok and (count == #packet or count == true)
end

-- 初始化与关闭路径保留逐包 ACK，确保快照和恢复完整。
local function command_ack(cmd, data)
  if not allowed[cmd] or type(data) ~= "string" or #data == 0 then return nil end
  local responses = {}
  for address = 0, #data - 1, 56 do
    local chunk = data:sub(address + 1, math.min(address + 56, #data))
    local packet = report(cmd, chunk, address, address + #chunk == #data)
    local received = nil
    for _ = 1, 4 do
      if drain() and write_result(packet) then
        received = ack(cmd, address, #chunk)
        if received then break end
      end
    end
    if not received then
      last_rgb, last_table = nil, nil
      device:error("F87S 2.4G: response timeout cmd=" .. cmd .. " address=" .. address)
      return nil
    end
    responses[#responses + 1] = received
  end
  return table.concat(responses)
end

-- 灯效帧只检查 write 返回值；每次写入前有限次 timeout=0 排空输入。
local function fast_write(cmd, chunk, address, last)
  drain()
  if write_result(report(cmd, chunk, address, last)) then return true end
  last_rgb, last_table = nil, nil
  device:error("F87S 2.4G: write failed cmd=" .. cmd .. " address=" .. address)
  return false
end

-- 本体校验分三态，因为「键盘休眠」和「不是 F87S」必须区别对待：
--   "f87s"   = 确认是 F87S 本体
--   "other"  = 接收器在线，但后面挂的不是 F87S
--   "silent" = 没有任何应答（键盘休眠 / 未按醒），值得稍后重试
-- 旧实现把后两种都当成失败直接 return false，导致扫描一次不中就永远不再出现。
function protocol.identify()
  local chunk = string.rep("\0", 56)
  local packet = report(16, chunk, 0, true)
  for attempt = 1, 2 do
    if drain() and write_result(packet) then
      local data = ack(16, 0, 56, 4, 150)
      if data and #data == 56 then
        local vid = data:byte(5) + data:byte(6) * 256
        local pid = data:byte(7) + data:byte(8) * 256
        if vid ~= 0x38A6 or pid ~= 0x2908 then return "other" end
        return "f87s"
      end
    end
    -- 首轮失败后留一个读超时当等待，给休眠中的键盘一次被按醒的机会。
    if attempt == 1 then pcall(device.read, device, 65, 150) end
  end
  return "silent"
end

-- 心跳：一次写 + 至多两次 80ms 短读，只回答「本体还在不在」。
-- 必须比 identify() 便宜得多——identify() 在无应答时要阻塞约 1.3 秒，
-- 拿来做两秒一次的常驻心跳会把插件线程长期钉住。
function protocol.ping()
  local packet = report(16, string.rep("\0", 56), 0, true)
  if not (drain() and write_result(packet)) then return false end
  return ack(16, 0, 56, 2, 80) ~= nil
end

-- 丢弃差分基线，强制下一帧走完整表重同步。
-- 唤醒后必须调用：差分基线在插件里，硬件表在键盘里，
-- 键盘休眠会自己清表，两边就此永久分叉。
function protocol.resync()
  last_rgb, last_table, last_box, last_side = nil, nil, nil, nil
end

function protocol.initialize()
  if saved then return true end
  local effect = command_ack(19, string.rep("\0", 16))
  if not effect then return false end
  local colors = command_ack(20, string.rep("\0", 512))
  if not colors then return false end
  -- Preserve independent factory-controlled zones without taking ownership of them.
  local box = command_ack(27, string.rep("\0", 24))
  local side = command_ack(29, string.rep("\0", 24))
  if not box or not side then return false end
  -- Do not change lighting unless a complete recovery snapshot is available.
  saved = { effect = effect, colors = colors, box = box, side = side }
  last_rgb, last_table, last_box, last_side = nil, nil, nil, nil
  return true
end

local function zone_data(saved_bytes, rgb)
  local t = saved_bytes or string.rep("\0", 24)
  local r, g, b = rgb:byte(1, 3)
  return string.char(2, r or 0, g or 0, b or 0, t:byte(5) or 0, t:byte(6) or 0, t:byte(7) or 0, t:byte(8) or 0,
    t:byte(9) or 0, t:byte(10) or 5, t:byte(11) or 3, t:byte(12) or 0, t:byte(13) or 0, t:byte(14) or 0, 0, 0,
    t:sub(17, 24))
end

-- Reserved for a future explicit independent-zone output; normal presets never call this.
function protocol.update_zone(output_id, rgb)
  if not saved or type(rgb) ~= "string" or #rgb < 3 then return false end
  local is_box = output_id == "light_box"
  local previous = is_box and last_box or last_side
  if rgb == previous then return true end
  local old = is_box and saved.box or saved.side
  local data = zone_data(old, rgb)
  local ok = command_ack(is_box and 43 or 45, data) ~= nil
  if ok then
    if is_box then last_box = rgb else last_side = rgb end
  end
  return ok
end

function protocol.update(rgb, ids)
  if not saved or type(rgb) ~= "string" or #rgb ~= 87 * 3 or #ids ~= 87 then return false end
  if rgb == last_rgb then return true end
  local data = {}
  for slot = 0, 127 do
    data[slot * 4 + 1] = string.char(slot)
    data[slot * 4 + 2], data[slot * 4 + 3], data[slot * 4 + 4] = "\0", "\0", "\0"
  end
  for logical = 0, 86 do
    local slot = ids[logical + 1]
    if type(slot) ~= "number" or slot < 0 or slot > 127 or slot % 1 ~= 0 then return false end
    local r, g, b = rgb:byte(logical * 3 + 1, logical * 3 + 3)
    data[slot * 4 + 2], data[slot * 4 + 3], data[slot * 4 + 4] = string.char(r), string.char(g), string.char(b)
  end
  data = table.concat(data)
  local full = not last_table
  if full then
    if not command_ack(36, data) then return false end
  else
    for address = 0, #data - 1, 56 do
      local chunk = data:sub(address + 1, math.min(address + 56, #data))
      if chunk ~= last_table:sub(address + 1, address + #chunk)
        and not fast_write(36, chunk, address, false) then
        return false
      end
    end
  end
  if full then
    local effect = saved.effect:sub(1, 16)
    effect = string.char(20) .. effect:sub(2, 9) .. string.char(5)
      .. effect:sub(11, 14) .. string.char(0xAA, 0x55)
    if not command_ack(35, effect) then return false end
  end
  last_rgb, last_table = rgb, data
  return true
end

function protocol.shutdown()
  if not saved then return true end
  local original = saved
  local colors = command_ack(36, original.colors)
  local effect = colors and command_ack(35, original.effect)
  local box = effect and command_ack(43, original.box)
  local side = box and command_ack(45, original.side)
  saved, last_rgb, last_table, last_box, last_side = nil, nil, nil, nil, nil
  if not colors or not effect or not box or not side then
    device:error("F87S 2.4G: unable to restore original lighting after disconnect")
    return false
  end
  return true
end

return protocol
