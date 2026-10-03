import Foundation
import IOKit
import IOKit.hidsystem
import XCTest

final class VirtualGamepadInjectorTests: XCTestCase {
    func testNeverStartedDeviceDoesNotClaimAvailability() {
        XCTAssertFalse(VirtualGamepadInjector().status().isAvailable)
    }

    func testMissingEntitlementDoesNotAttemptDeviceCreationAndLatchesRetries() {
        var creations = 0
        var inspections = 0
        var now: UInt64 = 1_000_000_000
        let injector = VirtualGamepadInjector(entitlementProvider: { inspections += 1; return false }, deviceFactory: { _, _ in
            creations += 1
            return nil
        }, uptime: { now })
        XCTAssertFalse(injector.start())
        now = 10_000_000_000
        injector.setButton(.south, pressed: true)
        XCTAssertEqual(creations, 0)
        XCTAssertEqual(inspections, 1)
        XCTAssertEqual(injector.status().phase, .missingEntitlement)
        XCTAssertFalse(injector.status().isAvailable)
        XCTAssertFalse(injector.retry())
        XCTAssertEqual(inspections, 2)
        XCTAssertEqual(creations, 0)
    }

    func testCreationFailureWithEntitlementIsNotMisreportedAsMissingEntitlement() {
        let injector = VirtualGamepadInjector(entitlementProvider: { true }, deviceFactory: { _, _ in nil })
        XCTAssertFalse(injector.start())
        XCTAssertEqual(injector.status().phase, .creationFailed)
        XCTAssertEqual(injector.status().entitlementGranted, true)
    }

    func testInitialReportFailureNeverPublishesReadyAndCancelsDevice() {
        let cancelled = expectation(description: "cancel finishes")
        let device = FakeDevice(results: [kIOReturnError, kIOReturnSuccess])
        let injector = VirtualGamepadInjector(entitlementProvider: { true }, deviceFactory: { _, onCancelled in
            device.onCancelled = { onCancelled(); cancelled.fulfill() }
            return device
        })
        XCTAssertFalse(injector.start())
        XCTAssertFalse(injector.status().isActive)
        XCTAssertEqual(injector.status().phase, .reportFailed)
        XCTAssertEqual(injector.status().reportCount, 0)
        XCTAssertEqual(device.reports, [[1, 0, 0, 8, 0, 0, 0, 0, 0, 0], [1, 0, 0, 8, 0, 0, 0, 0, 0, 0]])
        wait(for: [cancelled], timeout: 1)
    }

    func testStopNeutralizesAllOutputsBeforeCancellationAndReleaseDoesNotRecreate() {
        let cancelled = expectation(description: "cancel finishes")
        let device = FakeDevice()
        var creations = 0
        let injector = VirtualGamepadInjector(entitlementProvider: { true }, deviceFactory: { _, onCancelled in
            creations += 1
            device.onCancelled = { onCancelled(); cancelled.fulfill() }
            return device
        })
        XCTAssertTrue(injector.start())
        injector.setButton(.south, pressed: true)
        injector.setStick(.right, x: 1, y: -1)
        injector.setTrigger(.left, value: 1)
        XCTAssertTrue(injector.status().isAvailable)
        injector.stop()
        wait(for: [cancelled], timeout: 1)
        injector.setButton(.south, pressed: false)
        injector.setStick(.right, x: 0, y: 0)
        injector.setTrigger(.left, value: 0)
        XCTAssertEqual(creations, 1)
        XCTAssertEqual(device.reports.last, [1, 0, 0, 8, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(injector.status().phase, .inactive)
        XCTAssertEqual(injector.status().pressedButtons, [])
    }

    func testGetReportReturnsCurrentStateAndRejectsInvalidTypeIDAndShortBuffer() {
        let buffer = VirtualGamepadHIDReportBuffer()
        var state = VirtualGamepadReportState()
        state.buttons = [.east, .dpadUp]
        buffer.update(state.reportBytes)
        var bytes = [UInt8](repeating: 0xEE, count: 16)
        var length = bytes.count
        func request(_ type: IOHIDReportType, _ id: UInt32) -> IOReturn {
            bytes.withUnsafeMutableBufferPointer { buffer.copyInputReport(type: type, reportID: id, destination: $0.baseAddress!, length: &length) }
        }
        XCTAssertEqual(request(kIOHIDReportTypeInput, 1), kIOReturnSuccess)
        XCTAssertEqual(length, 10)
        XCTAssertEqual(Array(bytes.prefix(10)), [1, 2, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(bytes[10], 0xEE)
        XCTAssertEqual(request(kIOHIDReportTypeFeature, 1), kIOReturnUnsupported)
        XCTAssertEqual(request(kIOHIDReportTypeInput, 2), kIOReturnUnsupported)
        bytes = [UInt8](repeating: 0xEE, count: 16); length = 9
        XCTAssertEqual(request(kIOHIDReportTypeInput, 1), kIOReturnNoSpace)
        XCTAssertEqual(length, 10)
        XCTAssertEqual(bytes, [UInt8](repeating: 0xEE, count: 16))
        length = -1
        XCTAssertEqual(request(kIOHIDReportTypeInput, 1), kIOReturnBadArgument)
        XCTAssertEqual(length, 0)
        XCTAssertEqual(bytes, [UInt8](repeating: 0xEE, count: 16))
    }

    private final class FakeDevice: VirtualGamepadHIDDevice {
        private let lock = NSLock()
        private var storedReports: [[UInt8]] = []
        private var results: [IOReturn]
        var onCancelled: (() -> Void)?
        init(results: [IOReturn] = []) { self.results = results }
        var reports: [[UInt8]] {
            lock.lock(); defer { lock.unlock() }
            return storedReports
        }
        func sendReport(_ bytes: [UInt8]) -> IOReturn {
            lock.lock(); defer { lock.unlock() }
            storedReports.append(bytes)
            return results.isEmpty ? kIOReturnSuccess : results.removeFirst()
        }
        func cancel() { onCancelled?() }
    }
}
