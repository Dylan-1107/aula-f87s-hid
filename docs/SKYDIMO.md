# SKYdimo 插件实现方法（有线 + 2.4G 无线）

> **本文是适配层文档，不是本仓库的主体。**
> 主体是 [`HID-PROTOCOL.md`](HID-PROTOCOL.md) 描述的 HID 协议——SKYdimo 插件只是它的 Lua 实现之一，
> 不用 SKYdimo 也能接 OpenRGB 或自己写（见 [`OPENRGB.md`](OPENRGB.md)）。
>
> SKYdimo 以 OpenRGB 为后端，控制器走 **Lua 插件**机制。本文记录 AULA F87S 两个插件的完整实现思路与所有关键坑。
> 键位见 [`KEY-MAPPING.md`](KEY-MAPPING.md)。源码在 [`adapters/skydimo/`](../adapters/skydimo)。
>
> ⚠️ **插件有两个变体**，先去 [`adapters/skydimo/README.md`](../adapters/skydimo/README.md) 选一个：
> **🏃 `lowest-latency`**（18×6 / 87 键，延迟最优，装饰灯保留官方预设）
> 和 **🎨 `best-effects`**（19×6 / 101 点，效果最好，含星环与侧灯）。
> 下面各节的矩阵尺寸以 **`best-effects`** 为准；`lowest-latency` 的差异是
> **没有灯区采样点、不接管 cmd43/45**。

### SKYdimo 是什么

SKYdimo 是一个桌面灯效控制软件，**内置完整 OpenRGB 作为后端**（自带 `OpenRGB.exe` +
`hidapi.dll` + Qt5 DLL）。它的设备控制器走 Lua 插件机制，插件放在
`C:/Program Files/Skydimo/plugins/` 下即可被自动识别。

**它对本项目不是必需的** —— 不用它也能直接接 OpenRGB 或自己写程序，
见 [`OPENRGB.md`](OPENRGB.md)。

### 插件可用的 `device` API

写插件时宿主注入的全局 `device` 对象提供这些方法（按用途分组）：

| 类别 | 方法 |
|---|---|
| 生命周期 | `on_validate` / `on_init` / `on_tick(dt)` / `on_shutdown` |
| HID | `device:write(string)` / `device:read(size, timeout_ms)` |
| 取色 | `device:get_rgb_bytes(output_id)` |
| 注册输出 | `device:add_output({...})` |
| 设备信息 | `set_manufacturer` / `set_model` / `set_device_type` / `set_description` / `set_serial_id` / `serial_id` / `controller_port` |
| 日志 | `device:log(msg)` / `device:error(msg)` |

> ⚠️ **没有 `device:sleep`** —— 延时只能靠 `device:read(size, timeout_ms)` 的超时实现。

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
| `on_validate` | 设置厂商/型号/序列号 | **只按 manifest 的 VID/PID 认领，不发任何命令** |
| `on_init` | `add_output` 注册矩阵 + `cmd35` 切 custom 模式 | 试一次 `identify()`；成功则读 `cmd19`+`cmd20` 快照，失败留给 `on_tick` |
| `on_tick` | 取 RGB → 差分写 cmd36 | 未识别时每 2 秒重试 `identify()`；**已识别后每 2 秒额外发一次 `ping()` 心跳**；休眠期只发心跳不推灯效帧；正常节流 1/60，失败退避 2 秒 |
| `on_shutdown` | 熄灭全部按键 | 写回快照（原表 + 原模式），失败报错 |

> ⚠️ **无线插件的 `on_validate` 里绝对不要做 I/O 探测**—— 见下方 §5.1。
> ⚠️ **无线插件必须有 `ping()` 心跳**—— 见下方 §5.2。

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

布局为什么长这样（侧灯在最外侧两列、星环只有 2 格）见
[`KEY-MAPPING.md` §5.2](KEY-MAPPING.md#52-为什么是-19-列为什么星环只有-2-格)——都是从实机结构来的。

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

1. **三态本体校验**：`cmd16` 返回 `38A6:2908` 才接受该接收器。
2. **快照优先**：`cmd19`+`cmd20` 都读成功才允许改灯，否则 `on_tick` 里重试。
3. **关灯还原**：`on_shutdown` 写回原表 → 原模式；失败用 `device:error` 明确上报，不静默。

另外无线版节流为 `1/60`，失败后退避到 2 秒重试；`write` 失败时清空 `last_rgb / last_table`，下一帧强制完整 11 包恢复。

### 5.1 为什么 `on_validate` 里不能探测（真实踩坑）

**症状**：设备列表里「未发现设备」。日志里反复出现：

```text
ERROR controller plugin device error  plugin=aula_f87s_wireless
      msg="F87S 2.4G: response timeout cmd=16 address=0"
      span={"trigger":"hotplug","name":"devices.scan"}
```

**根因**：2.4G **接收器**是常驻 USB HID 端点（所以 Windows 一直看得见、一直触发热插拔扫描），
但**键盘本体休眠时对 `cmd16` 完全不应答**。旧实现把本体校验放在 `on_validate`：

```lua
--❌ 错误写法
function plugin.on_validate()
  if not protocol.probe() then return false end   -- 超时 → 设备被永久丢弃
  ...
end
```

`on_validate` 返回 `false` 的设备**不会被保留、也没有重试入口**。于是：

- 启动扫描失败 → 设备不出现；
- 你手动点「扫描设备」，如果那一刻键盘恰好休眠 → 还是失败；
- **必须先按一下键盘让它醒着，再点扫描**，才能刷出来。

**修法**：把「认领」和「校验」拆开。

| | 旧 | 新 |
|---|---|---|
| `on_validate` | 发 `cmd16`，超时即拒| 只按 manifest 的 VID/PID + 接口号认领，**一个字节都不发** |
| 本体校验 | 在 `on_validate` | 移到 `on_tick`，**每 2 秒重试一次**，独立节流 |
| 休眠表现 | 设备消失 | 设备常驻列表，按一下键盘即自动接管 |

`identify()` 返回三态，区分「不是 F87S」和「没应答」：

```lua
"f87s"   -- 确认是 F87S 本体
"other"  -- 接收器在线，但后面挂的不是 F87S → 明确拒绝，不再重试
"silent" -- 没有任何应答（休眠/ 未按醒）→ 保留设备，2 秒后重试
```

识别成功时调用 `protocol.resync()` 清掉差分基线，保证唤醒后的第一帧是**完整表**而不是差分包。

> 这个修复同时消除了另一个副作用：`on_validate` 里的阻塞式探测曾让每次热插拔扫描
> 卡住约 880 ms（见日志 `time.busy":"984ms"`）。

### 5.2 为什么必须有 `ping()` 心跳（唤醒不恢复预设）

§5.1 修好了「设备从列表消失」，但**没有**修好「唤醒后灯效回不来」。这是个更隐蔽的坑，
根因是**两处状态分居两地**：

|状态 | 存在哪 | 休眠时|
|---|---|---|
| 差分基线 `last_rgb` / `last_table` | **插件进程**里 | 一直保留，认为「已同步」 |
| 实际灯效表 | **键盘 MCU** 里 | 唤醒时LED 引擎重新初始化，**被清空** |

关键在于**2.4G 接收器是常驻 USB HID 端点**：键盘本体睡掉后，`device.write()`
**照样返回成功**（接收器吞了报文）。于是差分基线在一片漆黑中一路推进，
等本体醒来时 `protocol.update()` 命中这句早退：

```lua
if rgb == last_rgb and ring_rgb == last_ring_rgb and side_rgb == last_side_rgb then
  return true   -- 一个字节都不发，灯效永远回不来
end
```

表现就是：**动画预设能自愈**（每帧 RGB 都在变，差分持续触发重发），
**静态预设永久卡死**（RGB 不变，永远命中早退）。

修法是加一条独立节流的轻量心跳，休眠期只探测不推帧：

```lua
state.probe_elapsed = state.probe_elapsed + step
if state.probe_elapsed >= PROBE_INTERVAL then       -- 2 秒
  state.probe_elapsed = 0
  if protocol.ping() then
    if state.asleep then                -- silent → f87s 的跳变
      state.asleep = false
      protocol.resync()                  -- 丢掉已经失效的差分基线
      device:log("F87S 2.4G: keyboard awake; relighting the current preset")
    end
  elseif not state.asleep then
    state.asleep = true
    device:log("F87S 2.4G: keyboard asleep; lighting frames paused")
  end
end
if state.asleep then return end        -- 休眠期只发心跳，不推灯效帧
```

| | 旧 | 新 |
|---|---|---|
| 休眠期行为 | 继续推帧，基线推进成假象 | 只发 `ping()`，不推任何灯效包 |
| 唤醒后 | 命中早退，**什么都不发** | 探测到应答 → `resync()` → **整表重发** |
| 恢复延迟 | 永不恢复 | ≤ 2 秒（心跳间隔） |

`ping()` 必须比`identify()` 便宜得多，否则常驻心跳会把插件线程钉住：

| | `identify()` | `ping()` |
|---|---|---|
| ACK 尝试 | 2 轮 × 4 次 × 150 ms | 2 次 × 80 ms |
| 无应答时最坏耗时 | **≈ 1.3 s** | **≈ 0.16 s** |

---

## 6. 部署步骤

1. **完全关闭 SKYdimo**（含托盘）。
2. 优先部署到**用户目录**—— 它才是真正生效的那份：
   `%APPDATA%\com.skydimo.desktop\plugins\`
3. 如需同时更新 `C:/Program Files/Skydimo/plugins/`，**`C:/Program Files` 需要管理员权限**，
   普通权限 Node/Bash 写入会 `Permission denied`。
4. 覆盖前先备份目标目录。
5. 重启 SKYdimo。
6. 验证设备档案出现：
   `%APPDATA%\com.skydimo.desktop\devices\AULA-AULA_F87S-*.json`
   其中 `lastSeenControllerId` 应为 `aula_f87s`（无线为 `aula_f87s_wireless`）。
7. 在 UI 里给该设备选灯效，目视确认。

> ⚠️ **「设备被识别」≠「灯效验证通过」**，两者差一次目视确认。

### 6.1 只改Program Files 会不生效

`core.log` 里这行是明确信号：

```text
WARN duplicate controller plugin id; skipping   span={"name":"plugins.initialize"}
```

两个目录存在同名插件时，SKYdimo **只加载用户目录那份**，Program Files 的被跳过。
所以改了 Program Files 却没变化时，先去用户目录确认是不是有一份旧的。

本次实际遇到的情况：用户目录是旧版（87 键），Program Files 是新版（101 采样点），
日志显示跳过重复项后生效的始终是用户目录那份。**修好后应把两份保持一致。**

### 6.2 排查「设备扫不出来」

日志在：`%LOCALAPPDATA%\com.skydimo.desktop\logs\core.log`

```bash
# 只看无线插件相关的行
grep "aula_f87s_wireless" core.log | tail -30

# 看扫描结果（added=0 就是没扫到）
grep -o '"message":"manual scan completed".*' core.log | tail -5
```

看到 `response timeout cmd=16` 就是本体没应答——**修复后不应该再导致设备消失**，
只会看到设备常驻列表 + 每 2 秒一次的 `cmd16` 探测。按一下键盘即可接管。

---

## 7. 离线测试（Lua mock）

不接硬件也能验证插件逻辑。[`adapters/skydimo/best-effects/tests/mock-test-wireless.py`](../adapters/skydimo/best-effects/tests/mock-test-wireless.py)
用 Lua 5.4 模拟 `device` 对象，**当前 88 项断言全部通过**：

- 初始化 + 首帧：`19` + `20`×10 + `27, 29` + `36`×10 + `35, 43, 45`
- 后续变化帧：仅变化的 `36` 分包（`last=0`），不发 `35`
- 单键变化：只发 1 包
- 写失败后：下一帧完整重新同步
- 关闭：`36`×10 + `35, 43, 45`，状态回到快照原值
- `device:write` 返回短写 / `0` / `false` / `nil` / 抛异常，全部不崩溃
- 快照缺失时拒绝改灯；休眠唤醒后在 `on_tick` 重试初始化
- **休眠回归**（见 §5.1）：`on_validate` 零总线流量、睡眠期只发 `cmd16` 探测、
  2 秒节流不重复探测、按一下键即完整接管并整表同步、唤醒后仍能还原原灯效
- **唤醒回归**（见 §5.2）：mock 增加 `asleep` 模式（**接收器照常吞包并返回成功，
  但本体不应答**）+ `asleep_reset()`（模拟 LED 引擎重init 把硬件表清零），
  覆盖「心跳发现休眠 → 休眠期零灯效包 → 唤醒整表重发 → 预设真的回到硬件 →
  稳定帧回到静默」，并跑两轮完整睡眠周期防基线漂移
- **错配回归**：非 F87S 键盘接在接收器上 → 通过 VID 认领但首次重试即拒绝，
  之后不再重试、从未下发任何灯光命令

> **回归有效性已验证**：把 `main.lua` 里的心跳与 `asleep` 门控临时摘掉再跑，
> 上面的唤醒回归有 **8 项失败**（含 `the second wake also republishes the full table`、
> `the preset survives repeated sleep cycles`），确认这些断言真的能捕获该 bug，
> 不是自证式测试。

```bash
pip install lupa
cd adapters/skydimo/best-effects/tests
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
| 7 | 灯区采样点均为虚拟点，硬件上是整区单色 | ⚠️ 设计如此：旋钮仅**半边**有灯，侧灯在**底壳外侧**，都不可逐灯珠控制 |
| 8 | 休眠键盘能否不重扫自动接管 | ✅ 已在 mock 覆盖（§5.1），**待实机验证** |
| 9 | 休眠唤醒后静态预设能否自动恢复 | ✅ 已在 mock 覆盖（§5.2，含两轮周期），**待实机验证** |
