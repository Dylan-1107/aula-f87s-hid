# AULA F87S — 87 键硬件 LED 地址映射

> 权威数据文件：[`data/f87s-calibration.json`](../data/f87s-calibration.json)
> 该映射同时用于有线 `0x38A6:0x2908` 与 2.4G 无线 `0x0C45:0xFEF9`。

## 1. ⚠️ 先读：两套互斥的键位表

| 版本 | 编码方式 | 代表值 | 状态 |
|---|---|---|---|
| **行优先（本文）** | 物理行扫描顺序 | Esc=0、Backquote=16、Tab=32、**KeyW=34** | ✅ **唯一正确** |
| 列优先（F87 Pro 矩阵） | `ledId = row + 6 × col` | **KeyW=14** | ❌ 不适用 F87S，会点亮错误的键 |

网上多数 AULA F87 **Pro** 开源项目用的是列优先矩阵。**不要直接照抄**。

## 2. 完整映射表

| 键区 | 按键 → 硬件槽位 |
|---|---|
| **功能行** | Escape=0 · F1–F12=1–12 · PrintScreen=99 · ScrollLock=100 · Pause=102 |
| **数字行** | Backquote=16 · Digit1–Digit9=17–25 · Digit0=26 · Minus=27 · Equal=28 · Backspace=92 |
| **数字行导航** | Insert=103 · Home=104 · PageUp=105 |
| **QWERTY 行** | Tab=32 · Q=33 · W=34 · E=35 · R=36 · T=37 · Y=38 · U=39 · I=40 · O=41 · P=42 · BracketLeft=43 · BracketRight=44 · Backslash=60 |
| **QWERTY 导航** | Delete=106 · End=107 · PageDown=108 |
| **Home 行** | CapsLock=48 · A=49 · S=50 · D=51 · F=52 · G=53 · H=54 · J=55 · K=56 · L=57 · Semicolon=58 · Quote=59 · Enter=76 |
| **Shift 行** | ShiftLeft=64 · Z=65 · X=66 · C=67 · V=68 · B=69 · N=70 · M=71 · Comma=72 · Period=73 · Slash=74 · ShiftRight=75 · ArrowUp=90 |
| **Ctrl 行** | ControlLeft=80 · MetaLeft=81 · AltLeft=82 · Space=83 · AltRight=84 · Fn=85 · ContextMenu=86 · ControlRight=87 · ArrowLeft=88 · ArrowDown=89 · ArrowRight=91 |

**分布规律**（行优先扫描）：F 行 16 → 数字行 17 → QWERTY 17 → Home 13 → Shift 13 → Ctrl 11 = **87**。
功能区与导航区是**离散高位地址**（90–108），不是连续的。

## 3. 逐键对照（87 项）

| 键 | id | 键 | id | 键 | id |
|---|---:|---|---:|---|---:|
| Escape | 0 | F1 | 1 | F2 | 2 |
| F3 | 3 | F4 | 4 | F5 | 5 |
| F6 | 6 | F7 | 7 | F8 | 8 |
| F9 | 9 | F10 | 10 | F11 | 11 |
| F12 | 12 | PrintScreen | 99 | ScrollLock | 100 |
| Pause | 102 | Backquote | 16 | Digit1 | 17 |
| Digit2 | 18 | Digit3 | 19 | Digit4 | 20 |
| Digit5 | 21 | Digit6 | 22 | Digit7 | 23 |
| Digit8 | 24 | Digit9 | 25 | Digit0 | 26 |
| Minus | 27 | Equal | 28 | Backspace | 92 |
| Insert | 103 | Home | 104 | PageUp | 105 |
| Tab | 32 | KeyQ | 33 | KeyW | 34 |
| KeyE | 35 | KeyR | 36 | KeyT | 37 |
| KeyY | 38 | KeyU | 39 | KeyI | 40 |
| KeyO | 41 | KeyP | 42 | BracketLeft | 43 |
| BracketRight | 44 | Backslash | 60 | Delete | 106 |
| End | 107 | PageDown | 108 | CapsLock | 48 |
| KeyA | 49 | KeyS | 50 | KeyD | 51 |
| KeyF | 52 | KeyG | 53 | KeyH | 54 |
| KeyJ | 55 | KeyK | 56 | KeyL | 57 |
| Semicolon | 58 | Quote | 59 | Enter | 76 |
| ShiftLeft | 64 | KeyZ | 65 | KeyX | 66 |
| KeyC | 67 | KeyV | 68 | KeyB | 69 |
| KeyN | 70 | KeyM | 71 | Comma | 72 |
| Period | 73 | Slash | 74 | ShiftRight | 75 |
| ArrowUp | 90 | ControlLeft | 80 | MetaLeft | 81 |
| AltLeft | 82 | Space | 83 | AltRight | 84 |
| Fn | 85 | ContextMenu | 86 | ControlRight | 87 |
| ArrowLeft | 88 | ArrowDown | 89 | ArrowRight | 91 |

## 4. 逻辑索引 ↔ 硬件地址

87 个按键的**连续逻辑索引 0..86**（行优先顺序），需要转成硬件地址再写进 128 槽表。
（101 点矩阵里的 87..100 是灯区虚拟采样点，不参与这个转换，见 §5。）

`HARDWARE_IDS` 数组（下标 = 逻辑索引，值 = 硬件槽位），已内置在两个插件的 `lib/layout.lua`：

```lua
layout.HARDWARE_IDS = {
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 99, 100, 102,
  16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 92, 103, 104,
  105, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 60, 106,
  107, 108, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 76, 64,
  65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 90, 80, 81, 82, 83,
  84, 85, 86, 87, 88, 89, 91
}
```

这个顺序同时就是**官方驱动 JSON 导入格式**要求的 87 项顺序：

```json
{ "name": "配置名", "speed": 50, "data": ["rgb(0, 0, 0)", "... 恰好 87 项 ..."] }
```

## 5. SKYdimo 矩阵：19 × 6 / 101 采样点

两个插件（有线 + 无线）都注册**单个** `keys` 输出，网格 **19 × 6**，共 **101 个采样点**：

| 采样点 | 数量 | 逻辑索引 | 说明 |
|---|---:|---|---|
| 校准按键 | 87 | 0..86 | 走 `HARDWARE_IDS` → `cmd36` 逐键 |
| 旋钮星环 | 2 | 87..88 | 方向键旁上下两格，**平均成 1 个整区色** → `cmd43` |
| 左侧灯条 | 6 | 89..94 | 第 0 列，**平均成 1 个整区色** → `cmd45` |
| 右侧灯条 | 6 | 95..100 | 最右列，**平均成 1 个整区色** → `cmd45` |

网格布局：第 1 列 = 左侧灯条，第 2..19 列 = 87 键，最右列 = 右侧灯条，
方向键旁两格 = 星环。MAP 由 `lib/layout.lua` 程序化生成（先铺 18×6 键区，
再插入灯区采样点），直接读源码更可靠。

### 5.1 虚拟采样点 → 整区颜色

灯区采样点在 UI 里看起来是很多格，但**硬件上不能逐格寻址**。
`layout.split_frame(rgb)` 负责把 101 点拆成三段：

```lua
function layout.split_frame(rgb)
  -- 返回：87 键 RGB 串、星环平均色(3B)、侧灯平均色(3B)
  return rgb:sub(1, 87 * 3), average(rgb, 87, 88), average(rgb, 89, 100)
end
```

平均色再交给 `cmd43` / `cmd45` 写整区。**不要声称灯区可逐灯珠控制。**

### 5.2 为什么是 19 列，为什么星环只有 2 格

这两处看起来「不像键盘」的设计，都是从实机结构来的，**不是随手画的**：

| 设计 | 物理原因 |
|---|---|
| 侧灯条放在**最外侧两列**（列 0 / 列 18） | 灯珠不在按键区域里，而是**键盘底壳两侧边缘的导光条**，物理上就在键区之外 |
| 星环只有 **2 个采样点** | 右下角旋钮的灯**只有半边有灯珠**，不是一整圈。用 2 格表示这半圈，而不是画成一个完整圆环 |

所以矩阵的边界不是「键盘外壳的边界」，而是「**灯光可寻址区域的边界**」。

> 左右两条侧灯在硬件上是**一起**控制的（`cmd45` 一个整区色）；
> 12 个采样点只是让 UI 上看起来像两条独立灯条。

> 若灯效在键盘上呈转置（横竖颠倒），**只交换 MAP 的 width/height 与坐标，绝对不要改 HARDWARE_IDS**——硬件地址是实测校准值。

## 6. 装饰灯区（星环 / 侧灯）

F87S 除 87 键外还有两组装饰灯，协议见 [`HID-PROTOCOL.md` §5.5](HID-PROTOCOL.md#55-cmd27--cmd29--cmd43--cmd45--灯区参数24-b)：

| 灯区 | 读 | 写 | 载荷 | 可寻址性 |
|---|---:|---:|---|---|
| 旋钮星环 | cmd27 | cmd43 | 24 B | **整区单色** |
| 两侧灯条 | cmd29 | cmd45 | 24 B | **整区单色**（左右一起） |

要点：

- 它们**没有** 0..127 槽位里的硬件地址，不在 `f87s-calibration.json` 中；
- **不要**凭「槽位大于 87」去推断它们的归属——128 槽表里那些槽位是固件内部用途；
- 24 B 参数块必须**以 cmd27/cmd29 读回的原值当底稿**，只替换 RGB 三字节，否则会破坏预设参数（实测会导致切预设后灯区全黑）；
- 灯区**不受** `cmd35` 的 `mode` / `brightness` 控制，也不在 `cmd51` 读数范围内。

**证据等级**：无线路径读 → 写 → 回读 → 恢复已实测通过；有线代码已对齐但未部署验证。
