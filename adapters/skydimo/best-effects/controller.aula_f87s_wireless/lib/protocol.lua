-- F87S receiver 0C45:FEF9 MI_03 / FF60:0061.
-- Output: reportId 0 + 64-byte body. Input: 64-byte body.
-- 首次同步等待 ACK，后续 RGB888 差分块使用 last=0 写入。
local protocol = {}
local allowed = {
  [16] = true, [19] = true, [20] = true, [27] = true, [29] = true,
  [35] = true, [36] = true, [43] = true, [45] = true,
}
local last_rgb, last_table = nil, nil
local last_ring_rgb, last_side_rgb = nil, nil
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

local function ack(cmd, address, length)
  for _ = 1, 8 do
    local ok, raw = pcall(device.read, device, 65, 200)
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
      last_ring_rgb, last_side_rgb = nil, nil
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
  last_ring_rgb, last_side_rgb = nil, nil
  device:error("F87S 2.4G: write failed cmd=" .. cmd .. " address=" .. address)
  return false
end

function protocol.probe()
  local data = command_ack(16, string.rep("\0", 56))
  if not data or #data ~= 56 then return false end
  local vid = data:byte(5) + data:byte(6) * 256
  local pid = data:byte(7) + data:byte(8) * 256
  if vid ~= 0x38A6 or pid ~= 0x2908 then
    device:log("F87S 2.4G: receiver is not connected to an F87S; skipping")
    return false
  end
  return true
end

function protocol.initialize()
  if saved then return true end
  local effect = command_ack(19, string.rep("\0", 16))
  if not effect then return false end
  local colors = command_ack(20, string.rep("\0", 512))
  if not colors then return false end
  local ring = command_ack(27, string.rep("\0", 24))
  if not ring then return false end
  local side = command_ack(29, string.rep("\0", 24))
  if not side then return false end
  -- Do not change lighting unless a complete recovery snapshot is available.
  saved = { effect = effect, colors = colors, ring = ring, side = side }
  last_rgb, last_table = nil, nil
  last_ring_rgb, last_side_rgb = nil, nil
  return true
end

local function zone_packet(rgb, original)
  if type(rgb) ~= "string" or #rgb < 3 or type(original) ~= "string" or #original ~= 24 then return nil end
  return string.char(original:byte(1), rgb:byte(1), rgb:byte(2), rgb:byte(3)) .. original:sub(5)
end

local function update_zone(rgb, previous, original, command_id)
  if not rgb or rgb == previous then return previous, true end
  local packet = zone_packet(rgb, original)
  if not packet then return previous, false end
  if not command_ack(command_id, packet) then return previous, false end
  return rgb, true
end

function protocol.update(rgb, ids, ring_rgb, side_rgb)
  if not saved or type(rgb) ~= "string" or #rgb ~= 87 * 3 or #ids ~= 87 then return false end
  if type(ring_rgb) ~= "string" or #ring_rgb ~= 3 then return false end
  if type(side_rgb) ~= "string" or #side_rgb ~= 3 then return false end
  if rgb == last_rgb and ring_rgb == last_ring_rgb and side_rgb == last_side_rgb then return true end
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
  local next_ring, ring_ok = update_zone(ring_rgb, last_ring_rgb, saved.ring, 43)
  if not ring_ok then return false end
  local next_side, side_ok = update_zone(side_rgb, last_side_rgb, saved.side, 45)
  if not side_ok then return false end
  last_rgb, last_table = rgb, data
  last_ring_rgb, last_side_rgb = next_ring, next_side
  return true
end

function protocol.shutdown()
  if not saved then return true end
  local original = saved
  local colors = command_ack(36, original.colors)
  local effect = colors and command_ack(35, original.effect)
  local ring = effect and command_ack(43, original.ring)
  local side = ring and command_ack(45, original.side)
  saved, last_rgb, last_table = nil, nil, nil
  last_ring_rgb, last_side_rgb = nil, nil
  if not colors or not effect or not ring or not side then
    device:error("F87S 2.4G: unable to restore original lighting after disconnect")
    return false
  end
  return true
end

return protocol
