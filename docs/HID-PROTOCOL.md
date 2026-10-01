# AULA F87S — 逆向 HID 灯光接口文档（有线 + 2.4G 无线）

> **本文件是整个仓库的主体。** SKYdimo / OpenRGB / CLI 工具都只是这套协议的适配层，
> 任何能发 64 字节 HID output report 的程序都可以直接用它，**不需要装任何灯效软件**。
>
> 版本 v1.0 · 2026-10-01
> 目标：用第三方程序（node-hid / OpenRGB / SKYdimo / 自写脚本）直接控制狼蛛 AULA F87S 8K 的 87 键逐键 RGB。
> 方法：USB HID 枚举 + Windows HID capabilities + 官方配置协议黑盒实测（未使用任何厂商源码）。
> 本文不依赖 AULA Hub 官方驱动，也不包含任何厂商专有代码。

**一句话可用流程：`cmd36` 写 128 槽 RGB888 表 → `cmd35` 切 `mode=20, brightness=5`。有线与无线通用。**
装饰灯（旋钮星环 / 两侧灯条）是**整区单色**通道，走 `cmd43` / `cmd45`，见 §5.5。

**想接 OpenRGB？** → [`OPENRGB.md`](OPENRGB.md)（三条路径，均不需要 SKYdimo）
**键位地址表？** → [`KEY-MAPPING.md`](KEY-MAPPING.md)

---

## 0. 证据等级（请先读）

本文档严格区分「已实测确认」与「推断 / 未验证」，请勿把前者当后者用。

| 标记 | 含义 |
|---|---|
| ✅ 已验证 | 本机实机跑通，含回读或用户目视确认 |
| ⚠️ 部分验证 | 只有 ACK / 回读一致，或只验证了个别按键 |
| ❌ 未验证 | 有源码线索但未在 F87S 上证明显示生效 |
| ⛔ 禁止 | 会写固件 / 校准区，永远不要发 |

**「配置回读一致」与「灯珠真的亮了」是两种不同证据。** ACK 只证明键盘收下了数据，不能推断光学刷新率。

---

## 1. 设备识别

### 1.1 两条物理通路

| 模式 | VID : PID | 产品字符串 | 灯光配置口 | usagePage : usage |
|---|---|---|---|---|
| **有线** | `0x38A6 : 0x2908` | AULA F87S 8K | **MI_03**（interface 3） | `0xFF68 : 0x0061` |
| **2.4G 无线** | `0x0C45 : 0xFEF9` | 8K Wireless Receiver | **MI_03**（interface 3） | `0xFF60 : 0x0061` |

两条通路**共用同一套命令、同一份 87 键映射、同一种 RGB888 编码**。差别只有 VID/PID 和 usagePage。

> ⚠️ 无线接收器的 VID/PID 与键盘本体不同，这是正常的。`cmd16` 返回的本体 ID 才是 `0x38A6:0x2908`。
> **写入前务必用 `cmd16` 校验本体 ID**，防止同型号接收器配对了别的键盘。

### 1.2 接口拓扑（两者都是 5 接口复合设备）

| 接口 | 有线 `38A6:2908` | 2.4G 接收器 `0C45:FEF9` | 用途 |
|---|---|---|---|
| MI_00 | 标准键盘 | 键盘 | 打字 |
| MI_01 | 键盘 + 4 个 vendor 集合 | 键盘 + vendor 集合 | — |
| MI_02 | `0xFF71` | 键盘 / 消费控制 / 系统控制 | — |
| **MI_03** | **`0xFF68:0x61`** | **`0xFF60:0x61`** | **★ 灯光配置口** |
| MI_04 | `0xFF70:0x71` | `0xFF70:0x71` | 无关状态口，返回垃圾 |

**只向 MI_03 发灯光命令。** 早期踩坑：往 MI_04 写会「写入成功却全黑」。

### 1.3 Windows HID capabilities（MI_03 实测）

| 字段 | 字节数 | 说明 |
|---|---:|---|
| InputReportByteLength | 65 | 含 Report ID 槽 |
| OutputReportByteLength | 65 | 含 Report ID 槽 |
| FeatureReportByteLength | **0** | **没有 Feature Report** |

F87S **不存在 feature report**，不要照抄其他 AULA 型号的 `sendFeatureReport` 实现。

设备路径随 USB 端口变化，**不要硬编码 `\\?\HID#...`**，用 VID/PID + interface + usagePage 枚举。

---

## 2. 报告帧格式

本文所有偏移**从 64 字节报告体的第 0 字节开始**，不含主机 API 的 Report ID 前缀。

```text
Report ID      = 0
报告体          = 64 B
包头            = 8 B
每包有效载荷     = 56 B        (64 - 8)
node-hid.write = [0x00, ...64B 报告体]  → 合计 65 B
device:write   = 同上，第一个字节是 Report ID
WebHID         = sendReport(0, body64)，不要再把 Report ID 拼进 body
```

### 2.1 请求包

```text
AA cmd len addrLo addrHi 00 lastFlag 00 [payload ...] [zero padding ...]
```

| 报告体偏移 | 字节 | 字段 | 说明 |
|---:|---:|---|---|
| 0 | 1 | header | 固定 `0xAA` |
| 1 | 1 | cmd | 命令编号 |
| 2 | 1 | len | **本包**声明的有效长度，0..56 |
| 3 | 1 | addrLo | 数据区字节偏移低 8 位 |
| 4 | 1 | addrHi | 数据区字节偏移高 8 位 |
| 5 | 1 | other0 | 普通配置命令填 0 |
| 6 | 1 | lastFlag | 非末包 0，末包 1 |
| 7 | 1 | other2 | 填 0 |
| 8..63 | ≤56 | data | 写入数据 / 读取查询占位，不足补 0 |

- 地址是 **little-endian 16 位「数据区字节偏移」**，不是包号、不是按键编号。
- byte4 是地址高位，byte6 是末包标记，**不要混用**。
- 普通配置包**没有额外校验和**。不要附加其他型号 report 9 的校验尾字节。
- 读命令同样要声明长度，用等长全 0 查询数据构造，保证声明长度与分包一致。

### 2.2 响应包（ACK）

```text
55 cmd len addrLo addrHi ?? ?? ?? [data ...] [padding ...]
```

| 报告体偏移 | 字段 | 处理规则 |
|---:|---|---|
| 0 | header | 必须为 **`0x55`**（发出是 `0xAA`，收回是 `0x55`） |
| 1 | cmd | 应匹配当前请求命令 |
| 2 | len | 本包有效载荷长度 |
| 3..4 | addr | little-endian 地址 |
| 5..7 | 其他 | 不照搬请求字段语义，未明确字段保留 |
| 8 起 | data | **只取 `len` 字节**，尾部是 padding |

```js
const r = Buffer.from(device.readTimeout(timeoutMs));
const address = r.readUInt16LE(3);
const data = r.subarray(8, 8 + r[2]);   // 必须按 len 截断
```

可校验 cmd / addr / len 三项。但**不要把「地址必须严格匹配」当成全产品线通用要求**——官方实现默认只匹配命令，地址校验是可选项。

---

## 3. 分包规则

```text
W = 64 - 8 = 56
分包数 = ceil(contentSize / 56)
第 i 包 addr = i * 56
本包 len     = min(56, contentSize - addr)
末包 lastFlag = 1，其余为 0
```

512 B 自定义表 = **10 包**：

| 包 | addr | addrLo/addrHi | len | last |
|---:|---:|---|---:|---:|
| 0 | 0 | `00 00` | 56 | 0 |
| 1 | 56 | `38 00` | 56 | 0 |
| 2 | 112 | `70 00` | 56 | 0 |
| 3 | 168 | `A8 00` | 56 | 0 |
| 4 | 224 | `E0 00` | 56 | 0 |
| 5 | 280 | `18 01` | 56 | 0 |
| 6 | 336 | `50 01` | 56 | 0 |
| 7 | 392 | `88 01` | 56 | 0 |
| 8 | 448 | `C0 01` | 56 | 0 |
| 9 | 504 | `F8 01` | 8 | **1** |

**每包串行：发送 → 等 ACK → 再发下一包。** 不要让多帧或查询交错发送。

### 3.1 lastFlag 的重要实测（性能优化关键）

| 场景 | lastFlag | 实测单包耗时 |
|---|---|---|
| 提交型写入（末包 / 首次同步） | 1 | **≈ 54.47 ms**（设备端 stall） |
| 连续帧差分写入 | **0** | **≈ 0.279 ms**，且颜色输出回读生效 |

→ **优化策略**：初始化时全表 10 包（末包 `last=1`）+ `cmd35` 提交；之后每帧只发**变化的 56 B 分包，全部 `last=0`**，不再每帧发 `cmd35`。
87 键的硬件地址全部落在前 8 个分包内，后 2 包无需逐帧重发。

---

## 4. 命令表

### 4.1 白名单（本文可安全使用）

| 十进制 | 十六进制 | 名称 | contentSize | 说明 |
|---:|---|---|---:|---|
| 16 | `0x10` | GET_DEVICE_INFO | 56 B | 读本体 VID/PID、电量、版本 |
| 19 | `0x13` | GET_LED_EFFECT | 16 B | 读当前灯效参数（**用于快照**） |
| 20 | `0x14` | GET_CUSTOM_LED_DATA | 512 B | 读 128 槽颜色表（**用于快照**） |
| 27 | `0x1B` | GET_RING_ZONE | 24 B | 读**旋钮星环**参数（⚠️ 见 5.5） |
| 29 | `0x1D` | GET_SIDE_ZONE | 24 B | 读**两侧灯条**参数（⚠️ 见 5.5） |
| 35 | `0x23` | SET_LED_EFFECT | 16 B | 切模式 / 亮度 |
| 36 | `0x24` | SET_CUSTOM_LED_DATA | 512 B | 写逐键颜色 |
| 43 | `0x2B` | SET_RING_ZONE | 24 B | 写**旋钮星环**整区颜色 |
| 45 | `0x2D` | SET_SIDE_ZONE | 24 B | 写**两侧灯条**整区颜色 |
| 51 | `0x33` | GET_ALL_LIGHTS_RGB | 512 B | 读物理输出（需先发查询载荷，⚠️ 见 5.4） |

### 4.2 ⛔ 禁止列表

| cmd | 名称 | 禁止原因 |
|---|---|---|
| **79** | SET_FLASH_DOWNLOAD | **写固件，可能变砖** |
| 15 | SET_FACTORY_RESET | 恢复出厂 |
| 校准类命令 | — | 可能破坏灯效校准 |
| 80 / 81 | SET_TFT_* | F87S 无 TFT 屏 |

命令编号只在官方驱动里出现过，**不代表本机可用**。本项目工具只放行白名单命令。

---

## 5. 命令详解

### 5.1 cmd16 — 设备信息（56 B 响应）

偏移从拼接后的 **56 B 响应数据区**开始（不含 8 B 头）：

| 数据偏移 | 类型 | 含义 |
|---:|---|---|
| 4..5 | uint16 LE | 键盘本体 VID |
| 6..7 | uint16 LE | 键盘本体 PID |
| 8..9 | 编码 | 版本号 |
| 12..13 | uint16 LE | 厂商内部标识 |
| 14..15 | uint16 LE | 产品内部标识 |
| 16 | uint8 | workMode（枚举语义未独立验证） |
| 17 | uint8 | **batteryLevel** |
| 18 | uint8 | chargeStatus（枚举语义未独立验证） |
| 26..27 | uint16 LE | ledMaxFrames（**不等于实时 FPS**） |
| 30 | uint8 | frameVersion |
| 31 | uint8 | lightingVersion |

```js
const version = ((d[8] & 15) + ((d[8] & 240) >> 4) * 10 + d[9] * 100) / 100;
```

本机实测：本体 `38A6:2908`、电量 100、frameVersion 0、lightingVersion 1。
⚠️ 版本字段**不能**用来推断刷新速率。

请求报告体头（单包）：`AA 10 38 00 00 00 01 00` + 56 B 全 0。

### 5.2 cmd19 / cmd35 — 灯效参数（16 B）

cmd19 读、cmd35 写，结构相同：

| 数据偏移 | 字段 | 自定义配置建议 |
|---:|---|---|
| 0 | mode | **20 (`0x14`) = custom** |
| 1..3 | 主色 R/G/B | 可保留读回值；逐键颜色来自 cmd36 |
| 4 | 固定字段 | 官方写入 255；读回可能不同，不作错误判定 |
| 5..7 | secondaryR/G/B | 可保留读回值 |
| 8 | colorMode | 0 |
| 9 | **brightness** | **0..5，5 最亮** |
| 10 | speed | 保留读回值（测试值 3） |
| 11 | direction | 保留读回值（测试值 0） |
| 12 | effectModeType | 保留读回值（测试值 0） |
| 13 | 保留 | 0 或保留读回值 |
| 14 | 固定结尾 | `0xAA` |
| 15 | 固定结尾 | `0x55` |

**★ 两个致命参数（卡了一整天的根因）**

| 参数 | 正确值 | 错误后果 |
|---|---|---|
| `mode` | **20** | 填 1 / 3 / 12 会显示板载内置动画，**不是**自定义表 |
| `brightness` | **5**（量程 0–5） | 填 255 会溢出 → **全黑** |

建议先 `cmd19` 读回原值，只改 `mode=20`、`brightness=5` 和结尾 `AA 55`，把无关字段改动降到最小（关机时才能完整还原）。

cmd35 请求头（单包）：`AA 23 10 00 00 00 01 00` + 16 B 参数 + 补 0。

### 5.3 cmd20 / cmd36 — 自定义颜色表（512 B）

```text
总长 512 B = 128 槽 × 4 B
第 s 槽 = [s, R, G, B]     偏移 s*4     s ∈ 0..127
编码 = RGB888，每分量 0..255
```

- **槽 ID 固定写槽位下标 `s`。** 固件按数组下标取色，传入的 ledId 值不参与寻址。
- **有线和无线都是 RGB888**，无线**不是** RGB565。
- 必须填满全部 **128 槽**；只写 87 槽会让后 41 槽缺失，破坏已校准字节（表现为功能区 / 右 Ctrl / Enter 不亮）。

cmd36 首包：`AA 24 38 00 00 00 00 00`；末包：`AA 24 08 F8 01 00 01 00`。
cmd20 只需把命令字节换成 `14`。

### 5.4 cmd51 — 读物理输出（⚠️ 存疑）

必须先发 512 B 查询载荷 `[ledId=o,0,0,0]`（o = 0..127），键盘才回填颜色。

⚠️ **最新基准中读数恒为 `[252,252,252]`，与自定义表不一致**，因此 cmd51 是否为真实物理输出读数仍存疑。可用它做「有没有变」的粗校验，不要当作权威颜色回读。

### 5.5 cmd27 / cmd29 / cmd43 / cmd45 — 灯区参数（24 B）

除 87 个按键外，F87S 还有两组**装饰灯**：旋钮星环（ring）与两侧灯条（side）。
它们**不是逐灯珠可寻址**——每组只能整体设一个颜色。

| cmd | 方向 | 名称 | 载荷 |
|---:|---|---|---|
| 27 | 读 | GET_RING_ZONE | 24 B 全 0 查询 |
| 29 | 读 | GET_SIDE_ZONE | 24 B 全 0 查询 |
| 43 | 写 | SET_RING_ZONE | 24 B 参数块 |
| 45 | 写 | SET_SIDE_ZONE | 24 B 参数块 |

24 B 参数块结构（**只改颜色，其余字节必须回写原值**）：

```text
[0]     zone byte 0 —— 原样保留（疑似模式/开关，未逆向语义）
[1]     R
[2]     G
[3]     B
[4..23] 其余参数 —— 原样保留
```

```lua
-- 参考实现：取快照原值，只替换 RGB 三字节
local function zone_packet(rgb, original)
  return string.char(original:byte(1), rgb:byte(1), rgb:byte(2), rgb:byte(3))
         .. original:sub(5)
end
```

⚠️ **不要凭空构造这 24 字节。** 必须先用 cmd27 / cmd29 读回原值当底稿，否则会破坏灯区的预设参数
（实测踩过：直接写入导致切换预设后灯区全黑）。

**证据等级**：无线路径的读 → 临时写 → 回读 → 恢复**已实测通过**；有线路径代码已对齐但未部署验证。
灯区**不受** cmd35 的 `mode` / `brightness` 控制，也不在 cmd51 的读数范围内。

---

## 6. 87 键硬件地址映射

87 个物理键对应 **0..108 内的稀疏地址**，不是连续 0..86。详见 [`KEY-MAPPING.md`](KEY-MAPPING.md) 与 [`data/f87s-calibration.json`](../data/f87s-calibration.json)。

关键值：`KeyW=34`、`ControlRight=87`、`Delete=106`、`PageDown=108`。

⚠️ **不要使用 F87 Pro 的列优先矩阵**（那套里 W=14）。F87S 是行优先，两者互不兼容，用错会点亮错误的键。

> 除这 87 个键外，还有两组**整区装饰灯**（旋钮星环 + 两侧灯条），走 cmd43/45，见 §5.5。
> 它们没有独立的硬件地址，不在 `f87s-calibration.json` 里，也**不能**按 87..127 的槽位推断。

---

## 7. 推荐执行流程

```text
1. 完全退出 AULA Hub（含托盘图标）与 SKYdimo，避免多写入者打架
2. 枚举 MI_03 打开 HID 句柄（有线 0x38A6:0x2908 / 无线 0x0C45:0xFEF9）
3. cmd16 读本体信息，校验是 38A6:2908
4. cmd19 读原模式 + cmd20 读原 512B 表 → 保存快照
   （要动装饰灯的话，再加 cmd27 / cmd29 各读 24 B 存快照）
5. 构造 128 槽表：所有槽 ID = 0..127，把 87 个逻辑颜色写到校准硬件地址
6. cmd36 串行发 10 包，逐包等 ACK
7. cmd35 写 mode=20 / brightness=5 提交
8. 可选：cmd43 / cmd45 写灯区颜色（**必须用快照原值当底稿**，见 §5.5）
9. 可选：cmd20 / cmd19 回读校验 + 目视确认
10. 结束时 cmd36 写回原表 → cmd35 写回原模式 → cmd43/45 写回原灯区 → 回读检查 → 关闭句柄
```

无线特有：**休眠会导致查询无回包**。先按实体键唤醒，必要时重插接收器，不要无限重试。

---

## 8. 性能实测

| 场景 | 结果 | 证据等级 |
|---|---|---|
| cmd36 全表 10 包 / 帧，逐包等 ACK | 有线 ≈ 15.9 FPS | 主机写入速率 |
| cmd36 全表，不等 ACK 直接连写 | 有线 ≈ 18.0 FPS | 主机写入速率 |
| **cmd36 变化分包 + last=0** | 有线 **30.31 FPS / 60.23 FPS，0 迟到帧**，87 键尾帧回读全部匹配 | ✅ 3 秒调度 + cmd51 尾帧回读 |
| 无线 cmd36 整表 + cmd35，逐包 ACK | 10 帧累计 1501 ms ≈ **6.66 FPS** | 主机发送耗时 |
| 无线 last=0 差分版 | 仅代码 + Lua mock 通过，**未实测** | ⚠️ |

> 上表除标注外都是**主机写入完成速率**，不是光学帧率，不证明每个中间帧都被灯珠显示。

---

## 9. ❌ 未走通的路径：0x08 实时通道（保持禁用）

官方驱动的 GIF 灯效 / 音乐律动走另一条独立通道：

```text
63 B 报告 = [0x08, 0x03, 0x00, total, index, chunkLen, ...payload@6, checksum@62]
每键 2 字节 RGB565；87 键 = 174 B = 4 包/帧
checksum: sum = 0x09 + packet[0..61]；packet[62] = (0xFF - sum) & 0xFF
发送: sendReport(9, packet)   —— 但 F87S 浏览器端没有 reportId 9 接口
```

**为什么禁用：**

- 旧探针曾测得 20 帧 / 156.7 ms（≈127 FPS），但那只是主机写完的速度；
- 2026-10-01 再次发送蓝色后，cmd51 输出仍为原色 → **未证明显示生效**；
- 在 SKYdimo 插件里切到 0x08 后灯效无法切换，已回退。

**推荐统一使用 §3.1 的 `cmd36 + last=0` 差分更新。**

---

## 10. 安全边界

1. **绝不发 cmd 79（SET_FLASH_DOWNLOAD）** 及任何校准 / 恢复出厂命令。
2. 同一接口**只允许单一串行写入者**。退出 AULA Hub（含托盘）后再操作。
3. 键盘无响应 → **拔插 USB 必恢复**。
4. 无回包时先排查休眠 / 并发写入，**禁止**用随机命令或随机 Report ID 扫描补救。
5. 每个写操作前保存快照；恢复失败必须明确上报，不能静默。
6. 快照回读一致 ≠ 实体灯珠恢复，最终以目视为准。

---

## 11. 适配层与参考实现

协议是语言无关的规范，下面是它的几种实现——**任选其一，互不依赖**：

| 适配层 | 文件 | 说明 |
|---|---|---|
| **命令行（推荐先试）** | `tools/aula-f87s-light.mjs` | 有线 CLI：set / single / rainbow / off / read |
| | `tools/f87s-wireless-control.mjs` | 无线 CLI：probe / set / single / off / demo / restore / selftest |
| **OpenRGB** | `adapters/openrgb/` | 原生 C++ 控制器（⚠️ 从未编译）。接入方式见 [`OPENRGB.md`](OPENRGB.md) |
| **SKYdimo** | `adapters/skydimo/controller.aula_f87s/` | Lua 插件（有线） |
| | `adapters/skydimo/controller.aula_f87s_wireless/` | Lua 插件（2.4G 无线） |
| **你自己的程序** | — | 照 §2 / §3 / §5 实现即可，约 50 行 |

**最短实现**（语言无关，仅首次同步；后续帧改用 §3.1 的 `last=0` 差分）：

```text
1. 打开 MI_03（有线 0x38A6:0x2908 / usagePage 0xFF68，无线 0x0C45:0xFEF9 / 0xFF60）
2. cmd36：512 B = 128 槽 × [slotId, R, G, B]，分 10 包，末包 lastFlag=1
3. cmd35：16 B，mode=20、brightness=5、结尾 0xAA 0x55
```

---

## 12. 最小可运行示例（Node.js）

复制粘贴即可跑，把整个键盘设成红色。**约 40 行，没有其他依赖。**

```js
import HID from 'node-hid';

const W = 56, CMD_CUSTOM = 36, CMD_EFFECT = 35;

// 1. 打开灯光口 MI_03；无线改 0x0C45 / 0xFEF9
const info = HID.devices().find(d =>
  d.vendorId === 0x38A6 && d.productId === 0x2908 && d.interface === 3);
const dev = new HID.HID(info.path);

// 2. 组包：node-hid 的 write() 首字节是 reportId，所以是 65 字节
function packet(cmd, chunk, addr, last) {
  const b = Buffer.alloc(65);
  b[1] = 0xAA; b[2] = cmd; b[3] = chunk.length;
  b[4] = addr & 255; b[5] = addr >> 8; b[7] = last ? 1 : 0;
  chunk.copy(b, 9);
  return b;
}

function send(cmd, data) {
  for (let a = 0; a < data.length; a += W) {
    const c = data.subarray(a, Math.min(a + W, data.length));
    dev.write(packet(cmd, c, a, a + c.length === data.length));
    dev.readTimeout(200);                       // 等 ACK 并排空
  }
}

// 3. cmd36：512 B = 128 槽 × [槽ID, R, G, B]，槽 ID 必须是下标
const table = Buffer.alloc(512);
for (let s = 0; s < 128; s++) {
  table[s * 4] = s;                             // ← 别漏，漏了会点不亮功能区
  table[s * 4 + 1] = 255;                       // 全红
}
send(CMD_CUSTOM, table);

// 4. cmd35：mode=20（custom）、brightness=5（量程 0–5！）、结尾 AA 55
const effect = Buffer.alloc(16);
effect[0] = 20; effect[9] = 5; effect[14] = 0xAA; effect[15] = 0x55;
send(CMD_EFFECT, effect);

dev.close();
```

想只点亮某一个键：把上面第 3 步改成「其余槽 RGB 全 0，只给目标槽上色」，
目标槽位查 [`KEY-MAPPING.md`](KEY-MAPPING.md)（例如 W=34、Delete=106）。

---

## 13. 完整报文示例（可直接对照抓包）

把 **W 键（槽位 34）设为绿色**，其余全黑。共 11 个包（cmd36 ×10 + cmd35 ×1），
每包 65 字节（首字节 reportId=0，其后 64 字节报告体）：

```text
cmd36 包 0   addr=0    len=56  last=0
00 AA 24 38 00 00 00 00 | 00 00 00 00 01 00 00 00 02 00 00 00 03 00 00 00
                          04 00 00 00 05 00 00 00 06 00 00 00 07 00 00 00
                          08 00 00 00 09 00 00 00 0A 00 00 00 0B 00 00 00
                          0C 00 00 00 0D 00 00 00
cmd36 包 1..8  仅 addr / len 变化（56 / 112 / ... / 448），payload 依此类推

cmd36 包 9   addr=504  len=8   last=1
00 AA 24 08 F8 01 00 01 00 | <最后 8 字节>

cmd35        addr=0    len=16  last=1
00 AA 23 10 00 00 00 01 00 | 14 FF FF FF FF 00 00 00 00 05 03 00 00 00 AA 55
                              ↑mode  ↑主色RGB ↑255   ↑secRGB ↑cMode ↑亮度 ↑速度
```

对照要点：

- `AA` 是发包头，`55` 是回包头，**不一样**；
- 第 4 字节（报告体偏移 2）是**本包长度**，不是总长度；
- 地址是 little-endian 字节偏移，504 = `F8 01`；
- `lastFlag` 在报告体偏移 6（65 字节包里的第 8 字节）；
- cmd35 那 16 字节里 `14`=mode20、`05`=亮度5、`AA 55`=结尾。

---

## 14. 跨平台注意事项

协议本身与操作系统无关，但**打开 HID 设备**的方式有平台差异：

| 平台 | 说明 |
|---|---|
| **Windows** | `node-hid` 开箱可用，**不需要管理员权限**。设备路径随 USB 口变化，按 VID/PID + interface + usagePage 枚举，不要硬编码 `\\?\HID#...` |
| **Linux** | 需要 `udev` 规则给普通用户 hidraw 权限，否则 `open` 会 EACCES：<br>`SUBSYSTEM=="hidraw", ATTRS{idVendor}=="38a6", ATTRS{idProduct}=="2908", MODE="0666"`<br>写入 `/etc/udev/rules.d/99-aula-f87s.rules` 后 `sudo udevadm control --reload-rules && sudo udevadm trigger` |
| **macOS** | `node-hid` 可用；系统可能把 vendor-defined 接口占用，若打不开先检查有没有其他程序持有 |

通用要点：

- **必须退出 AULA Hub（含托盘图标）**和任何正在写灯效的程序，否则串口被占 / 两边互相覆盖；
- 无线接收器的 VID/PID 和键盘本体**不同**（`0x0C45:0xFEF9` vs `0x38A6:0x2908`），这是正常的；
- 有线与无线同时接上时，两条路径都能写，**同一时刻只用一个**。

---

## 15. 免责声明

本项目是通过**黑盒 USB 通信观测**逆向得到的第三方文档，与 AULA / 狼蛛官方无任何关联，也未使用其任何专有代码。

按本文操作存在使键盘灯效异常的风险（拔插 USB 可恢复）。作者不对任何设备损坏负责。**请勿发送 §4.2 禁止列表中的命令。**
