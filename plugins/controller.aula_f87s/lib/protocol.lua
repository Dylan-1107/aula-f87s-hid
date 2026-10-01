---
--- AULA F87S — HID output-report protocol（实测点亮版）
---
--- 接口：MI_03（0xFF68:0x61），vid 0x38A6 / pid 0x2908
--- 数据通路：output report，reportId=0，64 字节/包，头部 8 字节：
---   [0xAA, cmd, chunkSize, addr_lo, addr_hi, 0x00, isLast, 0x00]
--- 载荷 56 字节/包，分包 Q = ceil(contentSize/56)
---
--- 关键命令：
---   cmd36 = 写自定义灯表（512B = 128 槽 × [ledId, R, G, B]）
---   cmd35 = 切模式（16B，mode=20 为 custom 模式，brightness 量程 0-5）
---

local protocol = {}

protocol.REPORT_ID   = 0x00
protocol.REPORT_SIZE = 64     -- 每包数据 64 字节（不含 reportId）
protocol.HEADER_SIZE = 8
protocol.PAYLOAD_SIZE = 56    -- 64 - 8

protocol.CMD_SET_LED_EFFECT      = 35
protocol.CMD_SET_CUSTOM_LED_DATA = 36
protocol.CMD_GET_ALL_LIGHTS_RGB  = 51

protocol.CUSTOM_MODE = 20        -- custom 模式（实测确认）
protocol.BRIGHTNESS  = 5         -- 官方亮度量程 0-5，5=最亮（255 会溢出全黑）

protocol.LED_SLOTS = 128         -- 512 字节 = 128 槽
protocol.LOGICAL_LEDS = 87       -- F87S 物理按键数量

-- 官方 AULA 有线实时路径：cmd=0x08，RGB565，63 字节数据体。
-- 每包有效载荷 56B，包体为 [0x08, 0x03, 0, total, index, length, data..., checksum]。
protocol.REALTIME_COMMAND = 8
protocol.REALTIME_PARAM = 3
protocol.REALTIME_BODY_SIZE = 63
protocol.REALTIME_DATA_SIZE = 56
protocol.REALTIME_CHUNK_SIZE = 56
protocol.REALTIME_REPORT_ID = 0

---------------------------------------------------------------------------
-- 辅助函数
---------------------------------------------------------------------------

--- 构建 65 字节 output report（reportId + 64 数据）
local function build_report(cmd, chunk_size, addr, data_str, is_last)
  local pkt = {}
  for i = 1, 65 do pkt[i] = 0x00 end
  pkt[1] = protocol.REPORT_ID
  pkt[2] = 0xAA
  pkt[3] = cmd
  pkt[4] = chunk_size
  pkt[5] = addr % 256
  pkt[6] = math.floor(addr / 256) % 256
  pkt[7] = 0x00
  pkt[8] = (is_last and 1) or 0
  pkt[9] = 0x00
  if data_str then
    for i = 1, #data_str do
      pkt[9 + i] = string.byte(data_str, i)
    end
  end
  local chars = {}
  for i = 1, 65 do chars[i] = string.char(pkt[i]) end
  return table.concat(chars)
end

--- 分包发送一条命令（contentSize 字节，每包 56 字节）
--- wait_for_response=false 时只写包，不额外等待读取；适用于 cmd36 连续帧。
local function send_command(cmd, data_str, content_size, wait_for_response)
  local W = protocol.PAYLOAD_SIZE
  local Q = math.max(1, math.ceil(content_size / W))
  for M = 0, Q - 1 do
    local addr = M * W
    local rem  = content_size - M * W
    local chunk = (M == Q - 1) and rem or W
    local is_last = (M == Q - 1)  -- 必须为布尔值；Lua 中 0 也为真

    local d = nil
    if data_str then
      local off = M * W
      if off < #data_str then
        d = data_str:sub(off + 1, math.min(off + W, #data_str))
      end
    end

    local ok, err = pcall(function()
      return device:write(build_report(cmd, chunk, addr, d, is_last))
    end)
    if not ok or err == false then
      device:error("AULA F87S write failed: " .. tostring(err))
      return false
    end

    -- 只在初始化/模式切换时排空响应；连续 cmd36 帧不做同步读。
    if wait_for_response then
      pcall(function()
        device:read(protocol.REPORT_SIZE, 12)
      end)
    end
  end
  return true
end

--- 切模式（cmd35），payload 16 字节
function protocol.set_mode(mode, brightness, wait_for_response)
  local t = {}
  for i = 1, 16 do t[i] = 0x00 end
  t[1]  = mode
  t[2]  = 255
  t[3]  = 255
  t[4]  = 255
  t[5]  = 255
  t[10] = brightness   -- 亮度 0-5
  t[11] = 3
  t[15] = 0xAA
  t[16] = 0x55
  local chars = {}
  for i = 1, 16 do chars[i] = string.char(t[i]) end
  return send_command(protocol.CMD_SET_LED_EFFECT, table.concat(chars), 16, wait_for_response ~= false)
end

--- 只写自定义灯色；连续动画帧使用此函数，避免每帧重复 cmd35。
--- rgb: 二进制字符串，长度 = led_count * 3，索引 = ledId（R,G,B 交错）
function protocol.update_leds(rgb, hardware_ids)
  return protocol.write_custom(rgb, false, hardware_ids)
end

local last_custom_data = nil
local custom_buffer = {}
local byte_char = {}
for i = 0, 255 do byte_char[i] = string.char(i) end
for slot = 0, protocol.LED_SLOTS - 1 do
  local offset = slot * 4
  custom_buffer[offset + 1] = byte_char[slot]
  custom_buffer[offset + 2] = byte_char[0]
  custom_buffer[offset + 3] = byte_char[0]
  custom_buffer[offset + 4] = byte_char[0]
end
local report_padding = string.rep("\0", protocol.PAYLOAD_SIZE)

local function write_checked(report)
  local ok, result = pcall(device.write, device, report)
  if not ok or result == false or (type(result) == "number" and result <= 0) then
    device:error("AULA F87S write failed: " .. tostring(result))
    return false
  end
  return true
end

local function fast_report(cmd, address, data, is_last)
  return string.char(0, 0xAA, cmd, #data, address % 256,
    math.floor(address / 256), 0, is_last and 1 or 0, 0)
    .. data .. report_padding:sub(1, protocol.PAYLOAD_SIZE - #data)
end

function protocol.reset_cache()
  last_custom_data = nil
  protocol.last_packet_count = 0
end

protocol.last_packet_count = 0

--- Live frames use changed chunks without the slow last=1 commit.
function protocol.write_custom(rgb, need_mode, hardware_ids)

  -- 构建 512 字节 = 128 槽 × [ledId, R, G, B]。
  -- SKYdimo rgb 是连续逻辑索引；hardware_ids 转成 F87S 硬件地址。
  local buf = custom_buffer

  -- 只把 SKYdimo 的 87 个逻辑灯写入校准后的硬件地址。
  -- 不能循环到 LED_SLOTS，否则 hardware_ids[88..128] 会是 nil。
  for logical_index = 0, protocol.LOGICAL_LEDS - 1 do
    local hardware_id = hardware_ids and hardware_ids[logical_index + 1] or logical_index
    local offset = hardware_id * 4
    if offset >= 0 and offset + 4 <= 512 then
      if rgb then
        local r, g, b = string.byte(rgb, logical_index * 3 + 1, logical_index * 3 + 3)
        buf[offset + 2] = byte_char[r or 0]
        buf[offset + 3] = byte_char[g or 0]
        buf[offset + 4] = byte_char[b or 0]
      end
    end
  end
  local data = table.concat(buf)
  local changed = {}
  for address = 0, 511, protocol.PAYLOAD_SIZE do
    local ending = math.min(address + protocol.PAYLOAD_SIZE, 512)
    local chunk = data:sub(address + 1, ending)
    if not last_custom_data or chunk ~= last_custom_data:sub(address + 1, ending) then
      changed[#changed + 1] = { address = address, data = chunk }
    end
  end
  protocol.last_packet_count = 0
  local full_sync = last_custom_data == nil
  for index, chunk in ipairs(changed) do
    -- last=1 incurs a ~54ms device stall. Use it only for full resynchronization
    -- or explicit saved-mode submission; last=0 live writes update LEDs directly.
    local commit = index == #changed and (full_sync or need_mode == true)
    if not write_checked(fast_report(protocol.CMD_SET_CUSTOM_LED_DATA,
        chunk.address, chunk.data, commit)) then
      last_custom_data = nil
      return false
    end
    protocol.last_packet_count = protocol.last_packet_count + 1
  end
  if need_mode == true and #changed > 0 then
    if not protocol.set_mode(protocol.CUSTOM_MODE, protocol.BRIGHTNESS, false) then
      last_custom_data = nil
      return false
    end
    protocol.last_packet_count = protocol.last_packet_count + 1
  end
  last_custom_data = data
  return true
end

--- 把 RGB888 逻辑颜色转换为官方有线实时通道使用的 RGB565。
local function rgb565_bytes(r, g, b)
  local value = ((r or 0) & 0xF8) << 8
  value = value | (((g or 0) & 0xFC) << 3)
  value = value | (((b or 0) & 0xF8) >> 3)
  return math.floor(value / 256) % 256, value % 256
end

--- 发送一帧官方 0x08 实时数据。
--- 与 cmd36 不同：颜色由电脑逐帧编码成 RGB565，键盘只负责接收/显示。
function protocol.write_realtime(rgb, hardware_ids)
  local raw = {}
  for logical_index = 0, protocol.LOGICAL_LEDS - 1 do
    local r = string.byte(rgb, logical_index * 3 + 1) or 0
    local g = string.byte(rgb, logical_index * 3 + 2) or 0
    local b = string.byte(rgb, logical_index * 3 + 3) or 0
    local hi, lo = rgb565_bytes(r, g, b)
    raw[#raw + 1] = hi
    raw[#raw + 1] = lo
  end

  local payload_size = protocol.REALTIME_DATA_SIZE
  local total = math.max(1, math.ceil(#raw / payload_size))
  for index = 0, total - 1 do
    local first = index * payload_size
    local last = math.min(#raw, first + payload_size)
    local chunk_len = last - first
    local packet = {}
    for i = 1, protocol.REALTIME_BODY_SIZE do packet[i] = 0 end
    packet[1] = protocol.REALTIME_COMMAND
    packet[2] = protocol.REALTIME_PARAM
    packet[3] = 0
    packet[4] = total
    packet[5] = index
    packet[6] = chunk_len
    for i = 1, chunk_len do packet[6 + i] = raw[first + i] end

    -- 官方固定报告尾校验：sum 从 0x09 开始，最后为 0xFF - sum。
    local sum = 0x09
    for i = 1, 62 do sum = sum + packet[i] end
    packet[63] = (0xFF - (sum % 256)) % 256

    local chars = {}
    for i = 1, protocol.REALTIME_BODY_SIZE do chars[i] = string.char(packet[i]) end
    local body = table.concat(chars)
    local ok, err = pcall(function()
      -- SKYdimo controller device:write 使用 reportId=0 的 63B 包体，
      -- 与官方 WebHID 的 sendReport(0, body) 等价；不要把 reportId 再写进 body。
      device:write(body)
    end)
    if not ok then
      device:error("AULA F87S realtime write failed: " .. tostring(err))
      return false
    end
  end
  return true
end

return protocol
