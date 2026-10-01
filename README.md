# AULA F87S — SKYdimo Plugins & Reverse-Engineered HID Protocol

Open-source SKYdimo controller plugins (wired + 2.4G wireless) and the reverse-engineered HID lighting protocol for the **AULA F87S 8K** (87-key TKL) keyboard.

狼蛛 AULA F87S 8K 的 **SKYdimo 插件（有线 + 2.4G 无线）** 与 **逆向 HID 灯光接口文档**。让这把被官方驱动独占的键盘，接入第三方灯效生态。

---

## 为什么需要这个项目

- 官方 AULA Hub 驱动**独占 HID 接口**，第三方程序连不上，且只支持自家灯效。
- 网上绝大多数开源 AULA 项目针对的是 **F87 Pro**（`0x258A:0x010C`，SinoWealth 平台），而 F87S 是 `0x38A6:0x2908` 的**全新 8K 平台**，VID 不同 → 直接扫不到设备。
- F87S 的键位映射也比 F87 Pro 多了偏移，**照抄会点亮错误的键**。

本项目把协议、键位、插件、工具全部实测打通并公开。

---

## 仓库结构

```text
docs/
  HID-PROTOCOL.md      ★ 逆向 HID 接口文档（有线 + 无线，含证据等级）
  SKYDIMO-PLUGIN.md    ★ 插件实现方法（生命周期、组包、6 个关键坑）
  KEY-MAPPING.md       ★ 87 键硬件 LED 地址映射
plugins/
  controller.aula_f87s/            有线插件  (0x38A6:0x2908)
  controller.aula_f87s_wireless/   无线插件  (0x0C45:0xFEF9)
tools/
  aula-f87s-light.mjs              有线 CLI（node-hid）
  f87s-wireless-control.mjs        无线 CLI（node-hid）
data/
  f87s-calibration.json            87 键校准映射（权威数据）
openrgb/
  OpenRGB C++ 控制器（⚠️ 从未编译，仅供参考）
```

---

## 快速开始

### 1. 命令行控灯（不装任何软件）

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

### 2. SKYdimo 插件

```bash
# 关闭 SKYdimo 后，以管理员权限复制（C:/Program Files 需要提权）
cp -r plugins/controller.aula_f87s           "C:/Program Files/Skydimo/plugins/"
cp -r plugins/controller.aula_f87s_wireless  "C:/Program Files/Skydimo/plugins/"
```

重启 SKYdimo，在设备档案里确认 `lastSeenControllerId` 为 `aula_f87s` / `aula_f87s_wireless`，然后在 UI 里选灯效。
完整步骤与排错见 [`docs/SKYDIMO-PLUGIN.md`](docs/SKYDIMO-PLUGIN.md)。

---

## 协议一句话总结

```
cmd36 写 128 槽 RGB888 表（512 B）→ cmd35 切 mode=20 / brightness=5 → 87 键立即显示自定义颜色
```

- 接口：MI_03，output report，`reportId=0`，64 B/包，8 B 头，载荷 56 B
- 分包：`Q = ceil(size/56)`，每包 `addr = i×56`，末包 `lastFlag=1`
- 回包头是 `0x55`（发出是 `0xAA`），按 `len` 截断，尾部是 padding
- 有线 `usagePage 0xFF68` / 无线 `0xFF60`，命令与键位表**完全一致**

**两个致命参数**：`mode` 必须是 **20**（其他值是板载动画）；`brightness` 量程是 **0–5**，填 255 会全黑。

完整内容 → [`docs/HID-PROTOCOL.md`](docs/HID-PROTOCOL.md)

---

## 实测状态（诚实清单）

| 项目 | 状态 |
|---|---|
| 有线协议逆向 + 点亮 | ✅ 实测 |
| 无线协议逆向 + 点亮 | ✅ 实测（全键设色 + Delete=106 单键） |
| 87 键硬件地址映射 | ✅ 由校准数据确定 |
| 有线差分更新 30/60 FPS | ✅ 3 秒调度 + 尾帧回读验证 |
| 无线 87 键逐键复测 | ⚠️ 仅确认 Delete，其余继承有线校准 |
| SKYdimo 内实际视觉效果 | ⚠️ 协议层通，需用户目视确认 |
| 无线 `last=0` 差分版帧率 | ⚠️ 代码 + Lua mock 通过，未实测 |
| `0x08` 实时通道 | ❌ 未证实显示生效，**已禁用** |
| 槽位 87–127（旋钮星环 / 侧灯） | ❌ 未接入（需 cmd43/45） |
| OpenRGB C++ 控制器 | ❌ 缺 Qt，**从未编译** |

---

## 安全警告

**绝对不要发送 `cmd 79`（SET_FLASH_DOWNLOAD）** 及任何校准 / 恢复出厂命令，可能损坏固件。

键盘无响应时**拔插 USB 必恢复**。操作前请完整阅读 [`docs/HID-PROTOCOL.md`](docs/HID-PROTOCOL.md) 的安全边界章节。

---

## 免责声明

本项目通过**黑盒 USB 通信观测**逆向得到，与 AULA / 狼蛛官方无任何关联，未使用其任何专有代码。
按本文档操作存在使键盘灯效异常的风险，作者不对任何设备损坏负责。

## 许可证

MIT — 见 [LICENSE](LICENSE)。
