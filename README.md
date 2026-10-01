# AULA F87S — Reverse-Engineered HID Lighting Protocol

逆向得到的 **狼蛛 AULA F87S 8K（87 键 TKL）灯光 HID 协议**，以及基于它的几个适配层实现。

> ### 本仓库的主体是协议，不是某个软件
>
> [`docs/HID-PROTOCOL.md`](docs/HID-PROTOCOL.md) 描述的是**键盘本身的 HID 接口**——
> 它先于、也独立于任何灯效软件存在。SKYdimo 插件只是它的 Lua 适配层；
> **同一份协议可以原样接进 OpenRGB、自写脚本、Home Assistant、游戏状态灯，全程不需要 SKYdimo。**
>
> ```text
> docs/HID-PROTOCOL.md   ← 主体：语言无关的协议规范（有线 + 2.4G 无线）
> docs/KEY-MAPPING.md    ← 主体：87 键硬件 LED 地址
>        ├── adapters/skydimo/   Lua 适配层（可选）
>        ├── adapters/openrgb/   C++ 适配层（可选）
>        └── tools/              Node.js CLI（不装任何灯效软件，开箱即用）
> ```

---

## 协议一句话总结

```text
cmd36 写 128 槽 RGB888 表（512 B）→ cmd35 切 mode=20 / brightness=5 → 87 键立即显示自定义颜色
```

| 项目 | 有线 | 2.4G 无线 |
|---|---|---|
| VID : PID | `0x38A6 : 0x2908` | `0x0C45 : 0xFEF9`（接收器） |
| 灯光口 | MI_03 / `0xFF68:0x61` | MI_03 / `0xFF60:0x61` |
| 报告 | output report，`reportId=0`，64 B/包，8 B 头，载荷 56 B | 同左 |
| 命令与键位表 | **完全一致** | **完全一致** |

**两个致命参数**：`mode` 必须是 **20**（其他值是板载动画）；`brightness` 量程是 **0–5**，填 255 会全黑。

除 87 键逐键外，还有两组**整区单色**装饰灯（旋钮星环 + 两侧灯条），走 `cmd43` / `cmd45`（24 B 参数块，必须以读回的原值当底稿）。

完整规范 → [`docs/HID-PROTOCOL.md`](docs/HID-PROTOCOL.md)

---

## 为什么需要这个项目

- 官方 AULA Hub 驱动**独占 HID 接口**，第三方程序连不上，且只支持自家灯效。
- 网上绝大多数开源 AULA 项目针对的是 **F87 Pro**（`0x258A:0x010C`，SinoWealth 平台），
  而 F87S 是 `0x38A6:0x2908` 的**全新 8K 平台**，VID 不同 → 直接扫不到设备。
- F87S 键位映射与 F87 Pro 不兼容（W 在旧表里是 14，实际是 **34**），**照抄会点亮错误的键**。

本项目把协议、键位逐字节逆向并实测打通，公开给所有灯效生态使用。

---

## 三种用法，任选其一

### 1. 命令行直接控灯（不装任何灯效软件）

```bash
npm i node-hid

# 有线
node tools/aula-f87s-light.mjs set 255 0 0        # 全键盘红
node tools/aula-f87s-light.mjs rainbow            # 彩虹渐变
node tools/aula-f87s-light.mjs off                # 熄灭

# 2.4G 无线
node tools/f87s-wireless-control.mjs probe                  # 读设备信息
node tools/f87s-wireless-control.mjs single Delete 0 0 160  # 只点亮 Delete
node tools/f87s-wireless-control.mjs selftest               # 离线自检，不碰硬件
```

> **前置：必须完全退出 AULA Hub（含托盘图标）**，否则它持续回写灯效。

### 2. 接 OpenRGB（不需要 SKYdimo）

三条路径，从「改 OpenRGB 源码」到「自己写 50 行」都有，
详见 [`docs/OPENRGB.md`](docs/OPENRGB.md)。

### 3. 接 SKYdimo（可选）

```bash
# 关闭 SKYdimo 后，以管理员权限复制（C:/Program Files 需要提权）
cp -r adapters/skydimo/controller.aula_f87s           "C:/Program Files/Skydimo/plugins/"
cp -r adapters/skydimo/controller.aula_f87s_wireless  "C:/Program Files/Skydimo/plugins/"
```

重启后确认设备档案里 `lastSeenControllerId` 为 `aula_f87s` / `aula_f87s_wireless`。

> ⚠️ 改了 `C:/Program Files` 却没生效？SKYdimo **优先加载用户目录**
> `%APPDATA%\Roaming\com.skydimo.desktop\plugins\` 下的同名插件，它会覆盖 Program Files 版本。

完整步骤与排错 → [`docs/SKYDIMO.md`](docs/SKYDIMO.md)。

---

## 仓库结构

```text
docs/
  HID-PROTOCOL.md      ★ 主体：逆向 HID 接口文档（有线 + 无线，含证据等级）
  KEY-MAPPING.md       ★ 主体：87 键硬件 LED 地址映射
  OPENRGB.md             接入 OpenRGB 的三条路径（均不需要 SKYdimo）
  SKYDIMO.md             SKYdimo 插件实现方法（适配层文档）
adapters/
  skydimo/               有线 + 无线 Lua 插件（19×6 / 101 点统一矩阵）
    tests/               离线 Lua mock 测试（34 项，不接硬件）
  openrgb/               OpenRGB 原生 C++ 控制器（⚠️ 从未编译）
tools/
  aula-f87s-light.mjs        有线 CLI（node-hid）
  f87s-wireless-control.mjs  无线 CLI（node-hid）
data/
  f87s-calibration.json      87 键校准映射（权威数据）
```

---

## 实测状态（诚实清单）

| 项目 | 状态 |
|---|---|
| 有线协议逆向 + 点亮 | ✅ 实测 |
| 无线协议逆向 + 点亮 | ✅ 实测（全键设色 + Delete=106 单键） |
| 87 键硬件地址映射 | ✅ 由校准数据确定 |
| 有线差分更新 30/60 FPS | ✅ 3 秒调度 + 尾帧回读验证 |
| **装饰灯区（星环 + 侧灯，cmd43/45）** | ✅ 无线读/写/回读/恢复实测通过；有线代码已对齐未实测 |
| SKYdimo 统一 19×6 / 101 点矩阵 | ✅ 无线已确认单输出 + 紧凑矩阵；有线渲染待目视 |
| 插件离线 mock 测试 | ✅ **34 项断言全部通过**（不接硬件） |
| 无线 87 键逐键复测 | ⚠️ 仅确认 Delete，其余继承有线校准 |
| 无线 `last=0` 差分版帧率 | ⚠️ mock 只验证包序列，真实帧率未实测 |
| `0x08` 实时通道 | ❌ 未证实显示生效，**已禁用** |
| 灯区逐灯珠可控 | ❌ 硬件上是**整区单色**，采样点只是 UI 虚拟格 |
| OpenRGB C++ 控制器 | ❌ 缺 Qt，**从未编译** |

---

## 安全警告

**绝对不要发送 `cmd 79`（SET_FLASH_DOWNLOAD）** 及任何校准 / 恢复出厂命令，可能损坏固件。

键盘无响应时**拔插 USB 必恢复**。操作前请完整阅读
[`docs/HID-PROTOCOL.md`](docs/HID-PROTOCOL.md) 的安全边界章节。

---

## 免责声明

本项目通过**黑盒 USB 通信观测**逆向得到，与 AULA / 狼蛛官方无任何关联，未使用其任何专有代码。
按本文档操作存在使键盘灯效异常的风险，作者不对任何设备损坏负责。

## 许可证

MIT — 见 [LICENSE](LICENSE)。
