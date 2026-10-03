#!/usr/bin/env swift
// Read-only independent consumer probe. Never creates HID or injects input.
// Run while the appropriately signed receiver and paired iPhone are active.
import CryptoKit
import Foundation
import GameController
import IOKit
import IOKit.hid

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count <= 1,
      arguments.first == nil || (Double(arguments[0]).map { (0...30).contains($0) } ?? false) else {
    fputs("Usage: swift scripts/probe-gamepad-compatibility.swift [observation-seconds: 0...30]\n", stderr)
    exit(2)
}
let duration = arguments.first.flatMap(Double.init) ?? 3
let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
IOHIDManagerSetDeviceMatching(manager, [
    kIOHIDVendorIDKey as String: 0xCB01,
    kIOHIDProductIDKey as String: 0x5050
] as CFDictionary)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
let openResult = IOHIDManagerOpen(manager, 0)
GCController.shouldMonitorBackgroundEvents = true
RunLoop.main.run(until: Date().addingTimeInterval(duration))

func property(_ device: IOHIDDevice, _ name: String) -> Any? {
    IOHIDDeviceGetProperty(device, name as CFString)
}

let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
let hid: [[String: Any]] = devices.map { device in
    var registryID: UInt64 = 0
    let service = IOHIDDeviceGetService(device)
    let registryResult = IORegistryEntryGetRegistryEntryID(service, &registryID)
    var result: [String: Any] = [
        "registryID": registryID,
        "registryResult": UInt32(bitPattern: registryResult),
        "gameControllerSupportsHIDDevice": GCController.supportsHIDDevice(device)
    ]
    for key in ["Product", "Manufacturer", "Transport", "VendorID", "ProductID", "VersionNumber", "PrimaryUsagePage", "PrimaryUsage"] {
        if let value = property(device, key) { result[key] = value }
    }
    if let descriptor = property(device, "ReportDescriptor") as? Data {
        result["descriptorSHA256"] = SHA256.hash(data: descriptor).map { String(format: "%02x", $0) }.joined()
    }
    let elements = (IOHIDDeviceCopyMatchingElements(device, nil, 0) as? [IOHIDElement]) ?? []
    result["inputs"] = elements.compactMap { element -> [String: Any]? in
        let kind = IOHIDElementGetType(element)
        guard kind == kIOHIDElementTypeInput_Button || kind == kIOHIDElementTypeInput_Axis ||
              kind == kIOHIDElementTypeInput_Misc else { return nil }
        let reading = withUnsafeTemporaryAllocation(of: Unmanaged<IOHIDValue>.self, capacity: 1) { buffer in
            let status = IOHIDDeviceGetValue(device, element, buffer.baseAddress!)
            return (status, status == kIOReturnSuccess ? IOHIDValueGetIntegerValue(buffer[0].takeUnretainedValue()) : nil)
        }
        var input: [String: Any] = [
            "usagePage": IOHIDElementGetUsagePage(element), "usage": IOHIDElementGetUsage(element),
            "logicalMin": IOHIDElementGetLogicalMin(element), "logicalMax": IOHIDElementGetLogicalMax(element),
            "unit": IOHIDElementGetUnit(element), "result": UInt32(bitPattern: reading.0)
        ]
        if let value = reading.1 { input["value"] = value }
        return input
    }
    return result
}
let controllers: [[String: Any]] = GCController.controllers().map { controller in
    var result: [String: Any] = [
        "vendorName": controller.vendorName ?? "unknown", "productCategory": controller.productCategory,
        "extendedGamepad": controller.extendedGamepad != nil,
        "buttonCount": controller.physicalInputProfile.buttons.count,
        "axisCount": controller.physicalInputProfile.axes.count,
        "buttons": controller.physicalInputProfile.buttons.mapValues { ["value": $0.value, "pressed": $0.isPressed] as [String: Any] }
    ]
    if let gamepad = controller.extendedGamepad {
        result["axes"] = [
            "leftX": gamepad.leftThumbstick.xAxis.value, "leftY": gamepad.leftThumbstick.yAxis.value,
            "rightX": gamepad.rightThumbstick.xAxis.value, "rightY": gamepad.rightThumbstick.yAxis.value,
            "leftTrigger": gamepad.leftTrigger.value, "rightTrigger": gamepad.rightTrigger.value,
            "dpadX": gamepad.dpad.xAxis.value, "dpadY": gamepad.dpad.yAxis.value
        ]
    }
    return result
}
let report: [String: Any] = [
    "observedAt": ISO8601DateFormatter().string(from: Date()),
    "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
    "observationSeconds": duration,
    "hidManagerOpenResult": UInt32(bitPattern: openResult),
    "thumbleHIDDevices": hid,
    "gameControllerControllers": controllers,
    "consumerTestsStillRequired": ["SDL raw joystick and mapped gamepad", "Steam Input on/off", "actual games"],
    "note": "Registry presence, supportsHIDDevice and enumeration are separate observations, not a gameplay pass."
]
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data([10]))
IOHIDManagerClose(manager, 0)
IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
