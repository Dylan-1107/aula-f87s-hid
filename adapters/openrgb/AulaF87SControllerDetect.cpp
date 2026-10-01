// AulaF87SControllerDetect.cpp
// 设备探测：注册 F87S 到 OpenRGB 的 DeviceDetector
#include "AulaF87SController.h"
#include "Detector.h"
#include "RGBController.h"
#include "LogManager.h"
#include "hidapi/hidapi.h"

#define F87S_VID_WIRED  0x38A6
#define F87S_PID_WIRED  0x2908
#define F87S_VID_24G    0x0C45
#define F87S_PID_24G    0xFEF9

void DetectAulaF87SControllers(hid_device_info* info, const std::string& /*name*/)
{
    hid_device* dev = hid_open_path(info->path);
    if (dev)
    {
        AulaF87SController* controller = new AulaF87SController(dev, info->path);
        ResourceManager::get()->RegisterRGBController(controller);
    }
}

REGISTER_DETECTOR("AULA F87S 8K", DetectAulaF87SControllers, F87S_VID_WIRED, F87S_PID_WIRED);
REGISTER_DETECTOR("AULA F87S 8K 2.4G", DetectAulaF87SControllers, F87S_VID_24G, F87S_PID_24G);
