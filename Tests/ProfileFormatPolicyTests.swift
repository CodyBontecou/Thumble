import Foundation
import XCTest

final class ProfileFormatPolicyTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Host/fixtures/profile-formats/v1.json"))) as? [String: Any])
    }
    func testSharedNegotiationAndFrameMatrix() throws {
        for row in try XCTUnwrap(fixture()["negotiations"] as? [[String: Any]]) {
            let required = try XCTUnwrap(row["required"] as? Int)
            let allowed = (try? ProfileFormatPolicy.negotiate(required: required, offered: row["offered"] as? [Int])) != nil
            XCTAssertEqual(allowed, row["allowed"] as? Bool, row["name"] as? String ?? "")
        }
        for row in try XCTUnwrap(fixture()["frames"] as? [[String: Any]]) {
            let data = try JSONSerialization.data(withJSONObject: XCTUnwrap(row["message"]))
            let allowed = (try? ProfileFormatPolicy.validateIncoming(data)) != nil
            XCTAssertEqual(allowed, row["allowed"] as? Bool, row["name"] as? String ?? "")
        }
        XCTAssertEqual(ProfileFormatPolicy.supportedFormats, [4], "Do not advertise v5 before migration and transport integration")
    }
    func testFutureUnknownProfileIsRejectedBeforeTypedDecodeAndDuplicateTagsNeverDowngrade() throws {
        for raw in [
            #"{"type":"gamepad_profiles","profileFormatVersion":5,"gamepadProfiles":[{"appearanceBank":{"schemaVersion":99}}]}"#,
            #"{"type":"gamepad_profiles","profileFormatVersion":5,"profileFormatVersion":4,"gamepadProfiles":[]}"#,
            #"{"type":"gamepad_profiles","gamepadProfiles":[{"profileFormatVersion":5,"profileFormatVersion":4}]}"#
        ] { XCTAssertThrowsError(try ProfileFormatPolicy.validateIncoming(Data(raw.utf8))) }
        let huge = ["type": "gamepad_profiles", "gamepadProfiles": Array(repeating: [:], count: 257)] as [String: Any]
        XCTAssertThrowsError(try ProfileFormatPolicy.validateIncoming(JSONSerialization.data(withJSONObject: huge)))
    }
    func testFutureSavedProfileFailsWithoutRewritingOriginalBytes() throws {
        let suite = "Thumble-ProfileFormats-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let profile = GamepadConfigurationProfile(name: "Keep original", primaryCustomization: .defaultValue)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        raw["profileFormatVersion"] = 5
        let data = try JSONSerialization.data(withJSONObject: ["profiles": [raw], "activeProfileID": profile.id.uuidString, "defaultProfileID": profile.id.uuidString], options: [.sortedKeys])
        defaults.set(data, forKey: GamepadConfigurationProfilePersistence.defaultsKey)
        XCTAssertThrowsError(try GamepadConfigurationProfilePersistence.load(activeCustomization: .defaultValue, defaults: defaults))
        XCTAssertEqual(defaults.data(forKey: GamepadConfigurationProfilePersistence.defaultsKey), data)
    }
    func testFormatMetadataCannotDisappearIntoCompactInputAndOrdinaryInputStaysCompact() throws {
        let input = ControllerMessage(type: .button, button: .preset(1), state: .down,
            inputProtocolVersion: 3, inputGeneration: 1, inputSequence: 1, pressIdentifier: 1)
        let bytes = try ControllerWireCodec.encode(input, using: JSONEncoder())
        XCTAssertEqual(bytes.count, 56)
        XCTAssertNoThrow(try ProfileFormatPolicy.validateIncoming(bytes))
        var tagged = input
        tagged.supportedProfileFormats = [4]
        tagged.profileFormatVersion = 4
        let json = try ControllerWireCodec.encode(tagged, using: JSONEncoder())
        XCTAssertEqual(json.first, UInt8(ascii: "{"))
        let decoded = try ControllerWireCodec.decode(json, using: JSONDecoder())
        XCTAssertEqual(decoded.supportedProfileFormats, [4]); XCTAssertEqual(decoded.profileFormatVersion, 4)
    }
}
