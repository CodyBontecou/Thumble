import Foundation
import XCTest

final class RustHostInteropTests: XCTestCase {
    private struct FixtureFile: Decodable {
        var schema: String
        var version: Int
        var vectors: [Fixture]
    }

    private struct Fixture: Decodable {
        var name: String
        var kind: String
        var hex: String?
        var message: ControllerMessage?
        var json: ControllerMessage?
    }

    func testRustHostWireFixturesMatchSwiftCodec() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Host/fixtures/wire/vectors.json")
        let fixtureFile = try JSONDecoder().decode(
            FixtureFile.self,
            from: Data(contentsOf: fixtureURL)
        )

        XCTAssertEqual(fixtureFile.schema, "com.codybontecou.pocketpad.wire-fixtures")
        XCTAssertEqual(fixtureFile.version, 1)

        for fixture in fixtureFile.vectors {
            switch fixture.kind {
            case "compact":
                let message = try XCTUnwrap(fixture.message, fixture.name)
                let expected = try Data(hexadecimal: XCTUnwrap(fixture.hex, fixture.name))
                XCTAssertEqual(
                    try ControllerWireCodec.encode(message, using: JSONEncoder()),
                    expected,
                    "\(fixture.name) encode mismatch"
                )
                let decoded = try ControllerWireCodec.decode(expected, using: JSONDecoder())
                assertEquivalent(decoded, message, fixture.name)

            case "json":
                let message = try XCTUnwrap(fixture.json, fixture.name)
                let encoded = try ControllerWireCodec.encode(message, using: JSONEncoder())
                XCTAssertEqual(encoded.first, UInt8(ascii: "{"), fixture.name)
                let decoded = try ControllerWireCodec.decode(encoded, using: JSONDecoder())
                assertEquivalent(decoded, message, fixture.name)

            case "rejected":
                let bytes = try Data(hexadecimal: XCTUnwrap(fixture.hex, fixture.name))
                XCTAssertThrowsError(try ControllerWireCodec.decode(bytes, using: JSONDecoder()), fixture.name)

            default:
                XCTFail("Unknown fixture kind \(fixture.kind) in \(fixture.name)")
            }
        }
    }

    func testRustMinimalProfileDecodesInCurrentSwiftModel() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Host/fixtures/state/minimal-profile.json")
        let profile = try JSONDecoder().decode(
            GamepadConfigurationProfile.self,
            from: Data(contentsOf: fixtureURL)
        )

        XCTAssertEqual(profile.id.uuidString, "00000000-0000-0000-0000-000000000201")
        XCTAssertEqual(profile.name, "Default")
        XCTAssertEqual(profile.orientationPreference, .automatic)
        XCTAssertEqual(profile.outputMode, .keyboard)
        XCTAssertEqual(profile.customization.elements.count, 10)
        XCTAssertEqual(profile.customization.elements.first?.defaultControlID, KeypadElementID.preset(1))
    }

    private func assertEquivalent(
        _ actual: ControllerMessage,
        _ expected: ControllerMessage,
        _ name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.type, expected.type, name, file: file, line: line)
        XCTAssertEqual(actual.button, expected.button, name, file: file, line: line)
        XCTAssertEqual(actual.elementID, expected.elementID, name, file: file, line: line)
        XCTAssertEqual(actual.elementPart, expected.elementPart, name, file: file, line: line)
        XCTAssertEqual(actual.state, expected.state, name, file: file, line: line)
        XCTAssertEqual(actual.timestamp, expected.timestamp, name, file: file, line: line)
        XCTAssertEqual(actual.clientName, expected.clientName, name, file: file, line: line)
        XCTAssertEqual(actual.inputProtocolVersion, expected.inputProtocolVersion, name, file: file, line: line)
        XCTAssertEqual(actual.inputGeneration, expected.inputGeneration, name, file: file, line: line)
        XCTAssertEqual(actual.inputSequence, expected.inputSequence, name, file: file, line: line)
        XCTAssertEqual(actual.pressIdentifier, expected.pressIdentifier, name, file: file, line: line)
        XCTAssertEqual(actual.clientDeviceInfo?.deviceName, expected.clientDeviceInfo?.deviceName, name, file: file, line: line)
    }
}

private extension Data {
    init(hexadecimal: String) throws {
        guard hexadecimal.count.isMultiple(of: 2) else {
            throw HexFixtureError.invalidLength
        }
        var result = Data(capacity: hexadecimal.count / 2)
        var index = hexadecimal.startIndex
        while index < hexadecimal.endIndex {
            let end = hexadecimal.index(index, offsetBy: 2)
            guard let byte = UInt8(hexadecimal[index..<end], radix: 16) else {
                throw HexFixtureError.invalidByte(String(hexadecimal[index..<end]))
            }
            result.append(byte)
            index = end
        }
        self = result
    }
}

private enum HexFixtureError: Error {
    case invalidLength
    case invalidByte(String)
}
