import CryptoKit
import Foundation
import XCTest

final class PortableProfileArtifactTests: XCTestCase {
    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Host/fixtures/profile-artifact/\(name)")
    }

    private func fixtureData() throws -> Data {
        try Data(contentsOf: fixtureURL("v1.json"))
    }

    func testRustGoldenCanonicalBytesAndHashMatchExactly() throws {
        let artifact = try PortableProfileArtifact(validating: fixtureData())
        var expectedCanonical = try Data(contentsOf: fixtureURL("v1.canonical.json"))
        if expectedCanonical.last == 0x0A { expectedCanonical.removeLast() }
        let expectedHash = try String(contentsOf: fixtureURL("v1.sha256"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(artifact.canonicalContent, expectedCanonical)
        XCTAssertEqual(artifact.contentHash.value, expectedHash)
        XCTAssertEqual(artifact.rawData, try fixtureData())
        XCTAssertEqual(artifact.profileSummaries.count, 1)
        XCTAssertEqual(artifact.profiles.first?.id, artifact.profileSummaries.first?.id)
        XCTAssertEqual(artifact.profiles.first?.name, "未来 Pad 🎛️")
        XCTAssertNil(artifact.defaultProfileID)
    }

    func testCanonicalizerSortsIntegerLikeObjectKeysByUTF16CodeUnits() throws {
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixtureData()) as? [String: Any]
        )
        root["futureNumericKeys"] = ["2": "two", "10": "ten"]

        var expected = try String(
            contentsOf: fixtureURL("v1.canonical.json"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        expected = expected.replacingOccurrences(
            of: "\"futureTopLevel\":",
            with: "\"futureNumericKeys\":{\"10\":\"ten\",\"2\":\"two\"},\"futureTopLevel\":"
        )
        let digest = SHA256.hash(data: Data(expected.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        var hash = try XCTUnwrap(root["contentHash"] as? [String: Any])
        hash["value"] = digest
        root["contentHash"] = hash
        let encoded = try JSONSerialization.data(withJSONObject: root)

        let artifact = try PortableProfileArtifact(validating: encoded)
        XCTAssertEqual(String(decoding: artifact.canonicalContent, as: UTF8.self), expected)
        XCTAssertTrue(expected.contains("\"futureNumericKeys\":{\"10\":\"ten\",\"2\":\"two\"}"))
    }

    func testTamperFailsBeforeTypedAdoption() throws {
        let source = String(decoding: try fixtureData(), as: UTF8.self)
        let tampered = source.replacingOccurrences(of: "未来 Pad 🎛️", with: "Tampered")
        XCTAssertThrowsError(try PortableProfileArtifact(validating: Data(tampered.utf8))) {
            XCTAssertEqual($0 as? PortableProfileArtifactError, .contentHashMismatch)
        }
    }

    func testRejectsOversizeBeforeParseAndStrictUTF8BOMAndTrailingGarbage() throws {
        XCTAssertEqual(
            XCTAssertThrowsPortable(Data(count: PortableProfileArtifact.maximumBytes + 1)),
            .tooLarge
        )
        XCTAssertEqual(XCTAssertThrowsPortable(Data([0xFF])), .invalidUTF8)
        XCTAssertEqual(XCTAssertThrowsPortable(Data([0xEF, 0xBB, 0xBF, 0x7B, 0x7D])), .byteOrderMarkForbidden)
        let trailing = try fixtureData() + Data("x".utf8)
        guard case .trailingGarbage = XCTAssertThrowsPortable(trailing) else {
            return XCTFail("Expected trailing-garbage rejection")
        }
    }

    func testScannerRejectsDecodedDuplicateKeysEscapesSurrogatesControlsAndUnsafeIntegers() throws {
        let vectors: [(Data, (PortableProfileArtifactError) -> Bool)] = [
            (Data("{\"a\":1,\"\\u0061\":2}".utf8), { if case .duplicateObjectKey = $0 { true } else { false } }),
            (Data("{\"a\":\"\\x20\"}".utf8), { if case .malformedEscape = $0 { true } else { false } }),
            (Data("{\"a\":\"\\uD800\"}".utf8), { if case .loneSurrogate = $0 { true } else { false } }),
            (Data([0x7B, 0x22, 0x61, 0x22, 0x3A, 0x22, 0x01, 0x22, 0x7D]), { if case .unescapedControlCharacter = $0 { true } else { false } }),
            (Data("{\"a\":9007199254740992}".utf8), { if case .integerOutOfRange = $0 { true } else { false } }),
            (Data("{\"a\":-9007199254740992}".utf8), { if case .integerOutOfRange = $0 { true } else { false } }),
            (Data("{\"a\":1e400}".utf8), { if case .invalidNumber = $0 { true } else { false } }),
        ]
        for (data, matches) in vectors {
            let error = XCTAssertThrowsPortable(data)
            XCTAssertTrue(matches(error), "Unexpected error: \(error)")
        }
    }

    func testScannerRejectsDepthEntryKeyAndDecodedStringBounds() {
        let deep = Data((String(repeating: "[", count: 65) + "0" + String(repeating: "]", count: 65)).utf8)
        guard case .depthExceeded = XCTAssertThrowsPortable(deep) else { return XCTFail("depth") }

        let entries = (0...4096).map { "\"k\($0)\":0" }.joined(separator: ",")
        guard case .containerTooLarge = XCTAssertThrowsPortable(Data("{\(entries)}".utf8)) else { return XCTFail("entries") }

        let key = String(repeating: "k", count: 257)
        guard case .keyTooLarge = XCTAssertThrowsPortable(Data("{\"\(key)\":0}".utf8)) else { return XCTFail("key") }

        let string = String(repeating: "s", count: 256 * 1024 + 1)
        guard case .stringTooLarge = XCTAssertThrowsPortable(Data("{\"a\":\"\(string)\"}".utf8)) else { return XCTFail("string") }
    }

    func testReferencesBindingShapesForbiddenFieldsAndTypedFailuresFailClosed() throws {
        let fixture = String(decoding: try fixtureData(), as: UTF8.self)
        let missingActive = fixture.replacingOccurrences(
            of: "\"activeProfileID\": \"00000000-0000-0000-0000-000000000201\"",
            with: "\"activeProfileID\": \"00000000-0000-0000-0000-000000000999\""
        )
        XCTAssertEqual(XCTAssertThrowsPortable(Data(missingActive.utf8)), .activeProfileMissing)

        let launchTarget = fixture.replacingOccurrences(
            of: "\"updatedAt\": 42",
            with: "\"launchTarget\": null, \"updatedAt\": 42"
        )
        XCTAssertEqual(XCTAssertThrowsPortable(Data(launchTarget.utf8)), .launchTargetForbidden)

        let forbidden = fixture.replacingOccurrences(
            of: "\"futureProfileField\": {",
            with: "\"futureProfileField\": { \"shareURL\": \"https://invalid.example\","
        )
        XCTAssertEqual(XCTAssertThrowsPortable(Data(forbidden.utf8)), .forbiddenField)

        let malformedBinding = fixture.replacingOccurrences(of: "\"keyCode\": 12", with: "\"keyCode\": \"12\"")
        XCTAssertEqual(XCTAssertThrowsPortable(Data(malformedBinding.utf8)), .invalidBindingMap)
    }

    func testWrapperInlineSizeBudget() {
        XCTAssertLessThanOrEqual(MemoryLayout<PortableProfileArtifact>.size, 64)
    }

    private func XCTAssertThrowsPortable(
        _ data: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> PortableProfileArtifactError {
        do {
            _ = try PortableProfileArtifact(validating: data)
            XCTFail("Expected portable artifact rejection", file: file, line: line)
            return .invalidJSON
        } catch let error as PortableProfileArtifactError {
            return error
        } catch {
            XCTFail("Unexpected error type: \(error)", file: file, line: line)
            return .invalidJSON
        }
    }
}
