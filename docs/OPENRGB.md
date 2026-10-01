# 用这份协议接入 OpenRGB（不需要 SKYdimo）

> **本仓库的主体是 [`HID-PROTOCOL.md`](HID-PROTOCOL.md) 描述的 HID 灯光协议，不是 SKYdimo。**
> SKYdimo 插件只是这套协议的**消费方之一**（一个 Lua 适配层）。同一份协议可以原样接进 OpenRGB、
> 你自己写的脚本、Home Assistant、游戏状态灯——SKYdimo 从头到尾都不是必需项。

本文讲三条 OpenRGB 接入路径，按「改造成本」从低到高排列。

---

## 0. 先搞清楚一件事：SKYdimo 和 OpenRGB 的关系

SKYdimo **自带** OpenRGB 作为后端（`OpenRGB.exe` + `hidapi.dll` + Qt5 DLL）。它的 Lua 插件机制本质上是
「OpenRGB 的 RGBController 换了一层 Lua 皮肤」。所以：

- SKYdimo 插件能做的事，原生 OpenRGB 控制器**都能做**；
- 反过来，原生 OpenRGB 控制器**不需要** SKYdimo 存在；
- 两者共用同一份 [`HID-PROTOCOL.md`](HID-PROTOCOL.md) 和同一份 [`KEY-MAPPING.md`](KEY-MAPPING.md)。

**协议 → 适配层** 的分工：

```text
docs/HID-PROTOCOL.md        ← 语言无关的协议规范（主体）
docs/KEY-MAPPING.md         ← 87 键硬件地址（主体）
        │
        ├── adapters/skydimo/    Lua 适配层（有线 + 无线插件）
        ├── adapters/openrgb/    C++ 适配层（原生 OpenRGB 控制器）
        ├── tools/               Node.js 适配层（独立 CLI，不依赖任何灯效软件）
        └── 你的程序              任何能发 64 字节 HID output report 的语言
```

---

## 1. 路径 A：原生 OpenRGB 控制器（正统做法）

把 [`adapters/openrgb/`](../adapters/openrgb) 的 C++ 文件编进 OpenRGB，F87S 就会像其他设备一样出现在
OpenRGB 设备列表里，享受全部内置灯效。

### 1.1 为什么需要它

OpenRGB 官方**不支持** `0x38A6:0x2908`（只支持 SinoWealth F87 Pro `0x258A:0x010C`）。
F87S 是全新的 8K 平台，VID 不同 → 检测不到。

### 1.2 构建

```bash
# 1. 装 Qt5/Qt6（MSVC 版，含 QtWidgets）
# 2. 拿 OpenRGB 源码
git clone https://gitlab.com/CalcProgrammer1/OpenRGB.git
cd OpenRGB

# 3. 放控制器
mkdir -p Controllers/AulaF87SController
cp <本仓库>/adapters/openrgb/*.h adapters/openrgb/*.cpp Controllers/AulaF87SController/

# 4. 注册检测函数
#    在 Controllers/RGBControllerDetector.cpp 中加入：
#      #include "AulaF87SControllerDetect.cpp"
#      DetectAulaF87SControllers(existing_controllers);

# 5. 构建（Windows: 用 Qt Creator 打开 OpenRGB.pro；Linux: qmake && make）
```

### 1.3 控制器已实现的接口

| 成员 | 实现 |
|---|---|
| 设备检测 | `0x38A6:0x2908`，`hid_open()` 后按 usagePage 定位 MI_03 |
| `DeviceUpdateLEDs()` | `cmd36` 写 128 槽 RGB888 表 + `cmd35` 切 `mode=20 / brightness=5` |
| Feature report | **无**（F87S 不存在，不要照抄其他型号的 `sendFeatureReport`） |
| `cmd66` 灯光口 | **无**（那是别的型号 / 2.4G，F87S 有线没有） |

### 1.4 ⚠️ 当前状态：从未编译过

本机缺 Qt 与 OpenRGB 源码树，这份代码只做到「逻辑按实测协议写完」，**一次都没编译成功过**。
预计需要调整的地方：

- OpenRGB 的 `RGBController` / `hidapi` API 签名随版本变化，可能需要微调；
- 文件**顶部的 TODO 注释已过时**（写着"cmd66 帧头待抓包""custom mode 待确认"），
  **以代码正文和 [`HID-PROTOCOL.md`](HID-PROTOCOL.md) 为准**。

欢迎提 PR 把它跑起来——这是让 F87S 进 OpenRGB 主线的唯一路径。

---

## 2. 路径 B：OpenRGB SDK 桥接（免编译 OpenRGB）

如果你不想编译 OpenRGB，可以走网络 SDK：程序连到 OpenRGB 的 SDK server，
把 OpenRGB 里**某个已支持设备**的颜色镜像到 F87S。

### 2.1 ⚠️ 先理解方向，别搞反

OpenRGB SDK 的设计是「客户端 → 控制 → OpenRGB 的设备」：

| 命令 | 值 | 方向 | 含义 |
|---|---:|---|---|
| `REQUEST_CONTROLLER_COUNT` | 0 | client → server | 取设备数量 |
| `REQUEST_CONTROLLER_DATA` | 1 | client → server | 取设备描述（**含当前颜色**） |
| `REQUEST_PROTOCOL_VERSION` | 40 | client → server | 协商协议版本 |
| `SET_CLIENT_NAME` | 50 | client → server | 注册客户端名 |
| `DEVICE_LIST_UPDATED` | 100 | **server → client** | 设备列表变化通知 |
| `RGBCONTROLLER_UPDATELEDS` | 1050 | client → server | **给设备设色** |
| `RGBCONTROLLER_SETCUSTOMMODE` | 1100 | client → server | 切自定义模式 |

**SDK 不会主动向客户端推送颜色变化。** 要读取颜色，只能轮询 `REQUEST_CONTROLLER_DATA`。

这带来一个限制：

- ✅ **可行**：读 OpenRGB 中已有设备（显卡、主板、内存、灯带……）的颜色 → 转发给 F87S
  → F87S 变成「跟随灯」。
- ❌ **不可行**：让 F87S 凭空出现在 OpenRGB 设备列表里——那必须有原生控制器（路径 A）。

### 2.2 协议格式

```text
端口: 6742 ("ORGB" 在电话键盘上)
包头 16 字节:
  char[4]  magic   = "ORGB"
  uint32   dev_idx   设备索引（非设备相关命令填 0）
  uint32   pkt_id    命令 ID
  uint32   pkt_size  后续数据字节数
字符串编码: uint16 长度 + 该长度的字节（ASCII/UTF-8）
```

### 2.3 桥接骨架（Python）

用成熟库解析，别自己拆包：

```bash
pip install openrgb-python hidapi
```

```python
import time
from openrgb import OpenRGBClient
import hid

HW = [...]          # 87 项，见 data/f87s-calibration.json 的行优先顺序
VID, PID, IFACE = 0x38A6, 0x2908, 3     # 无线改 0x0C45 / 0xFEF9

def write_frame(colors_rgb):
    """colors_rgb: 87 个 (r,g,b) → cmd36 写表 + cmd35 提交（首次同步）"""
    table = bytearray(512)
    for s in range(128):
        table[s*4] = s
    for i, (r, g, b) in enumerate(colors_rgb):
        o = HW[i]*4
        table[o+1], table[o+2], table[o+3] = r, g, b
    dev = hid.device(); dev.open(VID, PID)          # 简化示例，未做 interface 选择
    for i in range(0, 512, 56):
        chunk = table[i:i+56]
        body = bytes([0xAA, 36, len(chunk), i & 255, i >> 8, 0,
                      1 if i + len(chunk) >= 512 else 0, 0]) + chunk
        dev.write(b'\x00' + body + b'\x00' * (56 - len(chunk)))
    # cmd35: mode=20, brightness=5
    eff = bytearray(16); eff[0] = 20; eff[9] = 5; eff[14] = 0xAA; eff[15] = 0x55
    body = bytes([0xAA, 35, 16, 0, 0, 0, 1, 0]) + eff
    dev.write(b'\x00' + body + b'\x00' * 40)
    dev.close()

cli = OpenRGBClient()
target = cli.get_devices_by_name("你的跟随源设备名")[0]
while True:
    write_frame([(c.red, c.green, c.blue) for c in target.colors[:87]])
    time.sleep(1 / 30)
```

> ⚠️ 上面是**骨架，不是成品**：`hid.device()` 没做 interface/usagePage 选择（必须限定 MI_03），
> 也没做快照与恢复。生产实现请照抄 [`tools/aula-f87s-light.mjs`](../tools/aula-f87s-light.mjs) 的完整逻辑。
> 本仓库**未提供**经过测试的桥接脚本——有需要欢迎 PR。

---

## 3. 路径 C：直接用协议，不碰任何灯效软件

最小可用实现只有三件事，任何能发 64 字节 HID output report 的语言都行：

```text
1. 打开 MI_03（有线 0x38A6:0x2908 / usagePage 0xFF68，无线 0x0C45:0xFEF9 / 0xFF60）
2. cmd36 写 512 B = 128 槽 × [slotId, R, G, B]，分 10 包，末包 lastFlag=1
3. cmd35 写 16 B：mode=20, brightness=5, 结尾 0xAA 0x55
```

伪代码（语言无关）：

```text
W = 56
for i in 0 .. ceil(size/56) - 1:
    addr = i * W
    len  = min(W, size - addr)
    body = [0xAA, cmd, len, addr & 0xFF, addr >> 8, 0, (i == last) ? 1 : 0, 0] + data[addr : addr+len]
    write(reportId=0, body padded to 64 bytes)     # node-hid 需前置 1 字节 reportId
```

完整规范、分包地址表、ACK 校验、安全边界 → [`HID-PROTOCOL.md`](HID-PROTOCOL.md)。

---

## 4. 三条路径对比

| | 路径 A 原生控制器 | 路径 B SDK 桥接 | 路径 C 自己写 |
|---|---|---|---|
| F87S 出现在 OpenRGB 设备列表 | ✅ | ❌ | ❌ |
| 用 OpenRGB 全部内置灯效 | ✅ | ❌（只能跟随别人的颜色） | ❌ |
| 需要编译 | ✅ 需要 Qt + OpenRGB 源码 | ❌ | ❌ |
| 需要 SKYdimo | ❌ | ❌ | ❌ |
| 本机已验证 | ❌ 从未编译 | ❌ 未提供成品 | ✅ CLI 已实测 |

---

## 5. 要不要先做哪个

- 想让 F87S 真正成为 OpenRGB 一等公民 → **路径 A**（需要有人把它编译一遍，欢迎 PR）。
- 只想让键盘跟着整机灯效走 → **路径 B**。
- 只想自己控灯、不装任何软件 → **路径 C**（`tools/` 下两个 CLI 开箱即用）。
