# SKYdimo 插件：两个变体

同一套 HID 协议（[`docs/HID-PROTOCOL.md`](../../docs/HID-PROTOCOL.md)）的两个版本，
**选一个装**，不要同时装。

> ## ⚠️ 当前生效：`lowest-latency`（87 键纯键位）
>
> 用户目录 `%APPDATA%\com.skydimo.desktop\plugins\controller.aula_f87s_wireless\`
> 装的是 **`lowest-latency`**：18 × 6 / **87 采样点**，只有按键，无星环/侧灯。
>
> 换变体必须**手动、整目录替换**，不要只覆盖单个文件 ——
> 两个变体的 `lib/layout.lua` 采样点不同（87 vs 101），
> 混用会出现 UI 形态错乱或帧长校验失败。

| | [`lowest-latency/`](lowest-latency) | [`best-effects/`](best-effects) |
|---|---|---|
| **标签** | 🏃 **延迟最优**（✅ 当前生效） | 🎨 **效果最好** |
| 矩阵 | 18 × 6 / **87** 采样点 | 19 × 6 / **101** 采样点 |
| 覆盖范围 | 仅 87 个按键 | 87 键 **+ 旋钮星环 + 两侧灯条** |
| 每帧发的命令 | 仅 `cmd36` 变化分包（`last=0`，不等 ACK） | `cmd36` 差分 **+ `cmd43` + `cmd45`**（两次 `command_ack` 往返） |
| 装饰灯区 | **保留官方出厂预设**，插件不接管 | 接管，跟随灯效一起变 |
| 状态 | ✅ 作者日常在用 | ✅ 灯区读写实测通过；**真实帧率未实测** |

> **⚠️ 改插件时不要顺手换变体。** 2026-10-05 曾因为「两份目录版本漂移」
> 而把生效的 87 键版换成了 101 采样点版，导致 UI 凭空多出星环和侧灯 ——
> 修bug 和换UI 形态是两件独立的事。**发现版本不一致时，先问用户。**

---

## 延迟差在哪

差距来自装饰灯区。灯区命令（`cmd43` / `cmd45`）走的是 `command_ack` ——
**每包都要等设备回 ACK**（无线路径实测该往返在数百毫秒量级）。

```text
best-effects    每帧：cmd36 × n（快写）  →  cmd43（等 ACK）  →  cmd45（等 ACK）
lowest-latency  每帧：cmd36 × n（快写）
```

`lowest-latency` 每帧省掉两次 ACK 往返，所以响应更快、掉帧更少。
代价是装饰灯不跟着灯效走，保持出厂效果。

> ⚠️ **这个「延迟最优」是设计层面的推断**（每帧少两次 ACK 往返），
> **没有做过 A/B 光学实测**。如果你实测过，欢迎提 issue 补数据。

---

## 怎么选

- **当前生效、也是日常在用的** → **`lowest-latency`**（87 键纯键位，无星环侧灯）
- 想要**全身灯效同步**、用来做氛围/展示 → **`best-effects`**（会接管星环和侧灯）

换变体 = **整目录替换**（`main.lua` + `lib/` 全部），别只换 `layout.lua`。

---

## 安装

关闭 SKYdimo，把选中的**两个目录**复制到**用户插件目录**（这才是真正生效的那份）：

```bash
PLUGINS="$APPDATA/com.skydimo.desktop/plugins"     # 实际生效
# PLUGINS="C:/Program Files/Skydimo/plugins"      # 需管理员权限，且会被用户目录覆盖

# 延迟最优（当前生效）
cp -r adapters/skydimo/lowest-latency/controller.aula_f87s           "$PLUGINS/"
cp -r adapters/skydimo/lowest-latency/controller.aula_f87s_wireless  "$PLUGINS/"

# 或：效果最好
# cp -r adapters/skydimo/best-effects/controller.aula_f87s             "$PLUGINS/"
# cp -r adapters/skydimo/best-effects/controller.aula_f87s_wireless    "$PLUGINS/"
```

> ⚠️ **换变体前先删掉旧目录**：`rm -rf "$PLUGINS/controller.aula_f87s_wireless"`
> 再拷新的。直接覆盖可能残留上一个变体的 `lib/` 文件。

> ⚠️ **SKYdimo 优先加载用户目录** `%APPDATA%\Roaming\com.skydimo.desktop\plugins\`，
> 它会**覆盖** `C:/Program Files` 下的同名插件。改了 Program Files 没生效时，
> 先去用户目录里删掉旧副本（或同步到那里）。
> 日志里的 `duplicate controller plugin id; skipping` 就是这个机制在起作用，
> 详见 [`docs/SKYDIMO.md` §6.1](../../docs/SKYDIMO.md)。

两个变体的 plugin id 相同（`aula_f87s` / `aula_f87s_wireless`），
所以**同一时刻只能存在一个**，别两个目录都塞进去。

---

## 目录说明

```text
lowest-latency/
  controller.aula_f87s/            有线  0x38A6:0x2908
  controller.aula_f87s_wireless/   无线  0x0C45:0xFEF9
best-effects/
  controller.aula_f87s/            有线
  controller.aula_f87s_wireless/   无线
  tests/                           Lua mock（34 项，仅覆盖本变体）
```

`best-effects` 里的灯区是**整区单色**、不可逐灯珠控制 —— 物理原因是
旋钮只有半边有灯、侧灯在底壳外侧，见
[`docs/KEY-MAPPING.md` §5.2](../../docs/KEY-MAPPING.md#52-为什么是-19-列为什么星环只有-2-格)。

实现细节与踩坑 → [`docs/SKYDIMO.md`](../../docs/SKYDIMO.md)
