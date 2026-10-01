// AulaF87SController.h
// 狼蛛 AULA F87S (0x38A6:0x2908) OpenRGB 控制器 — 声明
// 协议依据见同目录 PROTOCOL.md（与官方驱动 vendor-JR69bBR4.js 逐字核对）
#pragma once

#include "RGBController.h"
#include "RGBControllerKeyNames.h"
#include <vector>
#include <hidapi/hidapi.h>

class AulaF87SController : public RGBController
{
public:
    AulaF87SController(hid_device* dev_handle, const char* path);
    ~AulaF87SController();

    // ---- RGBController 必须实现的接口 ----
    void        SetupZones();
    void        ResizeZone(int zone, int new_size);

    // 直推模式（OpenRGB 默认，实时预览）：cmd66 物理输出
    void        DeviceUpdateLEDs();
    void        UpdateZoneLEDs(int zone);
    void        UpdateSingleLED(int led);

    // 保存模式：cmd36 写自定义表 + cmd35 切模式
    void        DeviceUpdateMode();
    void        DeviceSaveMode();

private:
    hid_device* dev;

    // ---- HID 发包（复刻驱动 hm/ar）----
    void        sendReportNormal(uint8_t cmd, uint16_t contentSize, uint16_t addr,
                                 const uint8_t* data, size_t dataLen, bool isLast);
    void        sendCommand(uint8_t cmd, const uint8_t* data, size_t dataLen, size_t contentSize);
    void        sendCustomLEDData(const std::vector<RGBColor>& colors);   // cmd36
    void        sendSetEffect(uint8_t mode, uint8_t brightness);           // cmd35
    void        sendDirectLED(const std::vector<RGBColor>& colors);        // cmd66 物理输出
};
