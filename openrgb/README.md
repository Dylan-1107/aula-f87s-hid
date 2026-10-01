# OpenRGB C++ 控制器（⚠️ 从未编译验证）

> **状态：实验性。** 本机缺 Qt 与 OpenRGB 源码树，这份代码**从未成功编译过**，仅供有环境的开发者参考。
> 逻辑已按实测协议修正（`DeviceUpdateLEDs()` 走 cmd36 + cmd35，无 feature report、无 cmd66），
> 但**文件顶部的 TODO 注释已过时**，以代码正文和 [`../docs/HID-PROTOCOL.md`](../docs/HID-PROTOCOL.md) 为准。

## 为什么需要独立控制器

OpenRGB 官方目前不支持 `0x38A6:0x2908`（只支持 SinoWealth F87 Pro `0x258A:0x010C`）。

## 构建步骤

```bash
1. 安装 Qt5/Qt6（MSVC 版，含 QtWidgets）
2. git clone https://gitlab.com/CalcProgrammer1/OpenRGB.git
3. 把本目录的 .h / .cpp 放进 OpenRGB/Controllers/AulaF87SController/
4. 在 RGBControllerDetector.cpp 注册 AulaF87SControllerDetect.cpp
5. CMake 构建
```

代码结构参考 `SinowealthKeyboard10cController`，个别 API 签名可能需要按当前 OpenRGB 版本微调。

## 文件

| 文件 | 内容 |
|---|---|
| `AulaF87SController.h` | 类声明，继承 `RGBController` |
| `AulaF87SController.cpp` | 控制器实现（`DeviceUpdateLEDs` = cmd36 + cmd35） |
| `AulaF87SControllerDetect.cpp` | 设备探测注册（VID `0x38A6` / PID `0x2908`） |

欢迎提 PR 把它跑起来。
