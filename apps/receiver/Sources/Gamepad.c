#include "Gamepad.h"
#include <IOKit/hidsystem/IOHIDUserDevice.h>
#include <pthread.h>
#include <mach/mach_time.h>
#include <string.h>
#include <stdlib.h>

// macOS 27 only lets virtual HID devices match GameController personalities marked
// GCIOMatchVirtual. The Xbox 360 personality (045E:028E) is not, so WoW never saw the pad.
// Present as an Xbox Series X|S controller over Bluetooth (045E:0B13), which is allowed,
// using that controller's 17-byte report (ID 1). Receiver.swift still builds the
// 20-byte Xbox 360-style report; tapping_gamepad_send converts it here.
static const uint8_t series_descriptor[] = {
    0x05,0x01, 0x09,0x05, 0xA1,0x01, 0x85,0x01,
    // Left stick X/Y, right stick Z/Rz: 16-bit, 0..65535, centre 32768, Y down (same direction as the 360 report).
    0x09,0x01, 0xA1,0x00, 0x09,0x30, 0x09,0x31, 0x15,0x00, 0x27,0xFF,0xFF,0x00,0x00, 0x95,0x02, 0x75,0x10, 0x81,0x02, 0xC0,
    0x09,0x01, 0xA1,0x00, 0x09,0x32, 0x09,0x35, 0x15,0x00, 0x27,0xFF,0xFF,0x00,0x00, 0x95,0x02, 0x75,0x10, 0x81,0x02, 0xC0,
    // Brake (LT) and accelerator (RT): 10 bits each, padded to 16.
    0x05,0x02, 0x09,0xC5, 0x15,0x00, 0x26,0xFF,0x03, 0x95,0x01, 0x75,0x0A, 0x81,0x02, 0x15,0x00, 0x25,0x00, 0x75,0x06, 0x95,0x01, 0x81,0x03,
    0x05,0x02, 0x09,0xC4, 0x15,0x00, 0x26,0xFF,0x03, 0x95,0x01, 0x75,0x0A, 0x81,0x02, 0x15,0x00, 0x25,0x00, 0x75,0x06, 0x95,0x01, 0x81,0x03,
    // Hat switch 1..8, 0 = centred.
    0x05,0x01, 0x09,0x39, 0x15,0x01, 0x25,0x08, 0x35,0x00, 0x46,0x3B,0x01, 0x66,0x14,0x00, 0x75,0x04, 0x95,0x01, 0x81,0x42,
    0x75,0x04, 0x95,0x01, 0x15,0x00, 0x25,0x00, 0x35,0x00, 0x45,0x00, 0x65,0x00, 0x81,0x03,
    // 15 buttons + 1 pad bit.
    0x05,0x09, 0x19,0x01, 0x29,0x0F, 0x15,0x00, 0x25,0x01, 0x75,0x01, 0x95,0x0F, 0x81,0x02,
    0x15,0x00, 0x25,0x00, 0x75,0x01, 0x95,0x01, 0x81,0x03,
    // Share button + 7 pad bits.
    0x05,0x0C, 0x0A,0xB2,0x00, 0x15,0x00, 0x25,0x01, 0x95,0x01, 0x75,0x01, 0x81,0x02,
    0x15,0x00, 0x25,0x00, 0x75,0x07, 0x95,0x01, 0x81,0x03,
    0xC0,
};
enum { REPORT_SIZE = 17 };
typedef struct { IOHIDUserDeviceRef device; pthread_mutex_t lock; uint8_t report[REPORT_SIZE]; } Gamepad;

static void put16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static int16_t get16(const uint8_t *p) { return (int16_t)(p[0] | (p[1] << 8)); }
static uint16_t axis(int16_t v) { return (uint16_t)((int32_t)v + 32768); }
// Xbox 360-style report (bytes 2-3 buttons, 4-5 triggers, 6-13 signed sticks, HID Y-down) → Series BLE report.
void tapping_gamepad_convert(const uint8_t *x360, uint8_t *out) {
    uint16_t b = (uint16_t)(x360[2] | (x360[3] << 8));
    memset(out, 0, REPORT_SIZE); out[0] = 1;
    put16(out + 1, axis(get16(x360 + 6))); put16(out + 3, axis(get16(x360 + 8)));
    put16(out + 5, axis(get16(x360 + 10))); put16(out + 7, axis(get16(x360 + 12)));
    put16(out + 9, (uint16_t)((x360[4] * 1023 + 127) / 255)); put16(out + 11, (uint16_t)((x360[5] * 1023 + 127) / 255));
    int up = b & 1, down = (b >> 1) & 1, left = (b >> 2) & 1, right = (b >> 3) & 1;
    static const uint8_t hats[3][3] = {{8, 1, 2}, {7, 0, 3}, {6, 5, 4}}; // [y][x], y: up/centre/down
    out[13] = hats[up ? 0 : down ? 2 : 1][left ? 0 : right ? 2 : 1];
    static const int map[][2] = {{12, 0}, {13, 1}, {14, 3}, {15, 4}, {8, 6}, {9, 7}, {5, 10}, {4, 11}, {10, 12}, {6, 13}, {7, 14}};
    uint16_t o = 0;
    for (size_t i = 0; i < sizeof map / sizeof map[0]; i++) if (b & (1u << map[i][0])) o |= (uint16_t)(1u << map[i][1]);
    put16(out + 14, o);
}
void *tapping_gamepad_create(void) {
    Gamepad *g = calloc(1, sizeof(Gamepad));
    pthread_mutex_init(&g->lock, NULL);
    uint8_t neutral[20] = {0, 20}; tapping_gamepad_convert(neutral, g->report);
    int vid = 0x045e, pid = 0x0b13;
    CFNumberRef vendor = CFNumberCreate(NULL, kCFNumberIntType, &vid), product = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    CFDataRef descriptor = CFDataCreate(NULL, series_descriptor, sizeof(series_descriptor));
    const void *keys[] = {CFSTR(kIOHIDReportDescriptorKey), CFSTR(kIOHIDProductKey), CFSTR(kIOHIDManufacturerKey), CFSTR(kIOHIDTransportKey), CFSTR(kIOHIDVendorIDKey), CFSTR(kIOHIDProductIDKey)};
    const void *values[] = {descriptor, CFSTR("Thumble Wi-Fi Gamepad"), CFSTR("Thumble"), CFSTR("Bluetooth Low Energy"), vendor, product};
    CFDictionaryRef props = CFDictionaryCreate(NULL, keys, values, 6, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    g->device = IOHIDUserDeviceCreateWithProperties(NULL, props, IOHIDUserDeviceOptionsCreateOnActivate);
    CFRelease(props); CFRelease(descriptor); CFRelease(vendor); CFRelease(product);
    if (!g->device) { pthread_mutex_destroy(&g->lock); free(g); return NULL; }
    IOHIDUserDeviceRegisterGetReportBlock(g->device, ^IOReturn(IOHIDReportType type, uint32_t id, uint8_t *report, CFIndex *size) {
        if (type != kIOHIDReportTypeInput || id != 1) return kIOReturnUnsupported;
        if (*size < REPORT_SIZE) { *size = REPORT_SIZE; return kIOReturnNoSpace; }
        pthread_mutex_lock(&g->lock); memcpy(report, g->report, REPORT_SIZE); pthread_mutex_unlock(&g->lock);
        *size = REPORT_SIZE; return kIOReturnSuccess;
    });
    IOHIDUserDeviceRegisterSetReportBlock(g->device, ^IOReturn(IOHIDReportType type, uint32_t id, const uint8_t *report, CFIndex size) {
        (void)type; (void)id; (void)report; (void)size; return kIOReturnSuccess; // rumble/LED requests: accept and ignore
    });
    IOHIDUserDeviceSetDispatchQueue(g->device, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));
    IOHIDUserDeviceSetCancelHandler(g->device, ^{ CFRelease(g->device); pthread_mutex_destroy(&g->lock); free(g); });
    IOHIDUserDeviceActivate(g->device);
    return g;
}
int32_t tapping_gamepad_send(void *device, const uint8_t *report) {
    Gamepad *g = device;
    uint8_t out[REPORT_SIZE]; tapping_gamepad_convert(report, out);
    pthread_mutex_lock(&g->lock); memcpy(g->report, out, REPORT_SIZE); pthread_mutex_unlock(&g->lock);
    // Never hold the GetReport lock while calling IOKit: it can call back synchronously.
    return IOHIDUserDeviceHandleReportWithTimeStamp(g->device, mach_absolute_time(), out, REPORT_SIZE);
}
void tapping_gamepad_destroy(void *device) { if (device) IOHIDUserDeviceCancel(((Gamepad *)device)->device); }
