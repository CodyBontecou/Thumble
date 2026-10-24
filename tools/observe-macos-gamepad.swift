// Independent read-only observer. Creates no devices and sends no input.
import Foundation
import GameController
import IOKit
import IOKit.hid

let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
IOHIDManagerSetDeviceMatching(manager, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
let openResult = IOHIDManagerOpen(manager, 0)
GCController.shouldMonitorBackgroundEvents = true
RunLoop.main.run(until: Date().addingTimeInterval(2))

let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
let observations: [[String: Any]] = devices.filter {
    (IOHIDDeviceGetProperty($0, kIOHIDProductKey as CFString) as? String) == "Thumble HID capability probe"
}.map { device in
    [
        "product": IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) ?? "unknown" as CFString,
        "supportedByGameController": GCController.supportsHIDDevice(device)
    ]
}
let result: [String: Any] = [
    "hidManagerOpenResult": UInt32(bitPattern: openResult),
    "probeHIDDevices": observations,
    "gameControllers": GCController.controllers().map {
        ["vendorName": $0.vendorName ?? "unknown", "category": $0.productCategory,
         "extendedGamepad": $0.extendedGamepad != nil] as [String: Any]
    }
]
let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data([10]))
IOHIDManagerClose(manager, 0)
IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
