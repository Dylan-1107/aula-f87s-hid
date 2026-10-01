# SKYdimo 插件实现方法（有线 + 2.4G 无线）

> **本文是适配层文档，不是本仓库的主体。**
> 主体是 [`HID-PROTOCOL.md`](HID-PROTOCOL.md) 描述的 HID 协议——SKYdimo 插件只是它的 Lua 实现之一，
> 不用 SKYdimo 也能接 OpenRGB 或自己写（见 [`OPENRGB.md`](OPENRGB.md)）。
>
> SKYdimo 以 OpenRGB 为后端，控制器走 **Lua 插件**机制。本文记录 AULA F87S 两个插件的完整实现思路与所有关键坑。
> 键位见 [`KEY-MAPPING.md`](KEY-MAPPING.md)。源码在 [`adapters/skydimo/`](../adapters/skydimo)。

---

## 1. 插件目录结构

```text
C:/Program Files/Skydimo/plugins/controller.aula_f87s/           # 有线
C:/Program Files/Skydimo/plugins/controller.aula_f87s_wireless/  # 无线

manifest.json      id / 版本 / 设备匹配规则
main.lua           生命周期：on_validate / on_init / on_tick / on_shutdown
lib/protocol.lua   HID 组包与发送
lib/layout.lua     19×6 / 101 采样点 MAP + HARDWARE_IDS + split_frame
locales/           zh-CN / zh-TW / en-US
```

两个插件**完全独立、互不覆盖**：manifest 的匹配规则分别锁定有线 / 无线的 VID:PID，同一台键盘插线时走有线插件，拔线用接收器时走无线插件。

---

## 2. manifest.json — 设备匹配

```json
{
  "id": "aula_f87s",
  "type": "controller",
  "language": "lua",
  "entry": "main.lua",
  "match": {
    "protocol": "hid",
    "timeout_ms": 100,
    "rules": [{ "vid": "0x38A6", "pid": "0x2908", "interface_number": 3 }]
  },
  "permissions": ["hid:read", "hid:write", "log"]
}
```

无线版只有两处不同：

```json
"id": "aula_f87s_wireless",
"rules": [{ "vid": "0x0C45", "pid": "0xFEF9", "interface_number": 3 }]
```

**`interface_number: 3` 是关键**——它让 SKYdimo 直接把 MI_03（灯光配置口）交给插件，插件不需要自己枚举设备、不需要管理员权限。

---

## 3. 生命周期

| 回调 | 有线插件 | 无线插件 |
|---|---|---|
| `on_validate` | 设置厂商/型号/序列号 | 额外 `protocol.probe()` 校验 `cmd16` 本体 ID，不是 F87S 就返回 false |
| `on_init` | `add_output` 注册矩阵 + `cmd35` 切 custom 模式 | 读 `cmd19`+`cmd20` 快照；失败则交给 `on_tick` 重试（应对键盘休眠） |
| `on_tick` | 取 RGB → 差分写 cmd36 | 节流 1/60；失败则退避到 2 秒；初始化未完成时重试 |
| `on_shutdown` | 熄灭全部按键 | 写回快照（原表 + 原模式），失败报错 |

### 3.1 注册输出

```lua
device:add_output({
  id = "keys", name = "Keyboard", type = "matrix", size = layout.LED_COUNT,
  matrix = { width = layout.WIDTH, height = layout.HEIGHT, map = layout.MAP },
  capabilities = {
    editable = false,
    min_total_leds = layout.LED_COUNT,
    max_total_leds = layout.LED_COUNT,
    allowed_total_leds = { layout.LED_COUNT }
  }
})
```

> 早期踩坑：`editable` 写 false 且缺 `allowed_total_leds` 时，UI 不允许切换灯效。
> 有线插件若要在 UI 里改灯效，需要 `editable = true`、`default_effect = "Rainbow"`、
> `allowed_total_leds = { layout.LED_COUNT }`（当前 **101**，不是 87）。

### 3.2 只注册一个输出

早期版本把按键、星环、侧灯注册成三个输出，SKYdimo 里显示为三个设备条目，体验很差。
现在**两个插件都只注册一个 `keys` 矩阵**（19×6 / 101 采样点），灯区作为虚拟采样点并入同一张网格：

```lua
local keys, ring, side = layout.split_frame(rgb)
protocol.update(keys, layout.HARDWARE_IDS, ring, side)
```

> ⚠️ **插件加载优先级**：SKYdimo 会优先加载
> `%APPDATA%\Roaming\com.skydimo.desktop\plugins\controller.aula_f87s_wireless`，
> 它**覆盖** `C:/Program Files/Skydimo/plugins/` 下的同名插件。
> 改了 Program Files 却没生效时，先查用户目录里是不是有一份旧的。

---

## 4. 六个必须记住的实现要点

### ① `device:write()` 的第一个字节是 Report ID

```lua
device:write(string.char(0) .. body64)   -- 合计 65 字节
```

与 node-hid 的 `write()` 约定一致。漏了前缀会导致整包错位——这是实时路径第一次失败的直接原因。

### ② 必须填满全部 128 槽，再写 87 个颜色

```lua
-- 先铺 128 槽，ledId = 槽位下标
for slot = 0, 127 do
  buf[slot*4+1] = string.char(slot)
  buf[slot*4+2], buf[slot*4+3], buf[slot*4+4] = "\0", "\0", "\0"
end
-- 再把逻辑索引 k 的颜色写到 HARDWARE_IDS[k+1]
for k = 0, 86 do
  local hw = layout.HARDWARE_IDS[k + 1]        -- Lua 1 基
  local r, g, b = rgb:byte(k*3+1, k*3+3)
  buf[hw*4+2], buf[hw*4+3], buf[hw*4+4] = string.char(r), string.char(g), string.char(b)
end
```

> **只写 87 槽会让后 41 槽为 nil，破坏已校准的 ledId 字节**，表现为功能区、右 Ctrl/Shift、Enter 不亮。

### ③ `mode=20` / `brightness=5`，且 cmd35 不要每帧发

`cmd35` 只在初始化（或首次同步）执行一次。每帧多一包开销，而且 `last=1` 会触发约 54 ms 的设备 stall。

### ④ 差分更新 + `lastFlag=0`（性能关键）

```lua
for address = 0, 511, 56 do
  local chunk = data:sub(address+1, math.min(address+56, 512))
  if chunk ~= last_table:sub(address+1, address+#chunk) then
    write(cmd36, chunk, address, last = false)   -- 连续帧用 0
  end
end
```

首次同步仍走「全表 10 包（末包 `last=1`）+ cmd35 提交 + 逐包 ACK」。之后只发变化的分包。
87 键地址全部落在前 8 个 56 B 分包内，后 2 包逐帧可跳过。

### ⑤ Lua 里没有 `device:sleep`

延时靠 `device:read(size, timeout_ms)` 的超时实现：

```lua
local function drain()
  for _ = 1, 32 do
    local ok, raw = pcall(device.read, device, 65, 0)
    if not ok then return false end
    if type(raw) ~= "string" or #raw == 0 then return true end
  end
  return false
end
```

### ⑥ 写返回值要宽容处理

不同宿主 `device:write` 的返回值可能是 `true` / 字节数 / `0` / `false` / `nil`，只判断「真 或 正数」：

```lua
local ok, count = pcall(device.write, device, packet)
return ok and (count == #packet or count == true)
```

---

## 5. 无线插件的额外处理

无线比有线多三件事，全部围绕「不可靠链路」：

1. **本体校验**：`cmd16` 返回 `38A6:2908` 才接受该接收器，防止配错键盘。
2. **快照优先**：`cmd19`+`cmd20` 都读成功才允许改灯，否则 `on_tick` 里重试（键盘休眠时首次查询常超时）。
3. **关灯还原**：`on_shutdown` 写回原表 → 原模式；失败用 `device:error` 明确上报，不静默。

另外无线版节流为 `1/60`，失败后退避到 2 秒重试；`write` 失败时清空 `last_rgb / last_table`，下一帧强制完整 11 包恢复。

---

## 6. 部署步骤

1. **完全关闭 SKYdimo**（含托盘）。
2. 把插件目录复制到 `C:/Program Files/Skydimo/plugins/` —— **`C:/Program Files` 需要管理员权限**，普通权限 Node 写入会 `EPERM`。
3. 覆盖前先备份目标目录（本项目内置 `.bak` 机制）。
4. 重启 SKYdimo。
5. 验证设备档案出现：
   `%APPDATA%\com.skydimo.desktop\devices\AULA-AULA_F87S-*.json`
   其中 `lastSeenControllerId` 应为 `aula_f87s`（无线为 `aula_f87s_wireless`）。
6. 在 UI 里给该设备选灯效，目视确认。

> ⚠️ **「设备被识别」≠「灯效验证通过」**，两者差一次目视确认。

---

## 7. 离线测试（Lua mock）

不接硬件也能验证插件逻辑。[`adapters/skydimo/tests/mock-test-wireless.py`](../adapters/skydimo/tests/mock-test-wireless.py)
用 Lua 5.4 模拟 `device` 对象，**当前 34 项断言全部通过**：

- 初始化 + 首帧：`19` + `20`×10 + `27, 29` + `36`×10 + `35, 43, 45`
- 后续变化帧：仅变化的 `36` 分包（`last=0`），不发 `35`
- 单键变化：只发 1 包
- 写失败后：下一帧完整重新同步
- 关闭：`36`×10 + `35, 43, 45`，状态回到快照原值
- `device:write` 返回短写 / `0` / `false` / `nil` / 抛异常，全部不崩溃
- 快照缺失时拒绝改灯；休眠唤醒后在 `on_tick` 重试初始化

```bash
pip install lupa
cd adapters/skydimo/tests
python mock-test-wireless.py
```

> **这只是 Lua 层 mock**，验证「插件发的包是对的」；不验证 SKYdimo 渲染、真实灯珠或帧率。
> 有线插件暂无对应 mock，欢迎 PR。

---

## 8. 已知未决问题

| # | 问题 | 状态 |
|---|---|---|
| 1 | SKYdimo 内实际视觉效果 | ✅ 无线已确认单输出 + 紧凑矩阵；有线渲染待目视 |
| 2 | 矩阵横纵转置（若转置只改 MAP，不改 HARDWARE_IDS） | ✅ 当前布局已按实机确认 |
| 3 | 无线 `last=0` 差分版的真实帧率 | ⚠️ 未实测（mock 只验证包序列） |
| 4 | 装饰灯区（星环 + 侧灯，cmd43/45） | ✅ 无线已实测读写恢复；有线代码已对齐、未实测 |
| 5 | `0x08` 实时通道在 F87S 上显示未证实 | ❌ 已禁用 |
| 6 | 87 键无线映射仅确认 Delete=106，其余继承有线校准 | ⚠️ 未逐键复测 |
| 7 | 灯区采样点为虚拟点，硬件上是整区单色 | ⚠️ 设计如此，不可逐灯珠控制 |
