import Foundation
import IOKit
import IOKit.hid
let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
let matches = [[kIOHIDProductKey: "Tapping Wi-Fi Gamepad"], [kIOHIDProductKey: "Thumble Wi-Fi Gamepad"]]
IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
IOHIDManagerRegisterInputValueCallback(manager, { _, result, _, value in
    guard result == kIOReturnSuccess else { return }
    let element = IOHIDValueGetElement(value)
    let product = IOHIDDeviceGetProperty(IOHIDElementGetDevice(element), kIOHIDProductKey as CFString) as? String ?? ""
    guard ["Tapping Wi-Fi Gamepad", "Thumble Wi-Fi Gamepad"].contains(product), [UInt32(1), UInt32(9)].contains(IOHIDElementGetUsagePage(element)) else { return }
    let entry: [String: Any] = ["time": Date().timeIntervalSince1970,
        "product": product,
        "cookie": IOHIDElementGetCookie(element),
        "page": IOHIDElementGetUsagePage(element), "usage": IOHIDElementGetUsage(element),
        "min": IOHIDElementGetLogicalMin(element), "max": IOHIDElementGetLogicalMax(element),
        "value": IOHIDValueGetIntegerValue(value)]
    if let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) {
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
    }
}, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
let result = IOHIDManagerOpen(manager, 0)
fputs("Independent HID observer open result=\(result)\n", stderr)
RunLoop.main.run(until: Date().addingTimeInterval(600))
IOHIDManagerClose(manager, 0)
IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
