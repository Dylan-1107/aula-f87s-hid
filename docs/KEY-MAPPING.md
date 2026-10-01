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

SKYdimo / 灯效软件给的是**连续逻辑索引 0..86**（行优先顺序），需要转成硬件地址再写进 128 槽表。
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

## 5. SKYdimo 18 × 6 矩阵 MAP

`add_output` 用 `matrix{width, height, map}`；`map` 是 **1 基 flat 数组**，值为 LED 逻辑索引，**`-1` = 空位**。

```lua
layout.WIDTH  = 18
layout.HEIGHT = 6
layout.MAP = {
   0, -1,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15, -1,
  16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, -1,
  33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, -1,
  50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, -1, 62, -1, -1, -1, -1,
  63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, -1, -1, 74, -1, 75, -1, -1,
  76, 77, 78, -1, -1, 79, -1, -1, 80, 81, 82, -1, -1, 83, 84, 85, 86, -1
}
```

> 若灯效在键盘上呈转置（横竖颠倒），**只交换 MAP 的 width/height 与坐标，绝对不要改 HARDWARE_IDS**——硬件地址是实测校准值。

## 6. 未覆盖区域

槽位 **87–127**（41 个）包含旋钮星环灯带与两侧装饰灯条，由 `cmd43` / `cmd45` 单独控制，**不在本项目范围内**，无线控制也尚未验证。
`cmd51` 不读这些槽位。不要凭「大于 87」推断它们的归属。
