import CryptoKit
import Foundation
import XCTest

/// Native-generated semantic oracle shared by the retained peer implementations.
final class AppearanceEditOracleTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }
    private func source() throws -> GamepadConfigurationProfile {
        let data = try Data(contentsOf: root.appendingPathComponent("Host/fixtures/profile-resources/v1/fixture.json"))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var profile = try JSONDecoder().decodeUnique(GamepadConfigurationProfile.self,
            from: JSONSerialization.data(withJSONObject: XCTUnwrap(fields["pooledProfile"])))
        profile.launchTarget = nil
        let local = profile.customization
        let button = try XCTUnwrap(local.elements.first).inputID
        var variants: [GamepadAppearanceBank.Variant] = []
        for scheme in ThumbleSkinColorScheme.allCases {
            for action in ThumbleActionSet.allCases {
                var value = local
                let color = GamepadRGBAColor(red: scheme == .dark ? 0.1 : 0.8,
                    green: action == .base ? 0.2 : 0.6, blue: 0.3)
                var control = value.buttonCustomization(for: button)
                control.styleID = "shared"
                control.visualStyle = .init(normal: .init(fillStyle: .solid(color), shadowRadius: 1,
                    content: .init(icon: .text("\(scheme.rawValue)/\(action.rawValue)"), fontSize: 12)),
                    pressed: .init(fillStyle: .solid(color), shadowRadius: 3,
                        content: .init(fontSize: 24, pointing: .init(joystickRingColor: color))),
                    active: .init(opacity: 0.8), disabled: .init(opacity: 0.3))
                value.setButtonCustomization(control, for: button)
                value.styleLibrary = .init(styles: [
                    .init(id: "shared", name: "Shared", visualStyle: .init(normal: .init(fillStyle: .solid(color), strokeWidth: 1))),
                    .init(id: "second", name: "Second", visualStyle: .init(normal: .init(opacity: 0.5)))
                ])
                value.artworkLayers = [.init(id: "a", fillStyle: .solid(color)),
                    .init(id: "\(scheme.rawValue)-only", fillStyle: .solid(color)), .init(id: "b", fillStyle: .solid(color))]
                if scheme == .dark {
                    value.setControlBarItemCustomization(.init(visualStyle: .init(normal: .init(fillStyle: .solid(color)))), for: .settings)
                }
                variants.append(.init(colorScheme: scheme, actionSet: action, appearance: .init(value)))
            }
        }
        profile.appearanceBank = try .init(variants: variants)
        profile.customization = try XCTUnwrap(variants.first { $0.colorScheme == .light && $0.actionSet == .base }).appearance.applying(to: local)
        return profile
    }
    private func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
    private func editControl(_ layout: inout GamepadCustomization, _ edit: (inout GamepadButtonCustomization) -> Void) {
        let button = layout.elements[0].inputID
        var control = layout.buttonCustomization(for: button)
        edit(&control); layout.setButtonCustomization(control, for: button)
    }
    func testNativeEditOracleIsStableAndKeepsInputOwners() throws {
        let original = try source()
        var cases: [[String: Any]] = []
        func record(_ name: String, _ edit: (inout GamepadCustomization) -> Void) throws {
            var profile = original
            edit(&profile.customization)
            let bank = try XCTUnwrap(profile.appearanceBank)
            var resolutions: [[String: Any]] = []
            for variant in bank.variants {
                let value = bank.resolve(profile.customization, colorScheme: variant.colorScheme, actionSet: variant.actionSet)
                XCTAssertEqual(value.elements.map(\.id), profile.customization.elements.map(\.id))
                XCTAssertEqual(value.elements.map(\.output), profile.customization.elements.map(\.output))
                XCTAssertEqual(value.elements.map(\.partOutputs), profile.customization.elements.map(\.partOutputs))
                resolutions.append(["colorScheme": variant.colorScheme.rawValue, "actionSet": variant.actionSet.rawValue,
                    "expectedAppearance": try object(GamepadAppearanceSnapshot(value))])
            }
            cases.append(["name": name, "profile": try object(profile), "resolutions": resolutions])
        }
        try record("unchanged") { _ in }
        try record("nested-content-and-haptics") { layout in
            editControl(&layout) { value in
                value.visualStyle?.normal.shadowRadius = 9
                let icon = value.visualStyle?.normal.content?.icon
                value.visualStyle?.normal.content = .init(icon: icon, legend: "Edited", fontSize: 30)
                value.visualStyle?.pressed?.content = .init(legend: "Pressed edit", pointing: .init(trackpadFrameStrokeWidth: 4))
                value.hapticFeedback = .init(style: .heavy, intensity: 0.8, sharpness: 0.3, duration: 0.12)
                value.centerX = 0.73; value.isHidden = true
            }
        }
        try record("explicit-state-and-content-clears") { layout in
            editControl(&layout) { $0.visualStyle?.pressed = nil; $0.visualStyle?.normal.content = nil }
        }
        try record("new-style-and-direct-icon") { layout in
            editControl(&layout) { $0.styleID = "second"; $0.icon = .text("My icon") }
        }
        try record("scheme-fill-edit") { layout in
            editControl(&layout) { $0.darkFillStyle = .solid(.init(red: 0.3, green: 0.4, blue: 0.5)) }
        }
        try record("fill-storage-bookkeeping") { layout in
            editControl(&layout) { value in
                let fill = value.fillStyle
                value.fillStyle = nil; value.lightFillStyle = fill; value.darkFillStyle = fill
            }
        }
        try record("artwork-reorder-and-edit") { layout in
            layout.artworkLayers = [layout.artworkLayers[2], layout.artworkLayers[0], layout.artworkLayers[1]]
            layout.artworkLayers[0].rotationDegrees = 15
        }
        try record("remove-all-artwork") { $0.artworkLayers = [] }
        try record("style-library-edit-and-reorder") { layout in
            layout.styleLibrary.styles[0].name = "Renamed"
            layout.styleLibrary.styles[0].visualStyle.normal.content = .init(legend: "Token edit")
            layout.styleLibrary.styles.reverse()
        }
        try record("bar-paint-and-manual-geometry") { layout in
            layout.topBarActivationRegion.centerX = 0.7
            layout.topBarActivationRegion.hapticFeedback = .init(style: .light, intensity: 0.2)
            layout.setControlBarItemCustomization(.init(visualStyle: .init(normal: .init(content: .init(legend: "Settings")))) , for: .settings)
        }
        try record("asset-replacement") { $0.assetLibrary.assets[0].data = Data("edited-image".utf8) }
        for accent in GamepadAccentStyle.allCases {
            try record("clear-fill-" + accent.rawValue) { layout in
                layout.accentStyle = accent
                editControl(&layout) { value in
                    value.fillStyle = nil; value.fillColor = nil
                    value.lightFillStyle = nil; value.darkFillStyle = nil
                    value.lightFillColor = nil; value.darkFillColor = nil
                }
            }
        }
        try record("clear-direct-icon") { layout in editControl(&layout) { $0.icon = nil } }
        try record("remove-control") { layout in
            layout.elements = []; layout.customButtons = []; layout.buttonCustomizations = [:]; layout.labelOverrides = [:]
        }
        try record("add-control") { layout in
            var element = layout.elements[0]
            element.id = UUID(uuidString: "ca000000-0000-0000-0000-000000000099")!
            element.label = "Added"
            element.layout.centerX = 0.84
            layout.elements.append(element)
        }
        try record("new-style-with-pressed-only-edit") { layout in
            editControl(&layout) { $0.styleID = "second"; $0.visualStyle?.pressed?.shadowRadius = 11 }
        }
        let fixture: [String: Any] = ["schemaVersion": 1, "cases": cases]
        let generated = try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys])
        let output = root.appendingPathComponent("build/AppearanceEditOracle/fixture.json")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try generated.write(to: output, options: .atomic)
        let frozenURL = root.appendingPathComponent("Host/fixtures/appearance-edits/v1/fixture.json")
        if FileManager.default.fileExists(atPath: frozenURL.path) {
            XCTAssertEqual(SHA256.hash(data: generated), SHA256.hash(data: try Data(contentsOf: frozenURL)))
        } else { XCTFail("Freeze the generated native oracle from build/AppearanceEditOracle/fixture.json") }
    }
}
