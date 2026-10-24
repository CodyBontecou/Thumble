// Diagnostic only: creates an ephemeral gamepad, sends no reports, then releases it.
// Build: xcrun clang -fblocks -framework IOKit -framework CoreFoundation tools/macos-hid-probe.c -o /tmp/thumble-hid-probe
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hidsystem/IOHIDUserDevice.h>
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "xbox-hid-descriptor.h"

int main(int argc, char **argv) {
    unsigned hold_seconds = 0;
    bool xbox = false;
    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--xbox") == 0) xbox = true;
        else if (strcmp(argv[i], "--hold-seconds") == 0 && i + 1 < argc) {
            char *end = NULL;
            long duration = strtol(argv[++i], &end, 10);
            if (end == argv[i] || *end != '\0' || duration < 0 || duration > 30) return 2;
            hold_seconds = (unsigned)duration;
        } else {
            fprintf(stderr, "Usage: macos-hid-probe [--xbox] [--hold-seconds 0...30]\n");
            return 2;
        }
    }
    // Generic Desktop / Game Pad; 16 buttons, four signed 8-bit axes.
    const unsigned char descriptor[] = {
        0x05,0x01,0x09,0x05,0xA1,0x01,
        0x05,0x09,0x19,0x01,0x29,0x10,0x15,0x00,0x25,0x01,
        0x75,0x01,0x95,0x10,0x81,0x02,
        0x05,0x01,0x09,0x30,0x09,0x31,0x09,0x33,0x09,0x34,
        0x15,0x81,0x25,0x7F,0x75,0x08,0x95,0x04,0x81,0x02,0xC0
    };
    CFMutableDictionaryRef properties = CFDictionaryCreateMutable(
        NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDataRef data = CFDataCreate(NULL, xbox ? xbox_descriptor : descriptor,
                                xbox ? sizeof(xbox_descriptor) : sizeof(descriptor));
    CFDictionarySetValue(properties, CFSTR(kIOHIDReportDescriptorKey), data);
    CFDictionarySetValue(properties, CFSTR(kIOHIDProductKey), CFSTR("Thumble HID capability probe"));
    CFDictionarySetValue(properties, CFSTR(kIOHIDTransportKey), xbox ? CFSTR("USB") : CFSTR("Virtual"));
    CFDictionarySetValue(properties, CFSTR(kIOHIDManufacturerKey), CFSTR("Thumble"));
    if (xbox) {
        int vendor = 0x045e, product = 0x028e;
        CFNumberRef vendor_ref = CFNumberCreate(NULL, kCFNumberIntType, &vendor);
        CFNumberRef product_ref = CFNumberCreate(NULL, kCFNumberIntType, &product);
        CFDictionarySetValue(properties, CFSTR(kIOHIDVendorIDKey), vendor_ref);
        CFDictionarySetValue(properties, CFSTR(kIOHIDProductIDKey), product_ref);
        CFRelease(vendor_ref);
        CFRelease(product_ref);
    }
    IOHIDUserDeviceRef device = IOHIDUserDeviceCreateWithProperties(NULL, properties, IOHIDUserDeviceOptionsCreateOnActivate);
    printf("uid=%u IOHIDUserDeviceCreateWithProperties=%s\n", getuid(), device ? "SUCCESS" : "NULL");
    fflush(stdout);
    if (device) {
        CFIndex report_size = xbox ? 20 : 6;
        IOHIDUserDeviceRegisterGetReportBlock(device, ^IOReturn(IOHIDReportType type, uint32_t report_id, uint8_t *report, CFIndex *length) {
            if (type != kIOHIDReportTypeInput || report_id != 0) return kIOReturnUnsupported;
            if (*length < report_size) { *length = report_size; return kIOReturnNoSpace; }
            memset(report, 0, (size_t)report_size);
            if (xbox) report[1] = 20;
            *length = report_size;
            return kIOReturnSuccess;
        });
        IOHIDUserDeviceRegisterSetReportBlock(device, ^IOReturn(IOHIDReportType type, uint32_t report_id, const uint8_t *report, CFIndex length) {
            (void)type; (void)report_id; (void)report; (void)length;
            return kIOReturnUnsupported;
        });
        IOHIDUserDeviceSetDispatchQueue(device, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));
        CFRetain(device);
        IOHIDUserDeviceSetCancelHandler(device, ^{ CFRelease(device); });
        IOHIDUserDeviceActivate(device);
    }
    if (device && hold_seconds) CFRunLoopRunInMode(kCFRunLoopDefaultMode, hold_seconds, false);
    if (device) IOHIDUserDeviceCancel(device);
    if (device) CFRelease(device);
    CFRelease(data);
    CFRelease(properties);
    return device ? 0 : 1;
}
