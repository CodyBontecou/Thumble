import Foundation
import XCTest

final class OwnedConfigurationDocumentTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent("Host/fixtures/owned-configuration/v1/\(name).json"))
    }
    func testSharedVersionFiveContractAndRejectedMutations() throws {
        let original = try JSONSerialization.jsonObject(with: fixture("document"))
        let matrix = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("cases")) as? [String: Any])
        for row in try XCTUnwrap(matrix["cases"] as? [[String: Any]]) {
            let value = mutate(original, path: try XCTUnwrap(row["path"] as? [Any]), row: row)
            let bytes = try JSONSerialization.data(withJSONObject: value)
            let accepted = (try? ThumbleOwnedConfigurationDocument(validating: bytes)) != nil
            XCTAssertEqual(accepted, row["allowed"] as? Bool, row["name"] as? String ?? "")
        }
    }
    private func mutate(_ value: Any, path: [Any], row: [String: Any]) -> Any {
        guard let first = path.first else { return value }
        if let index = first as? Int {
            var array = value as! [Any]
            array[index] = mutate(array[index], path: Array(path.dropFirst()), row: row)
            return array
        }
        let key = first as! String
        var object = value as! [String: Any]
        if path.count == 1 {
            if row["action"] as? String == "remove" { object.removeValue(forKey: key) }
            else { object[key] = row["value"] }
        } else { object[key] = mutate(object[key]!, path: Array(path.dropFirst()), row: row) }
        return object
    }
    func testExactSourceAndAllStatesSurviveNativeProjectionWithoutPackageLookup() throws {
        let original = try fixture("document")
        let document = try ThumbleOwnedConfigurationDocument(validating: original)
        XCTAssertEqual(document.originalData, original)
        let profile = try XCTUnwrap(document.projectedProfiles.first)
        XCTAssertEqual(document.projectedProfiles.count, 2)
        XCTAssertEqual(document.activeProfileID, profile.id)
        XCTAssertEqual(document.defaultProfileID, document.projectedProfiles.last?.id)
        XCTAssertNil(profile.skinReference)
        XCTAssertNil(profile.portraitCustomization)
        XCTAssertNil(profile.landscapeCustomization)
        for scheme in ThumbleSkinColorScheme.allCases {
            for action in ThumbleActionSet.allCases {
                let layout = profile.resolvedCustomization(for: .landscape, colorScheme: scheme, skinPackage: nil, actionSet: action)
                let element = try XCTUnwrap(layout.elements.first)
                XCTAssertEqual(layout.elements.map(\.id),profile.customization.elements.map(\.id))
                XCTAssertEqual(layout.elements.map(\.output),profile.customization.elements.map(\.output))
                XCTAssertEqual(layout.resolvedPresentation(for: layout.buttonCustomization(for: element.inputID), scheme: scheme == .dark ? .dark : .light).icon,
                    .text("\(scheme.rawValue)/\(action.rawValue)"))
                XCTAssertEqual(layout.assetLibrary.assets.first?.data, Data("fixture-image".utf8))
            }
        }
        var copy = document.projectedProfiles
        copy[0].name = "Changed projection"
        copy[0].appearanceBank = nil
        XCTAssertNotEqual(copy[0],document.projectedProfiles[0])
        XCTAssertEqual(document.originalData,original)
        XCTAssertEqual(ProfileFormatPolicy.supportedFormats,[4])
        XCTAssertThrowsError(try ThumbleKeypadConfigurationExport.validateImportBoundary(original))
    }
    func testDuplicateKeysInvalidUTF8AndExactDocumentLimit() throws {
        let original = try fixture("document")
        let text = try XCTUnwrap(String(data: original, encoding: .utf8))
        let duplicate = text.replacingOccurrences(of: "\"version\": 5", with: "\"version\": 5, \"version\": 4")
        XCTAssertThrowsError(try ThumbleOwnedConfigurationDocument(validating: Data(duplicate.utf8)))
        XCTAssertThrowsError(try ThumbleOwnedConfigurationDocument(validating: Data([255])))
        var maximum = original
        maximum.append(Data(repeating: 32, count: ThumbleOwnedConfigurationDocument.maximumBytes-original.count))
        XCTAssertEqual(try ThumbleOwnedConfigurationDocument(validating: maximum).originalData, maximum)
        maximum.append(32)
        XCTAssertThrowsError(try ThumbleOwnedConfigurationDocument(validating: maximum))
    }
}
