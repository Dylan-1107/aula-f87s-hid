// AulaF87SController.cpp
// 狼蛛 AULA F87S OpenRGB 控制器 — 实现
// 协议依据：PROTOCOL.md（官方驱动 vendor-JR69bBR4.js 逆向）
#include "AulaF87SController.h"
#include <cstring>

// ===================== 硬件 / 命令常量 =====================
#define F87S_VID_WIRED      0x38A6
#define F87S_PID_WIRED      0x2908
#define F87S_VID_24G        0x0C45
#define F87S_PID_24G        0xFEF9

#define CMD_GET_DEVICE_INFO         16
#define CMD_GET_LED_EFFECT          19
#define CMD_GET_CUSTOM_LED_DATA     20
#define CMD_SET_LED_EFFECT          35
#define CMD_SET_CUSTOM_LED_DATA     36
#define CMD_GET_LED_DATA            50
#define CMD_GET_ALL_LIGHTS_RGB      51
#define CMD_SET_MUSIC_DATA          53
#define CMD_CLEAR_LED_DATA          54
#define CMD_SET_LED_BOOT_ANIMATION  64
#define CMD_SET_LED_USER_ANIMATION  65
#define CMD_SET_LED_DATA            66      // ★物理输出 / GIF 直推
#define CMD_SET_FLASH_DOWNLOAD      79

#define REPORT_ID           0
#define REPORT_SIZE         64      // 主配置口 64 字节（实测；灯光口待确认，见 TODO）
#define HEADER_SIZE         8
#define CHUNK_PAYLOAD       (REPORT_SIZE - HEADER_SIZE)   // 56

#define LED_SLOTS           128     // cmd36/51 槽位数
#define CUSTOM_DATA_SIZE    512     // 128 * 4

// 直推 cmd66 帧头参数（TODO-2：X=ceil(101-u) 待抓包确认，暂用 u=0 → X=101）
#define FRAME_HEADER_X      101

// cmd35 模式值（TODO-3：custom 真实 mode 值待确认，暂用 20）
#define EFFECT_MODE_CUSTOM  20

AulaF87SController::AulaF87SController(hid_device* dev_handle, const char* path)
{
    dev = dev_handle;

    name        = "AULA F87S";
    vendor      = "AULA";
    type        = DEVICE_TYPE_KEYBOARD;
    description = "AULA F87S 8K (reverse-engineered controller)";
    location    = path;

    mode Direct;
    Direct.name       = "Direct";
    Direct.value      = 0;
    Direct.flags      = MODE_FLAG_HAS_PER_LED_COLOR;
    Direct.color_mode = MODE_COLORS_PER_LED;
    modes.push_back(Direct);

    // TODO-3：补充 Static/Custom 保存模式（依赖 cmd35 mode 值与 brightness 量程确认）
    SetupZones();
}

AulaF87SController::~AulaF87SController()
{
    hid_close(dev);
}

// ===================== 布局 =====================
// F87S 为 87 键 TKL。键位顺序与官方 JSON 导入一致（行优先，前 87 槽 = 0..86）。
// 剩余 41 槽（87..127）为旋钮星环灯带 + 两侧装饰灯条，具体映射见 TODO。
void AulaF87SController::SetupZones()
{
    zone z;
    z.name = "Keyboard";
    z.type = ZONE_TYPE_SINGLE;
    z.leds_min = 87;
    z.leds_max = 87;
    z.leds_count = 87;
    z.matrix_map = NULL;

    // 87 键，行优先（F行16 / 数字行17 / QWERTY17 / Home13 / Shift13 / Ctrl11）
    // 每键的 name 用 OpenRGB 键名，led 序号即槽位下标 0..86
    const char* rows[6][17] = {
        // F 行（16）：Esc..F12 段 + 功能区
        { "Key: Escape","Key: F1","Key: F2","Key: F3","Key: F4","Key: F5","Key: F6","Key: F7",
          "Key: F8","Key: F9","Key: F10","Key: F11","Key: F12", nullptr, nullptr, nullptr, nullptr },
        // 数字行（17）：` 1..0 - = Backspace + Ins/Del 等
        { "Key: Grave Accent and Tilde","Key: 1","Key: 2","Key: 3","Key: 4","Key: 5","Key: 6","Key: 7",
          "Key: 8","Key: 9","Key: 0","Key: Minus","Key: Equal Sign","Key: Backspace",
          "Key: Insert","Key: Delete", nullptr },
        // QWERTY 行（17）：Tab Q..] \ + Home/PgUp
        { "Key: Tab","Key: Q","Key: W","Key: E","Key: R","Key: T","Key: Y","Key: U",
          "Key: I","Key: O","Key: P","Key: Left Bracket","Key: Right Bracket","Key: Backslash",
          "Key: Home","Key: Page Up", nullptr },
        // Home 行（13）：Caps A..' Enter + End/PgDn
        { "Key: Caps Lock","Key: A","Key: S","Key: D","Key: F","Key: G","Key: H","Key: J",
          "Key: K","Key: L","Key: Semicolon","Key: Quote","Key: Enter", nullptr, nullptr, nullptr, nullptr },
        // Shift 行（13）：LShift Z../ Enter + ↑
        { "Key: Left Shift","Key: Z","Key: X","Key: C","Key: V","Key: B","Key: N","Key: M",
          "Key: Comma","Key: Period","Key: Slash","Key: Right Shift","Key: Up Arrow", nullptr, nullptr, nullptr, nullptr },
        // Ctrl 行（11）：LCtrl Win Alt Space Alt Fn RCtrl ← ↓ →
        { "Key: Left Control","Key: Left Windows","Key: Left Alt","Key: Space","Key: Right Alt",
          "Key: Right Function","Key: Right Control","Key: Left Arrow","Key: Down Arrow","Key: Right Arrow", nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr },
    };

    // 顺序遍历填入 led，确保 87 键槽位 = 下标 0..86
    int led_idx = 0;
    for (int r = 0; r < 6; r++)
    {
        for (int c = 0; c < 17; c++)
        {
            if (rows[r][c] == nullptr) continue;
            led l;
            l.name = rows[r][c];
            l.value = 0;
            z.leds.push_back(l);
            led_idx++;
        }
    }
    z.leds_count = led_idx;   // 应为 87

    zones.push_back(z);

    SetupColors();
}

void AulaF87SController::ResizeZone(int /*zone*/, int /*new_size*/)
{
    // 固定 87 键，不支持重设
}

// ===================== HID 发包（复刻驱动 hm/ar） =====================
// 普通头：[0xAA, cmd, chunkSize, addr_lo, addr_hi, 0, isLast, 0] + data@8
void AulaF87SController::sendReportNormal(uint8_t cmd, uint16_t contentSize, uint16_t addr,
                                          const uint8_t* data, size_t dataLen, bool isLast)
{
    uint8_t buf[REPORT_SIZE];
    std::memset(buf, 0, REPORT_SIZE);
    buf[0] = 0xAA;
    buf[1] = cmd;
    buf[2] = contentSize & 0xFF;
    buf[3] = addr & 0xFF;
    buf[4] = (addr >> 8) & 0xFF;
    buf[6] = isLast ? 1 : 0;
    if (data && dataLen > 0)
        std::memcpy(buf + HEADER_SIZE, data, dataLen);

    // hidapi 写：首字节为 reportId（0），报告紧跟其后
    uint8_t out[REPORT_SIZE + 1];
    out[0] = REPORT_ID;
    std::memcpy(out + 1, buf, REPORT_SIZE);
    hid_write(dev, out, REPORT_SIZE + 1);
}

void AulaF87SController::sendCommand(uint8_t cmd, const uint8_t* data, size_t dataLen, size_t contentSize)
{
    if (contentSize == 0) contentSize = dataLen;
    size_t Q = (contentSize + CHUNK_PAYLOAD - 1) / CHUNK_PAYLOAD;
    if (Q == 0) Q = 1;
    for (size_t M = 0; M < Q; M++)
    {
        uint16_t addr      = (uint16_t)(M * CHUNK_PAYLOAD);
        size_t   remaining = contentSize - M * CHUNK_PAYLOAD;
        size_t   chunk     = (M == Q - 1) ? remaining : (size_t)CHUNK_PAYLOAD;
        bool     isLast    = (M == Q - 1);

        const uint8_t* d = data;
        size_t dlen = 0;
        if (data)
        {
            size_t off = M * CHUNK_PAYLOAD;
            if (off < dataLen)
            {
                d = data + off;
                dlen = (dataLen - off) < (size_t)CHUNK_PAYLOAD ? (dataLen - off) : (size_t)CHUNK_PAYLOAD;
            }
        }
        sendReportNormal(cmd, (uint16_t)chunk, addr, d, dlen, isLast);
    }
}

// cmd36：写逐键自定义表（512B = 128 槽 × [ledId,R,G,B]）
void AulaF87SController::sendCustomLEDData(const std::vector<RGBColor>& colors)
{
    uint8_t data[CUSTOM_DATA_SIZE];
    std::memset(data, 0, CUSTOM_DATA_SIZE);
    for (int i = 0; i < LED_SLOTS && i < (int)colors.size(); i++)
    {
        data[i * 4 + 0] = (uint8_t)i;                       // ledId = 槽位下标（官方 iYe 强制）
        data[i * 4 + 1] = RGBGetRValue(colors[i]);
        data[i * 4 + 2] = RGBGetGValue(colors[i]);
        data[i * 4 + 3] = RGBGetBValue(colors[i]);
    }
    sendCommand(CMD_SET_CUSTOM_LED_DATA, data, CUSTOM_DATA_SIZE, CUSTOM_DATA_SIZE);
}

// cmd35：切灯效模式（16B）
void AulaF87SController::sendSetEffect(uint8_t mode, uint8_t brightness)
{
    uint8_t t[16];
    std::memset(t, 0, 16);
    t[0]  = mode;          // custom 模式 = 20（实测确认）
    t[4]  = 255;
    t[8]  = 0;             // colorMode
    t[9]  = brightness;    // ★量程 0-5，5=最亮；255 会溢出导致全黑（实测确认）
    t[10] = 0;             // speed
    t[11] = 0;             // direction
    t[12] = 0;             // effectModeType
    t[14] = 0xAA;
    t[15] = 0x55;
    sendCommand(CMD_SET_LED_EFFECT, t, 16, 16);
}

// cmd66：物理输出 / 直推（帧头 + RGB 三元组，自定义 8 字节报告头）
// TODO-1/2：灯光口报告大小与 X 值待抓包确认
void AulaF87SController::sendDirectLED(const std::vector<RGBColor>& colors)
{
    std::vector<uint8_t> payload;
    payload.reserve(4 + colors.size() * 3);

    // 4 字节帧头：frameIdx=0，X=ceil(101-u)
    payload.push_back(0);
    payload.push_back(0);
    payload.push_back(FRAME_HEADER_X & 0xFF);
    payload.push_back((FRAME_HEADER_X >> 8) & 0xFF);

    for (const RGBColor& c : colors)
    {
        payload.push_back(RGBGetRValue(c));
        payload.push_back(RGBGetGValue(c));
        payload.push_back(RGBGetBValue(c));
    }

    size_t Q = (payload.size() + CHUNK_PAYLOAD - 1) / CHUNK_PAYLOAD;
    if (Q == 0) Q = 1;
    for (size_t M = 0; M < Q; M++)
    {
        uint8_t buf[REPORT_SIZE];
        std::memset(buf, 0, REPORT_SIZE);
        // 自定义 8 字节头（复刻驱动 xYe 的 E）
        buf[0] = 0xAA;
        buf[1] = CMD_SET_LED_DATA;
        buf[2] = (M >> 8) & 0xFF;        // chunkIdx_hi
        buf[3] = M & 0xFF;               // chunkIdx_lo
        buf[4] = (Q >> 8) & 0xFF;        // total_hi
        buf[5] = (Q + 1) & 0xFF;         // total_lo（驱动用 h.length/x+1）
        buf[6] = 0;
        buf[7] = 0;

        size_t off = M * CHUNK_PAYLOAD;
        size_t len = (payload.size() - off) < (size_t)CHUNK_PAYLOAD
                     ? (payload.size() - off) : (size_t)CHUNK_PAYLOAD;
        std::memcpy(buf + HEADER_SIZE, payload.data() + off, len);

        uint8_t out[REPORT_SIZE + 1];
        out[0] = REPORT_ID;
        std::memcpy(out + 1, buf, REPORT_SIZE);
        hid_write(dev, out, REPORT_SIZE + 1);
    }
}

// ===================== RGBController 回调 =====================
void AulaF87SController::DeviceUpdateLEDs()
{
    // F87S 直推 = cmd36 写自定义表 + cmd35 切 custom 模式(brightness=5)
    // 注：F87S 有线无 feature report、无 cmd66 灯光口，物理输出就是 cmd36+cmd35
    std::vector<RGBColor> colors;
    for (const led& l : zones[0].leds)
        colors.push_back((RGBColor)l.value);
    sendCustomLEDData(colors);
    sendSetEffect(EFFECT_MODE_CUSTOM, 5);
}

void AulaF87SController::UpdateZoneLEDs(int /*zone*/)
{
    DeviceUpdateLEDs();
}

void AulaF87SController::UpdateSingleLED(int /*led*/)
{
    DeviceUpdateLEDs();
}

void AulaF87SController::DeviceUpdateMode()
{
    // Direct 模式无需额外动作（直推即时生效）
}

void AulaF87SController::DeviceSaveMode()
{
    // 保存模式：cmd36 写自定义表 + cmd35 切 custom 模式
    std::vector<RGBColor> colors;
    for (const led& l : zones[0].leds)
        colors.push_back((RGBColor)l.value);
    sendCustomLEDData(colors);
    sendSetEffect(EFFECT_MODE_CUSTOM, 5);   // brightness=5（量程 0-5，实测确认）
}
