-- Calibrated keys plus virtual samples for whole-zone hardware channels.
local layout = {}
layout.WIDTH = 19
layout.HEIGHT = 6
layout.KEY_COUNT = 87
layout.LED_COUNT = 101
local key_map = {
  0, -1, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, -1,
  16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, -1,
  33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, -1,
  50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, -1, 62, -1, -1, -1, -1,
  63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, -1, -1, 74, -1, 75, -1, -1,
  76, 77, 78, -1, -1, 79, -1, -1, 80, 81, 82, -1, -1, 83, 84, 85, 86, -1
}
layout.MAP = {}
for i = 1, layout.WIDTH * layout.HEIGHT do layout.MAP[i] = -1 end
for y = 0, 5 do
  for x = 0, 17 do
    layout.MAP[y * layout.WIDTH + x + 2] = key_map[y * 18 + x + 1]
  end
end
-- Two vertically stacked samples beside the arrow cluster.
local ring_points = {
  {17, 3}, {17, 4}
}
for i, point in ipairs(ring_points) do
  local cell = point[2] * layout.WIDTH + point[1] + 1
  assert(layout.MAP[cell] == -1, "Ring overlaps a calibrated key")
  layout.MAP[cell] = 86 + i
end
for y = 0, 5 do
  layout.MAP[y * layout.WIDTH + 1] = 89 + y
  layout.MAP[y * layout.WIDTH + 19] = 95 + y
end
layout.HARDWARE_IDS = {
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 99, 100, 102,
  16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 92, 103, 104,
  105, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 60, 106,
  107, 108, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 76, 64,
  65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 90, 80, 81, 82, 83,
  84, 85, 86, 87, 88, 89, 91
}
local function average(rgb, first, last)
  local r, g, b = 0, 0, 0
  for index = first, last do
    local cr, cg, cb = rgb:byte(index * 3 + 1, index * 3 + 3)
    r, g, b = r + cr, g + cg, b + cb
  end
  local count = last - first + 1
  return string.char(math.floor(r / count + 0.5),
    math.floor(g / count + 0.5), math.floor(b / count + 0.5))
end
function layout.split_frame(rgb)
  if type(rgb) ~= "string" or #rgb ~= layout.LED_COUNT * 3 then return nil end
  -- Virtual points are not independently addressable hardware LEDs.
  return rgb:sub(1, 87 * 3), average(rgb, 87, 88), average(rgb, 89, 100)
end
return layout
