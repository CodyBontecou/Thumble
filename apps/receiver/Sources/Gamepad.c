#include "Gamepad.h"
#include <IOKit/hidsystem/IOHIDUserDevice.h>
#include <pthread.h>
#include <mach/mach_time.h>
#include <string.h>
#include <stdlib.h>
#include "../../../tools/xbox-hid-descriptor.h"
typedef struct { IOHIDUserDeviceRef device; pthread_mutex_t lock; uint8_t report[20]; } Gamepad;
void *tapping_gamepad_create(void) {
    Gamepad *g = calloc(1, sizeof(Gamepad));
    pthread_mutex_init(&g->lock, NULL); g->report[1] = 20;
    int vid = 0x045e, pid = 0x028e;
    CFNumberRef vendor = CFNumberCreate(NULL, kCFNumberIntType, &vid), product = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    CFDataRef descriptor = CFDataCreate(NULL, xbox_descriptor, sizeof(xbox_descriptor));
    const void *keys[] = {CFSTR(kIOHIDReportDescriptorKey), CFSTR(kIOHIDProductKey), CFSTR(kIOHIDManufacturerKey), CFSTR(kIOHIDTransportKey), CFSTR(kIOHIDVendorIDKey), CFSTR(kIOHIDProductIDKey)};
    const void *values[] = {descriptor, CFSTR("Tapping Wi-Fi Gamepad"), CFSTR("Tapping"), CFSTR("USB"), vendor, product};
    CFDictionaryRef props = CFDictionaryCreate(NULL, keys, values, 6, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    g->device = IOHIDUserDeviceCreateWithProperties(NULL, props, IOHIDUserDeviceOptionsCreateOnActivate);
    CFRelease(props); CFRelease(descriptor); CFRelease(vendor); CFRelease(product);
    if (!g->device) { pthread_mutex_destroy(&g->lock); free(g); return NULL; }
    IOHIDUserDeviceRegisterGetReportBlock(g->device, ^IOReturn(IOHIDReportType type, uint32_t id, uint8_t *report, CFIndex *size) {
        if (type != kIOHIDReportTypeInput || id) return kIOReturnUnsupported;
        if (*size < 20) { *size = 20; return kIOReturnNoSpace; }
        pthread_mutex_lock(&g->lock); memcpy(report, g->report, 20); pthread_mutex_unlock(&g->lock);
        *size = 20; return kIOReturnSuccess;
    });
    IOHIDUserDeviceRegisterSetReportBlock(g->device, ^IOReturn(IOHIDReportType type, uint32_t id, const uint8_t *report, CFIndex size) {
        (void)type; (void)id; (void)report; (void)size; return kIOReturnUnsupported;
    });
    IOHIDUserDeviceSetDispatchQueue(g->device, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));
    IOHIDUserDeviceSetCancelHandler(g->device, ^{ CFRelease(g->device); pthread_mutex_destroy(&g->lock); free(g); });
    IOHIDUserDeviceActivate(g->device);
    return g;
}
int32_t tapping_gamepad_send(void *device, const uint8_t *report) {
    Gamepad *g = device;
    pthread_mutex_lock(&g->lock); memcpy(g->report, report, 20); pthread_mutex_unlock(&g->lock);
    // Never hold the GetReport lock while calling IOKit: it can call back synchronously.
    return IOHIDUserDeviceHandleReportWithTimeStamp(g->device, mach_absolute_time(), report, 20);
}
void tapping_gamepad_destroy(void *device) { if (device) IOHIDUserDeviceCancel(((Gamepad *)device)->device); }
