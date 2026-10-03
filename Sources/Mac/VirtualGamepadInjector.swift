import Darwin
import Foundation
import IOKit
import IOKit.hidsystem
import Security

/// The only mockable seam is the OS device. Tests never need HID privileges.
protocol VirtualGamepadHIDDevice: AnyObject {
    func sendReport(_ bytes: [UInt8]) -> IOReturn
    func cancel()
}

/// A separate lock is essential: GetReport can run while HandleReport is waiting
/// with the injector lock held. The callback must never re-enter the injector.
final class VirtualGamepadHIDReportBuffer {
    private let lock = NSLock()
    private var bytes = VirtualGamepadReportState().reportBytes

    func update(_ bytes: [UInt8]) {
        lock.lock()
        self.bytes = bytes
        lock.unlock()
    }

    func copyInputReport(
        type: IOHIDReportType,
        reportID: UInt32,
        destination: UnsafeMutablePointer<UInt8>,
        length: UnsafeMutablePointer<Int>
    ) -> IOReturn {
        let capacity = length.pointee
        length.pointee = 0
        guard type == kIOHIDReportTypeInput,
              reportID == UInt32(VirtualGamepadReport.reportID) else { return kIOReturnUnsupported }
        guard capacity >= 0 else { return kIOReturnBadArgument }
        lock.lock()
        defer { lock.unlock() }
        guard capacity >= bytes.count else {
            length.pointee = bytes.count
            return kIOReturnNoSpace
        }
        bytes.withUnsafeBufferPointer { destination.update(from: $0.baseAddress!, count: $0.count) }
        length.pointee = bytes.count
        return kIOReturnSuccess
    }
}

private final class IOKitVirtualGamepadDevice: VirtualGamepadHIDDevice {
    private let device: IOHIDUserDevice
    private let reportBuffer: VirtualGamepadHIDReportBuffer
    private var cancelled = false

    static func create(queue: DispatchQueue, onCancelled: @escaping () -> Void) -> VirtualGamepadHIDDevice? {
        let properties: [String: Any] = [
            kIOHIDReportDescriptorKey as String: Data(VirtualGamepadReport.descriptor),
            kIOHIDVendorIDKey as String: VirtualGamepadReport.vendorID,
            kIOHIDProductIDKey as String: VirtualGamepadReport.productID,
            kIOHIDVersionNumberKey as String: 1,
            kIOHIDTransportKey as String: "Virtual",
            kIOHIDManufacturerKey as String: "Thumble",
            kIOHIDProductKey as String: "Thumble Virtual Gamepad",
            kIOHIDSerialNumberKey as String: "PocketPad-Gamepad-1",
            kIOHIDPrimaryUsagePageKey as String: 0x01,
            kIOHIDPrimaryUsageKey as String: 0x05
        ]
        guard let device = IOHIDUserDeviceCreateWithProperties(kCFAllocatorDefault, properties as CFDictionary, 1)
        else { return nil }
        return IOKitVirtualGamepadDevice(device: device, queue: queue, onCancelled: onCancelled)
    }

    private init(device: IOHIDUserDevice, queue: DispatchQueue, onCancelled: @escaping () -> Void) {
        self.device = device
        let buffer = VirtualGamepadHIDReportBuffer()
        reportBuffer = buffer
        IOHIDUserDeviceRegisterGetReportBlock(device) { type, id, report, length in
            buffer.copyInputReport(type: type, reportID: id, destination: report, length: length)
        }
        // v1 intentionally has no output/feature reports or rumble contract.
        IOHIDUserDeviceRegisterSetReportBlock(device) { _, _, _, _ in kIOReturnUnsupported }
        IOHIDUserDeviceSetDispatchQueue(device, queue)
        // A dispatch cancel is asynchronous. An extra CF retain, not a capture
        // cycle, keeps the device alive until IOKit finishes all its callbacks.
        let cancellationRetain = Unmanaged.passRetained(device)
        IOHIDUserDeviceSetCancelHandler(device) {
            cancellationRetain.release()
            onCancelled()
        }
        IOHIDUserDeviceActivate(device)
    }

    func sendReport(_ bytes: [UInt8]) -> IOReturn {
        reportBuffer.update(bytes)
        return bytes.withUnsafeBufferPointer {
            IOHIDUserDeviceHandleReportWithTimeStamp(device, mach_absolute_time(), $0.baseAddress!, $0.count)
        }
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        IOHIDUserDeviceCancel(device)
    }
}

final class VirtualGamepadInjector {
    typealias Status = VirtualGamepadStatus
    typealias DeviceFactory = (DispatchQueue, @escaping () -> Void) -> VirtualGamepadHIDDevice?

    private let lock = NSLock()
    private let deviceQueue = DispatchQueue(label: "Thumble.VirtualGamepadHID", qos: .userInteractive)
    private let entitlementProvider: () -> Bool?
    private let deviceFactory: DeviceFactory
    private let uptime: () -> UInt64
    private var virtualDevice: VirtualGamepadHIDDevice?
    private var retiringDevices = 0
    private var state = VirtualGamepadReportState()
    private var phase: VirtualGamepadPhase = .inactive
    private var entitlementGranted: Bool?
    private var lastError: String?
    private var lastReportResult: UInt32?
    private var lastReportUptimeNanoseconds: UInt64?
    private var reportCount: UInt64 = 0
    private var retryAfter: UInt64 = 0

    init(
        entitlementProvider: @escaping () -> Bool? = VirtualGamepadInjector.currentEntitlement,
        deviceFactory: @escaping DeviceFactory = IOKitVirtualGamepadDevice.create,
        uptime: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.entitlementProvider = entitlementProvider
        self.deviceFactory = deviceFactory
        self.uptime = uptime
    }

    deinit { stop() }

    var isActive: Bool { status().isActive }

    func status() -> Status {
        lock.lock()
        defer { lock.unlock() }
        return Status(
            phase: phase,
            entitlementGranted: entitlementGranted,
            lastError: lastError,
            lastReportResult: lastReportResult,
            lastReportUptimeNanoseconds: lastReportUptimeNanoseconds,
            reportCount: reportCount,
            pressedButtons: VirtualGamepadButton.allCases.filter { state.buttons.contains($0) },
            leftStickX: state.leftStickX, leftStickY: state.leftStickY,
            rightStickX: state.rightStickX, rightStickY: state.rightStickY,
            leftTrigger: state.effectiveLeftTrigger, rightTrigger: state.effectiveRightTrigger
        )
    }

    @discardableResult
    func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return startLocked()
    }

    /// Explicit recovery is still performed by the current receiver, never CLI.
    @discardableResult
    func retry() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        state = VirtualGamepadReportState()
        retryAfter = 0
        if virtualDevice != nil { return sendReportLocked() }
        guard retiringDevices == 0 else { return false }
        phase = .inactive
        return startLocked()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        state = VirtualGamepadReportState()
        if virtualDevice != nil { _ = sendReportLocked() }
        retireDeviceLocked()
        phase = .inactive
        lastError = nil
        retryAfter = 0
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        state = VirtualGamepadReportState()
        if virtualDevice != nil { _ = sendReportLocked() }
    }

    func setButton(_ button: VirtualGamepadButton, pressed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        // A release must not create a new device after shutdown or failure.
        guard pressed || virtualDevice != nil, startLocked() else { return }
        if pressed { state.buttons.insert(button) } else { state.buttons.remove(button) }
        _ = sendReportLocked()
    }

    func setStick(_ stick: VirtualGamepadStick, x: Double, y: Double) {
        guard x.isFinite, y.isFinite else { return }
        lock.lock()
        defer { lock.unlock() }
        guard x != 0 || y != 0 || virtualDevice != nil, startLocked() else { return }
        switch stick {
        case .left: state.leftStickX = min(1, max(-1, x)); state.leftStickY = min(1, max(-1, y))
        case .right: state.rightStickX = min(1, max(-1, x)); state.rightStickY = min(1, max(-1, y))
        }
        _ = sendReportLocked()
    }

    func setTrigger(_ trigger: VirtualGamepadTrigger, value: Double) {
        guard value.isFinite else { return }
        lock.lock()
        defer { lock.unlock() }
        guard value != 0 || virtualDevice != nil, startLocked() else { return }
        switch trigger {
        case .left: state.leftTrigger = min(1, max(0, value))
        case .right: state.rightTrigger = min(1, max(0, value))
        }
        _ = sendReportLocked()
    }

    private func startLocked() -> Bool {
        if virtualDevice != nil { return phase == .ready }
        // Failed devices stay latched until owner-controlled recovery releases
        // captured input and explicitly retries; partial automatic restoration
        // would disagree with the server's still-held reference counts.
        guard phase == .inactive, retiringDevices == 0, uptime() >= retryAfter else { return false }
        entitlementGranted = entitlementProvider()
        guard entitlementGranted == true else {
            phase = entitlementGranted == false ? .missingEntitlement : .creationFailed
            lastError = entitlementGranted == false
                ? "This receiver is not signed with com.apple.developer.hid.virtual.device. Check its provisioning profile."
                : "Could not inspect this receiver's signed HID entitlement."
            retryAfter = uptime() &+ 3_000_000_000
            return false
        }
        guard let created = deviceFactory(deviceQueue, { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.retiringDevices -= 1
            self.lock.unlock()
        }) else {
            phase = .creationFailed
            lastError = "IOHIDUserDevice creation failed despite the signed HID entitlement; inspect provisioning, OS policy and IOKit logs."
            retryAfter = uptime() &+ 3_000_000_000
            return false
        }
        virtualDevice = created
        state = VirtualGamepadReportState()
        // Do not publish readiness until the mandatory neutral report succeeds.
        return sendReportLocked()
    }

    @discardableResult
    private func sendReportLocked() -> Bool {
        guard let device = virtualDevice else { return false }
        let result = device.sendReport(state.reportBytes)
        lastReportResult = UInt32(bitPattern: result)
        lastReportUptimeNanoseconds = uptime()
        if result == kIOReturnSuccess {
            reportCount &+= 1
            phase = .ready
            lastError = nil
            return true
        }
        phase = .reportFailed
        lastError = "IOHIDUserDevice report failed: 0x\(String(UInt32(bitPattern: result), radix: 16)). Device retired; retry controller output."
        state = VirtualGamepadReportState()
        // Best effort neutralization precedes cancellation. Preserve the original
        // failure even if this last report succeeds; readiness remains false.
        _ = device.sendReport(state.reportBytes)
        retryAfter = uptime() &+ 3_000_000_000
        retireDeviceLocked()
        return false
    }

    private func retireDeviceLocked() {
        guard let device = virtualDevice else { return }
        virtualDevice = nil
        retiringDevices += 1
        // Never let even a synchronous test-system cancel callback re-enter lock.
        // The closure also retains the wrapper through the call to Cancel.
        deviceQueue.async { device.cancel() }
    }

    private static func currentEntitlement() -> Bool? {
        guard let task = SecTaskCreateFromSelf(kCFAllocatorDefault) else { return nil }
        var error: Unmanaged<CFError>?
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.hid.virtual.device" as CFString, &error)
        defer { _ = error?.takeRetainedValue() }
        // Only a Boolean true grants this managed entitlement.
        guard let value else { return error == nil ? false : nil }
        guard CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self))
    }
}
