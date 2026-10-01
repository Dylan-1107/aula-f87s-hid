# OpenRGB 原生控制器适配层（C++）

把 AULA F87S 编进 OpenRGB，让它出现在设备列表里、使用全部内置灯效。
**不需要 SKYdimo**——本适配层直接实现 [`docs/HID-PROTOCOL.md`](../../docs/HID-PROTOCOL.md)。

完整说明（含另两条免编译路径）→ [`docs/OPENRGB.md`](../../docs/OPENRGB.md)

---

## ⚠️ 状态：从未编译过

本机缺 Qt 与 OpenRGB 源码树，这份代码只做到「逻辑按实测协议写完」，**一次都没编译成功过**。
API 签名可能需要按当前 OpenRGB 版本微调。欢迎 PR。

> 文件顶部的 TODO 注释**已过时**（仍写着"cmd66 帧头待抓包""custom mode 待确认"），
> **以代码正文和 `docs/HID-PROTOCOL.md` 为准**。

## 为什么需要它

OpenRGB 官方不支持 `0x38A6:0x2908`（只支持 SinoWealth F87 Pro `0x258A:0x010C`）。
F87S 是全新 8K 平台，VID 不同 → 检测不到。

## 构建速查

```bash
git clone https://gitlab.com/CalcProgrammer1/OpenRGB.git
mkdir -p OpenRGB/Controllers/AulaF87SController
cp *.h *.cpp OpenRGB/Controllers/AulaF87SController/

# 在 Controllers/RGBControllerDetector.cpp 注册：
#   #include "AulaF87SControllerDetect.cpp"
#   DetectAulaF87SControllers(existing_controllers);

# 需 Qt5/Qt6（MSVC 版，含 QtWidgets），然后用 Qt Creator 或 qmake/make 构建
```

代码结构参考 `SinowealthKeyboard10cController`。

## 文件

| 文件 | 内容 |
|---|---|
| `AulaF87SController.h` | 类声明，继承 `RGBController` |
| `AulaF87SController.cpp` | `DeviceUpdateLEDs()` = `cmd36` + `cmd35`；无 feature report、无 cmd66 |
| `AulaF87SControllerDetect.cpp` | 设备探测注册（VID `0x38A6` / PID `0x2908`） |
