# 键位校准：把这套协议复刻到你的键盘上

> **这是复刻过程中唯一不能照抄的部分。**
> 协议、命令、分包规则可以复用，但**键位 → 硬件槽位的映射每台设备都可能不同**。
> 想让别人（或三个月后的你）拿到一把别的 AULA 键盘也能点亮，就得自己过一遍校准。

---

## 1. 为什么必须校准

`cmd36` 那张 512 B 表里，第 `s` 槽控制**哪个物理键**由键盘固件决定，
不是按「键在键盘上的位置」排的。实测证据：

| 键盘 | W 键的槽位 |
|---|---|
| AULA F87 **Pro**（网上多数开源项目用列优先矩阵） | 14 |
| AULA **F87S**（本项目） | **34** |

照抄 F87 Pro 的矩阵会点亮错的键。F87S 的 87 个键落在 **0..108 的稀疏地址**上
（比如 Delete=106、PageDown=108），功能区/导航区是离散高位地址，不是连续的。

即便是同一型号，**不同固件版本**也可能改映射。所以拿到键盘先校准，别信任何现成表。

---

## 2. 校准在做什么

原理只有一句话：**点亮一个槽位，看哪个键亮，记下来。**

```text
for slot in 0..127:
    写 128 槽表，只把第 slot 槽设成白色，其余全黑
    cmd36 发送 → cmd35 提交
    人眼看：哪个物理键亮了？ → 记 mapping[键名] = slot
```

87 个键逐个做一遍，就得到完整的 `键名 → 槽位` 表。

---

## 3. 方法一：可视化校准器（推荐）

仓库自带一个网页校准器：`tools/calibrator/`，左边是键盘图，点一个键、
点亮一个槽位、确认，逐个分配完直接导出 `layout.lua`。

```bash
cd tools/calibrator
npm i node-hid
node calibrator-server.mjs
# 浏览器打开 http://127.0.0.1:8765
```

**使用前**：完全退出 AULA Hub（含托盘图标）和 SKYdimo，否则它们会持续回写灯效。

### HTTP 接口

| 方法 | 端点 | 作用 |
|---|---|---|
| GET | `/api/status` | 设备连接状态 |
| POST | `/api/connect` | 连接 MI_03 |
| POST | `/api/light` | 点亮指定槽位 |
| POST | `/api/off` | 熄灭 |
| POST | `/api/assign` | 把槽位分配给当前键 |
| POST | `/api/unassign` | 取消分配 |
| POST | `/api/reset` | 重置映射 |
| POST | `/api/apply` | 生成并写入 `layout.lua`（写入前自动备份 `.before-calibration.bak`） |
| POST | `/api/close` | 关闭设备 |

### 环境变量（适配其他型号）

| 变量 | 默认 | 说明 |
|---|---|---|
| `F87S_VID` | `0x38A6` | 键盘 VID（十进制或 `0x` 十六进制） |
| `F87S_PID` | `0x2908` | 键盘 PID |
| `F87S_INTERFACE` | `3` | 灯光口 interface（通常是 MI_03） |
| `F87S_CALIBRATOR_PORT` | `8765` | 服务端口 |
| `F87S_PLUGIN_LAYOUT` | `./layout.lua` | `/api/apply` 写出的布局文件路径 |

> 无线模式：`F87S_VID=0x0C45 F87S_PID=0xFEF9`（接收器），映射与有线相同。

---

## 4. 方法二：手动扫描

不想开网页的话，循环点亮 + 自己记录也行：

```js
import HID from 'node-hid';
const W = 56, CMD_CUSTOM = 36, CMD_EFFECT = 35;

const dev = new HID.HID(HID.devices().find(d =>
  d.vendorId === 0x38A6 && d.productId === 0x2908 && d.interface === 3).path);

function packet(cmd, chunk, addr, last) {
  const b = Buffer.alloc(65);                 // node-hid: 首字节 reportId
  b[1] = 0xAA; b[2] = cmd; b[3] = chunk.length;
  b[4] = addr & 255; b[5] = addr >> 8; b[7] = last ? 1 : 0;
  chunk.copy(b, 9);
  return b;
}

function send(cmd, data) {
  for (let a = 0; a < data.length; a += W) {
    const c = data.subarray(a, Math.min(a + W, data.length));
    dev.write(packet(cmd, c, a, a + c.length === data.length));
    dev.readTimeout(200);                     // 排空 ACK
  }
}

function lightSlot(slot) {
  const t = Buffer.alloc(512);
  for (let s = 0; s < 128; s++) t[s * 4] = s;      // 槽 ID 必须是下标
  t[slot * 4 + 1] = 255; t[slot * 4 + 2] = 255; t[slot * 4 + 3] = 255;
  send(CMD_CUSTOM, t);
  const e = Buffer.alloc(16);
  e[0] = 20; e[9] = 5; e[14] = 0xAA; e[15] = 0x55;  // mode=20, brightness=5
  send(CMD_EFFECT, e);
}

for (let slot = 0; slot < 128; slot++) {
  lightSlot(slot);
  console.log('slot', slot, '—— 哪个键亮了？');
  await new Promise(r => setTimeout(r, 1500));      // 留时间看
}
```

**注意**：`mode` 必须是 20、`brightness` 必须是 5（量程 0–5），否则全黑。详见
[`HID-PROTOCOL.md`](HID-PROTOCOL.md)。

---

## 5. 输出格式

校准结果保存到 `calibration.json`：

```json
{
  "version": 1,
  "device": "AULA F87S",
  "vid": "0x38A6",
  "pid": "0x2908",
  "interface": 3,
  "updatedAt": "2026-09-29T21:37:32.437Z",
  "mapping": {
    "Escape": 0, "F1": 1, "KeyW": 34, "Delete": 106
  }
}
```

本项目的权威结果在 [`data/f87s-calibration.json`](../data/f87s-calibration.json)。

---

## 6. 从校准表到插件布局

插件需要的是 `HARDWARE_IDS`：**按下标 = 灯效软件给的逻辑索引，值 = 硬件槽位**。
逻辑索引的顺序由你的矩阵决定（本项目是**行优先**：F 行 16 → 数字行 17 →
QWERTY 17 → Home 13 → Shift 13 → Ctrl 11 = 87）。

```js
// 行优先的 87 个键名 → 依次取硬件槽位
const order = ["Escape","F1","F2",...,"ArrowRight"];   // 87 项
const ids = order.map(name => mapping[name]);          // → HARDWARE_IDS
```

这个顺序同时也是**官方驱动 JSON 导入格式**要求的 87 项顺序
（`{"name":"...","speed":50,"data":["rgb(0, 0, 0)", ...]}`）。

---

## 7. 校准完必须验证

别校准完就当完事，跑一遍反向验证：

1. **逐个点亮**：按校准表把 87 个键各点一次，确认每次亮的是对应键；
2. **彩虹全亮**：`node tools/aula-f87s-light.mjs rainbow`，看有没有键不亮或错位；
3. **边界键**：重点看功能区（PrintScreen/ScrollLock/Pause）、导航区（Insert/Home/PgUp/Delete/End/PgDn）、
   Enter、右 Shift/右 Ctrl —— 这些是离散高位地址，最容易错。

> 如果只写 87 个槽而让后 41 槽留空，会破坏已校准的槽 ID 字节，
> 表现为功能区 / 右 Ctrl / Enter 不亮。**必须填满全部 128 槽。**

---

## 8. 复刻到其他 AULA 型号的路线

1. 用 Windows 设备管理器或 `HID.devices()` 列出所有接口，找到 vendor-defined 的
   `usagePage`（F87S 有线 `0xFF68`、无线 `0xFF60`，其他型号可能是 `0xFF67` 之类）；
2. 按 [`HID-PROTOCOL.md`](HID-PROTOCOL.md) 的帧格式发 `cmd16`，看能不能拿到合法回包
   （回包头应该是 `0x55`）；
3. 能通就说明是同一套协议族，直接进校准流程；
4. 键数不同的话，改 `LED_COUNT` / 矩阵尺寸 / `HARDWARE_IDS` 长度即可，协议不用动。

⚠️ **不要发 `cmd79`（SET_FLASH_DOWNLOAD）** 去试探，那会写固件。
