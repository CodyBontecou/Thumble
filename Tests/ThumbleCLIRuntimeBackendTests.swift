import Foundation
import XCTest

final class ThumbleCLIRuntimeBackendTests: XCTestCase {
    private let id = UUID(uuidString: "AAAAAAAA-BBBB-5CCC-8DDD-EEEEEEEEEEEE")!
    private let instance = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!

    func testRequestIsSeparateTaggedBoundedEnvelope() throws {
        let data = try ThumbleCLIRuntimeBackend.requestFrame(.tapControl("jump"), invocationID: id)
        XCTAssertEqual(String(decoding: data, as: UTF8.self),
            "{\"invocationID\":\"AAAAAAAA-BBBB-5CCC-8DDD-EEEEEEEEEEEE\",\"runtimeCommand\":{\"controlID\":\"jump\",\"type\":\"tap-control\"},\"schemaVersion\":1}\n")
        for control in ["", String(repeating: "x", count: 257), "jump\n", "../raw"] {
            XCTAssertThrowsError(try ThumbleCLIRuntimeBackend.requestFrame(.tapControl(control), invocationID: id))
        }
    }

    func testReceiverOwnedHeldTestsUseTypedBoundedControlRequests() throws {
        for state in [ButtonPressState.down, .up] {
            let data = try ThumbleCLIRuntimeBackend.requestFrame(.testControl("button:jump", state), invocationID: id)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let command = try XCTUnwrap(object["runtimeCommand"] as? [String: String])
            XCTAssertEqual(command, ["type": "test-control", "controlID": "button:jump", "state": state.rawValue])
        }
        XCTAssertThrowsError(try ThumbleCLIRuntimeBackend.requestFrame(.testControl("../raw", .down), invocationID: id))
    }

    func testStrictResponseFramingBoundsAndCorrelation() throws {
        let good = frame(owner: "rust", response: "{\"ok\":true,\"released\":true}")
        XCTAssertEqual(try ThumbleCLIRuntimeBackend.decodeResponse(good, invocationID: id).owner, .rust)
        for bad in [Data(good.dropLast()), good + good, Data(repeating: 32, count: 65537),
                    frame(owner: "offline"), frame(owner: "none", response: "{\"ok\":true}"),
                    Data(String(decoding: good, as: UTF8.self).replacingOccurrences(of: id.uuidString, with: instance.uuidString).utf8)] {
            XCTAssertThrowsError(try ThumbleCLIRuntimeBackend.decodeResponse(bad, invocationID: id))
        }
    }

    func testUnreachableRustNeverInvokesLegacyFallback() throws {
        var legacyCalled = false
        let backend = ThumbleCLIRuntimeBackend(transport: { _ in
            (1, self.frame(owner: "unreachable", ok: false, error: "authority_unreachable"))
        })
        XCTAssertThrowsError(try backend.route(.releaseAll, invocationID: id, legacyStatus: { _ in
            legacyCalled = true
            return Data()
        }, processIsLive: { _ in true }))
        XCTAssertFalse(legacyCalled)
    }

    func testLegacyRequiresCorrelatedFreshLivePIDAndInstance() throws {
        let backend = ThumbleCLIRuntimeBackend(transport: { _ in (0, self.frame(owner: "none")) })
        let now: Int64 = 10000
        func status(_ request: UUID, pid: Int = 42, updated: Int64 = 10000, nonce: String? = nil) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "updatedAt": updated, "runtimeProcessID": pid,
                "runtimeInstanceID": nonce ?? instance.uuidString,
                "runtimeStatusRequestID": request.uuidString
            ])
        }
        let route = try backend.route(.releaseAll, invocationID: id, legacyStatus: { try status($0) },
                                      processIsLive: { $0 == 42 }, now: now)
        guard case .legacy = route else { return XCTFail("Expected verified legacy route") }
        for data in [try status(instance), try status(id, updated: 1), try status(id, pid: 0), try status(id, nonce: "bad")] {
            XCTAssertThrowsError(try backend.route(.releaseAll, invocationID: id, legacyStatus: { _ in data },
                                                  processIsLive: { _ in true }, now: now))
        }
        XCTAssertThrowsError(try backend.route(.releaseAll, invocationID: id, legacyStatus: { try status($0) },
                                              processIsLive: { _ in false }, now: now))
        XCTAssertThrowsError(try backend.route(.releaseAll, invocationID: id, legacyStatus: { try status($0, updated: now + 2000) },
                                              processIsLive: { _ in true }, now: now))
    }

    func testRustRouteNeverReadsLegacyAndRequiresAcknowledgement() throws {
        var requests: [String] = []
        let backend = ThumbleCLIRuntimeBackend(transport: { request in
            requests.append(String(decoding: request, as: UTF8.self))
            return (0, self.frame(owner: "rust", response: "{\"ok\":true,\"released\":true}"))
        })
        let result = try backend.route(.releaseAll, invocationID: id, legacyStatus: { _ in
            XCTFail("Rust ownership must not consult legacy defaults")
            return Data()
        }, processIsLive: { _ in false })
        guard case .rust = result else { return XCTFail("Expected Rust route") }
        XCTAssertTrue(requests.last?.contains("release-all") == true)
    }

    func testAmbiguousLockMayOnlyUseVerifiedLegacyStatus() throws {
        let backend = ThumbleCLIRuntimeBackend(transport: { _ in
            (1, self.frame(owner: "unreachable", ok: false, error: "legacy_owner_possible"))
        })
        XCTAssertThrowsError(try backend.route(.tapControl("jump"), invocationID: id,
                                              legacyStatus: { _ in Data("{}".utf8) }, processIsLive: { _ in true }))
    }

    func testEnvelopeTypesAndUnexpectedFieldsFailClosed() throws {
        let good = String(decoding: frame(owner: "none"), as: UTF8.self)
        for text in [good.replacingOccurrences(of: "\"ok\":true", with: "\"ok\":1"),
                     good.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":true"),
                     good.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2"),
                     good.replacingOccurrences(of: "\"owner\":\"none\"", with: "\"owner\":\"none\",\"socketPath\":\"/tmp/evil\""),
                     good.replacingOccurrences(of: "\"owner\":\"none\"", with: "\"owner\":\"none\",\"owner\":\"none\""),
                     good.replacingOccurrences(of: "\"owner\":\"none\"", with: "\"owner\":\"none\",\"\\u006fwner\":\"none\"")] {
            XCTAssertThrowsError(try ThumbleCLIRuntimeBackend.decodeResponse(Data(text.utf8), invocationID: id))
        }
    }

    func testRustTapNeedsMatchingControlAcknowledgementAndNeverFallsBack() throws {
        let backend = ThumbleCLIRuntimeBackend(transport: { _ in
            (0, self.frame(owner: "rust", response: "{\"ok\":true,\"pressedControlID\":\"button:attack\"}"))
        })
        XCTAssertThrowsError(try backend.route(.tapControl("button:jump"), invocationID: id, legacyStatus: { _ in
            XCTFail("Mismatched Rust acknowledgement must never route legacy input")
            return Data()
        }, processIsLive: { _ in false }))
    }

    func testGamepadReadinessProjectionIsTypedAndRangeBounded() throws {
        func response(_ status: VirtualGamepadStatus) throws -> Data {
            let value = String(decoding: try JSONEncoder().encode(status), as: UTF8.self)
            return frame(owner: "rust", response: "{\"ok\":true,\"virtualGamepadStatus\":\(value)}")
        }
        let recording = try ThumbleCLIRuntimeBackend.decodeResponse(
            response(VirtualGamepadStatus(phase: .recording)), invocationID: id)
        XCTAssertEqual(recording.control?.virtualGamepadStatus?.phase, .recording)
        for invalid in [VirtualGamepadStatus(leftStickX: 2), VirtualGamepadStatus(leftTrigger: -0.1),
                        VirtualGamepadStatus(lastError: String(repeating: "x", count: 2049)),
                        VirtualGamepadStatus(pressedButtons: [.south, .south])] {
            XCTAssertThrowsError(try ThumbleCLIRuntimeBackend.decodeResponse(response(invalid), invocationID: id))
        }
    }

    func testExecutableValidationRejectsMissingBridgeBeforeLaunching() {
        XCTAssertThrowsError(try ThumbleCLIRuntimeBackend(executableURL:
            URL(fileURLWithPath: "/nonexistent-thumble-test/thumble-cli-bridge")))
    }

    private func frame(owner: String, ok: Bool = true, response: String? = nil, error: String? = nil) -> Data {
        var text = "{\"schemaVersion\":1,\"ok\":\(ok),\"invocationID\":\"\(id.uuidString)\",\"owner\":\"\(owner)\""
        if let response { text += ",\"response\":\(response)" }
        if let error { text += ",\"error\":{\"code\":\"\(error)\",\"message\":\"Unavailable\"}" }
        return Data((text + "}\n").utf8)
    }
}
