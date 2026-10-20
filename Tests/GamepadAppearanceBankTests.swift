import SwiftUI
import XCTest

final class GamepadAppearanceBankTests: XCTestCase {
    private func makeCandidate() throws -> GamepadConfigurationProfile {
        let original = GamepadControllerTemplate.arcadeStick.makeProfile().customization(for: .landscape)
        let button = try XCTUnwrap(original.elements.first).inputID
        var variants: [GamepadAppearanceBank.Variant] = []
        for scheme in ThumbleSkinColorScheme.allCases {
            for action in ThumbleActionSet.allCases {
                var layout = original
                let color = GamepadRGBAColor(red: scheme == .dark ? 0.1 : 0.8,
                    green: action == .base ? 0.2 : 0.6, blue: 0.3)
                var control = layout.buttonCustomization(for: button)
                control.styleID = "shared"
                control.visualStyle = .init(normal: .init(fillStyle: .solid(color), shadowRadius: 1,
                    content: .init(icon: .text("\(scheme.rawValue)/\(action.rawValue)"), fontSize: 12)),
                    pressed: .init(fillStyle: .solid(color), shadowRadius: 3),
                    active: .init(opacity: 0.8), disabled: .init(opacity: 0.3))
                layout.setButtonCustomization(control, for: button)
                if scheme == .dark {
                    layout.setControlBarItemCustomization(.init(visualStyle: .init(normal: .init(fillStyle: .solid(color)))), for: .settings)
                }
                layout.styleLibrary = .init(styles: [GamepadStyleToken(id: "shared", name: "Shared",
                    visualStyle: .init(normal: .init(fillStyle: .solid(color), strokeWidth: 1)))])
                layout.artworkLayers = [
                    .init(id: "shared-art", fillStyle: .solid(color)),
                    .init(id: "\(scheme.rawValue)-only-art", fillStyle: .solid(color))
                ]
                variants.append(.init(colorScheme: scheme, actionSet: action, appearance: .init(layout)))
            }
        }
        let bank = try GamepadAppearanceBank(variants: variants)
        let light = try XCTUnwrap(variants.first { $0.colorScheme == .light && $0.actionSet == .base })
        var profile = GamepadConfigurationProfile(id: UUID(uuidString: "ef000000-0000-0000-0000-000000000001")!,
            name: "Owned appearance", primaryCustomization: light.appearance.applying(to: original), updatedAt: 100)
        profile.appearanceBank = bank
        return profile
    }

    private func roundTrip(_ profile: GamepadConfigurationProfile) throws -> GamepadConfigurationProfile {
        try JSONDecoder().decodeUnique(GamepadConfigurationProfile.self, from: JSONEncoder().encode(profile))
    }

    private func resolve(_ profile: GamepadConfigurationProfile, _ variant: GamepadAppearanceBank.Variant) -> GamepadCustomization {
        profile.resolvedCustomization(for: .landscape, colorScheme: variant.colorScheme,
            skinPackage: nil, actionSet: variant.actionSet)
    }

    func testOwnedOfflineRecoveryRetainsAllStatesAfterHostDeletesProfile() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        struct Fixture: Decodable { let pooledProfile: GamepadConfigurationProfile }
        let fixture = try Data(contentsOf: root.appendingPathComponent("Host/fixtures/profile-resources/v1/fixture.json"))
        var profile = try JSONDecoder().decodeUnique(Fixture.self, from: fixture).pooledProfile
        let saved = profile
        let edit = PendingKeypadLayoutEdit(profileID: profile.id, orientation: .landscape,
            customization: profile.customization, serverID: "trusted-host", updatedAt: 101, recoveryProfile: profile)
        let bytes = try JSONEncoder().encode(edit)
        let restored = try JSONDecoder().decodeUnique(PendingKeypadLayoutEdit.self, from: bytes)
        profile.name = "Later mutation"
        profile.appearanceBank = nil
        XCTAssertEqual(restored.recoveryProfile?.profile, saved)
        let result = PendingKeypadLayoutReconciler.reconcile(incomingProfiles: [], pendingEdits: [restored], authoritativeServerID: "trusted-host")
        let recovered = try XCTUnwrap(result.profiles.first)
        XCTAssertEqual(recovered.id, saved.id)
        XCTAssertEqual(recovered.name, saved.name)
        XCTAssertEqual(recovered.updatedAt, max(saved.updatedAt, restored.updatedAt))
        XCTAssertEqual(recovered.appearanceBank, saved.appearanceBank)
        for variant in try XCTUnwrap(saved.appearanceBank).variants {
            XCTAssertEqual(resolve(recovered, variant), resolve(saved, variant))
        }
        XCTAssertEqual(result.remainingEdits.count, 1)
        XCTAssertEqual(result.editsToUpload.count, 1)
        let unrelated = PendingKeypadLayoutReconciler.reconcile(incomingProfiles: [], pendingEdits: [restored], authoritativeServerID: "different-host")
        XCTAssertTrue(unrelated.profiles.isEmpty)
        XCTAssertTrue(unrelated.editsToUpload.isEmpty)
        XCTAssertEqual(unrelated.remainingEdits, [restored])
    }

    func testPendingOwnedRecoveryRejectsWrongOwnerAndPreservesJournalBytes() throws {
        let profile = try makeCandidate()
        let edit = PendingKeypadLayoutEdit(profileID: profile.id, orientation: .landscape,
            customization: profile.customization, serverID: "trusted", updatedAt: 1, recoveryProfile: profile)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(edit)) as? [String: Any])
        raw["profileID"] = UUID().uuidString
        let bytes = try JSONSerialization.data(withJSONObject: [raw])
        let suite = "Thumble-OwnedRecovery-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(bytes, forKey: PendingKeypadLayoutPersistence.defaultsKey)
        XCTAssertThrowsError(try PendingKeypadLayoutPersistence.load(defaults: defaults))
        PendingKeypadLayoutPersistence.save([], defaults: defaults)
        XCTAssertEqual(defaults.data(forKey: PendingKeypadLayoutPersistence.defaultsKey), bytes)
    }

    func testProfileCodecAndPackageFreeResolutionKeepAllEightStates() throws {
        let original = try makeCandidate()
        let restored = try roundTrip(original)
        XCTAssertEqual(original, restored)
        XCTAssertNil(restored.skinReference)
        let bank = try XCTUnwrap(restored.appearanceBank)
        for variant in bank.variants {
            let expected = variant.appearance.applying(to: original.customization)
            XCTAssertEqual(resolve(restored, variant), expected)
        }
    }

    func testNestedEditsPreserveOtherStatesIconsAndHapticsAfterReload() throws {
        var profile = try makeCandidate()
        let bank = try XCTUnwrap(profile.appearanceBank)
        var local = profile.customization
        let button = try XCTUnwrap(local.elements.first).inputID
        var control = local.buttonCustomization(for: button)
        var style = try XCTUnwrap(control.visualStyle)
        style.normal.shadowRadius = 9
        style.normal.content = .init(icon: style.normal.content?.icon, legend: "My legend", fontSize: 30)
        style.pressed?.shadowRadius = 12
        control.visualStyle = style
        control.hapticFeedback = .init(style: .heavy, intensity: 0.8, sharpness: 0.3, duration: 0.12)
        local.setButtonCustomization(control, for: button)
        local.setPosition(CGPoint(x: 0.73, y: 0.64), for: .builtin(button))
        profile.setCustomization(local, for: .landscape)
        profile = try roundTrip(profile)
        for variant in bank.variants {
            let result = resolve(profile, variant)
            let expected = variant.appearance.applying(to: local).buttonCustomization(for: button)
            let actual = result.buttonCustomization(for: button)
            XCTAssertEqual(actual.visualStyle?.normal.fillStyle, expected.visualStyle?.normal.fillStyle)
            XCTAssertEqual(actual.visualStyle?.normal.content?.icon, expected.visualStyle?.normal.content?.icon)
            XCTAssertEqual(actual.visualStyle?.normal.content?.fontSize, 30)
            XCTAssertEqual(actual.visualStyle?.normal.content?.legend, "My legend")
            XCTAssertEqual(actual.visualStyle?.normal.shadowRadius, 9)
            XCTAssertEqual(actual.visualStyle?.pressed?.fillStyle, expected.visualStyle?.pressed?.fillStyle)
            XCTAssertEqual(actual.visualStyle?.pressed?.shadowRadius, 12)
            XCTAssertEqual(actual.hapticFeedback, control.hapticFeedback)
            XCTAssertEqual(actual.centerX, 0.73)
            XCTAssertEqual(actual.centerY, 0.64)
            XCTAssertEqual(result.elements.map(\.output), local.elements.map(\.output))
            XCTAssertEqual(result.elements.map(\.partOutputs), local.elements.map(\.partOutputs))
            let presentation = result.resolvedPresentation(for: actual, scheme: variant.colorScheme == .dark ? .dark : .light)
            XCTAssertEqual(presentation.content?.fontSize, 30)
            XCTAssertEqual(presentation.fillStyle, expected.visualStyle?.normal.fillStyle)
        }
    }

    func testIntentionalStateClearAndReusableStyleSelectionRemainVisible() throws {
        var profile = try makeCandidate()
        let button = try XCTUnwrap(profile.customization.elements.first).inputID
        var local = profile.customization
        var control = local.buttonCustomization(for: button)
        control.visualStyle?.pressed = nil
        local.setButtonCustomization(control, for: button)
        profile.customization = local
        for variant in try XCTUnwrap(profile.appearanceBank).variants {
            XCTAssertNil(resolve(profile, variant).buttonCustomization(for: button).visualStyle?.pressed)
        }
        let fill = GamepadFillStyle.solid(GamepadRGBAColor(red: 0.1, green: 0.9, blue: 0.2))
        local.styleLibrary.styles.append(.init(id: "chosen", name: "Chosen", visualStyle: .init(normal: .init(fillStyle: fill))))
        control.styleID = "chosen"
        local.setButtonCustomization(control, for: button)
        profile.customization = local
        profile = try roundTrip(profile)
        for variant in try XCTUnwrap(profile.appearanceBank).variants {
            let result = resolve(profile, variant)
            let actual = result.buttonCustomization(for: button)
            XCTAssertNil(actual.visualStyle)
            XCTAssertEqual(actual.styleID, "chosen")
            XCTAssertEqual(result.resolvedPresentation(for: actual, scheme: .dark).fillStyle, fill)
        }
        control.visualStyle?.normal.shadowRadius = 13
        local.setButtonCustomization(control, for: button)
        profile.customization = local
        for variant in try XCTUnwrap(profile.appearanceBank).variants {
            let result = resolve(profile, variant)
            let actual = result.buttonCustomization(for: button)
            XCTAssertEqual(actual.visualStyle?.normal.shadowRadius, 13)
            XCTAssertEqual(result.resolvedPresentation(for: actual, scheme: .dark).fillStyle, fill)
        }
    }

    func testDirectFillAndIconEditsAreNotHiddenByInheritedInlinePaint() throws {
        var profile = try makeCandidate()
        var local = profile.customization
        let button = try XCTUnwrap(local.elements.first).inputID
        var control = local.buttonCustomization(for: button)
        let editedFill = GamepadRGBAColor(red: 0.9, green: 0.4, blue: 0.7)
        control.lightFillColor = editedFill
        control.icon = .text("My icon")
        local.setButtonCustomization(control, for: button)
        profile.customization = local
        for variant in try XCTUnwrap(profile.appearanceBank).variants {
            let result = resolve(profile, variant)
            let actual = result.buttonCustomization(for: button)
            for state in GamepadControlPresentationState.allCases {
                let presentation = result.resolvedPresentation(for: actual, state: state,
                    scheme: variant.colorScheme == .dark ? .dark : .light)
                XCTAssertEqual(presentation.content?.icon, .text("My icon"))
                if state == .normal && variant.colorScheme == .light { XCTAssertEqual(presentation.fillStyle, .solid(editedFill)) }
            }
            if variant.colorScheme == .dark {
                let expected = variant.appearance.applying(to: local).buttonCustomization(for: button)
                XCTAssertEqual(actual.visualStyle?.normal.fillStyle, expected.visualStyle?.normal.fillStyle)
            }
        }
    }

    func testFirstControlBarEditKeepsTheOtherSchemesMaterial() throws {
        var profile = try makeCandidate()
        var local = profile.customization
        var appearance = local.controlBarItemCustomization(for: .settings)
        appearance.shadowStrength = 0.4
        local.setControlBarItemCustomization(appearance, for: .settings)
        profile.customization = local
        for variant in try XCTUnwrap(profile.appearanceBank).variants {
            let result = resolve(profile, variant)
            let actual = result.controlBarItemCustomization(for: .settings)
            let expected = variant.appearance.applying(to: local).controlBarItemCustomization(for: .settings)
            XCTAssertEqual(actual.shadowStrength, 0.4)
            XCTAssertEqual(actual.visualStyle?.normal.fillStyle, expected.visualStyle?.normal.fillStyle)
        }
    }

    func testNewReusableStyleKeepsItsChosenLibraryPositionAcrossStates() throws {
        var profile = try makeCandidate()
        var local = profile.customization
        local.styleLibrary.styles.insert(.init(id: "first", name: "First", visualStyle: .init(normal: .init(strokeWidth: 3))), at: 0)
        profile.customization = local
        for variant in try XCTUnwrap(profile.appearanceBank).variants {
            XCTAssertEqual(resolve(profile, variant).styleLibrary.styles.map(\.id), ["first", "shared"])
        }
    }

    func testSchemeStorageBookkeepingDoesNotOverwriteTheOtherSchemesPaint() throws {
        var profile = try makeCandidate()
        let button = try XCTUnwrap(profile.customization.elements.first).inputID
        let global = GamepadFillStyle.solid(GamepadRGBAColor(red: 0.2, green: 0.7, blue: 0.9))
        let variants = try XCTUnwrap(profile.appearanceBank).variants.map { variant in
            var layout = variant.appearance.applying(to: profile.customization)
            var control = layout.buttonCustomization(for: button)
            control.fillStyle = global
            layout.setButtonCustomization(control, for: button)
            return GamepadAppearanceBank.Variant(colorScheme: variant.colorScheme,
                actionSet: variant.actionSet, appearance: .init(layout))
        }
        profile.appearanceBank = try .init(variants: variants)
        let reference = try XCTUnwrap(variants.first { $0.colorScheme == .light && $0.actionSet == .base })
        profile.customization = reference.appearance.applying(to: profile.customization)
        var local = profile.customization
        var control = local.buttonCustomization(for: button)
        control.fillStyle = nil
        control.darkFillStyle = global
        control.lightFillColor = .init(red: 1, green: 0, blue: 0)
        local.setButtonCustomization(control, for: button)
        profile.customization = local
        for variant in variants where variant.colorScheme == .dark {
            let actual = resolve(profile, variant).buttonCustomization(for: button)
            let expected = variant.appearance.applying(to: local).buttonCustomization(for: button)
            XCTAssertEqual(actual.visualStyle?.normal.fillStyle, expected.visualStyle?.normal.fillStyle)
        }
    }

    func testPointingPaintEditKeepsUnchangedBankColorsAndAnalogOutputs() throws {
        var profile = try makeCandidate()
        let joystick = try XCTUnwrap(profile.customization.elements.first { $0.kind == .joystick }).inputID
        let variants = try XCTUnwrap(profile.appearanceBank).variants.map { variant in
            var layout = variant.appearance.applying(to: profile.customization)
            let color = GamepadRGBAColor(red: variant.colorScheme == .dark ? 0.2 : 0.8, green: 0.4, blue: 0.3)
            let index = layout.customButtons.firstIndex { $0.inputID == joystick }!
            layout.customButtons[index].layout.visualStyle = .init(normal: .init(content: .init(pointing:
                .init(joystickRingColor: color, joystickRingStrokeWidth: 1))))
            layout.normalizeInPlace()
            return GamepadAppearanceBank.Variant(colorScheme: variant.colorScheme,
                actionSet: variant.actionSet, appearance: .init(layout))
        }
        profile.appearanceBank = try .init(variants: variants)
        let reference = try XCTUnwrap(variants.first { $0.colorScheme == .light && $0.actionSet == .base })
        var local = reference.appearance.applying(to: profile.customization)
        let index = try XCTUnwrap(local.customButtons.firstIndex { $0.inputID == joystick })
        let color = local.customButtons[index].layout.visualStyle?.normal.content?.pointing?.joystickRingColor
        local.customButtons[index].layout.visualStyle?.normal.content = .init(pointing:
            .init(joystickRingColor: color, joystickRingStrokeWidth: 7))
        local.normalizeInPlace()
        profile.customization = local
        for variant in variants {
            let result = resolve(profile, variant)
            let expected = variant.appearance.applying(to: local)
            let actualPaint = result.customButtons[index].layout.visualStyle?.normal.content?.pointing
            XCTAssertEqual(actualPaint?.joystickRingStrokeWidth, 7)
            XCTAssertEqual(actualPaint?.joystickRingColor,
                expected.customButtons[index].layout.visualStyle?.normal.content?.pointing?.joystickRingColor)
            XCTAssertEqual(result.elements.map(\.partOutputs), local.elements.map(\.partOutputs))
        }
    }

    func testPhoneMoveDeleteUndoCancelAndOfflineSnapshotDoNotBakeRenderedBank() throws {
        var profile = try makeCandidate()
        let bank = try XCTUnwrap(profile.appearanceBank)
        let canonical = profile.customization
        let displayed = profile.resolvedCustomization(for: .landscape, colorScheme: .dark,
            skinPackage: nil, actionSet: .bothTriggers)
        let entry = profile.canonicalPhoneLayoutEdit(displayed, orientation: .landscape)
        XCTAssertEqual(entry, canonical)
        let session = GamepadLayoutEditSession(entrySnapshot: entry)
        let element = try XCTUnwrap(displayed.elements.first)
        var moved = displayed
        moved.setPosition(CGPoint(x: 0.78, y: 0.52), for: .builtin(element.inputID))
        let saved = profile.canonicalPhoneLayoutEdit(moved, orientation: .landscape)
        XCTAssertTrue(session.commit(saved))
        profile.setCustomization(saved, for: .landscape)
        let pending = PendingKeypadLayoutEdit(profileID: profile.id, orientation: .landscape,
            customization: saved, serverID: "trusted-host")
        let reloaded = try JSONDecoder().decodeUnique(PendingKeypadLayoutEdit.self, from: JSONEncoder().encode(pending))
        XCTAssertEqual(reloaded.customization, saved)
        XCTAssertEqual(reloaded.serverID, "trusted-host")
        var deleted = profile.resolvedCustomization(for: .landscape, colorScheme: .dark,
            skinPackage: nil, actionSet: .bothTriggers)
        deleted.elements.removeAll { $0.id == element.id }
        deleted.customButtons.removeAll { $0.id == element.id }
        deleted.buttonCustomizations[element.inputID] = nil
        deleted = profile.canonicalPhoneLayoutEdit(deleted, orientation: .landscape)
        XCTAssertTrue(session.commit(deleted))
        profile.setCustomization(deleted, for: .landscape)
        XCTAssertFalse(profile.customization.elements.contains { $0.id == element.id })
        XCTAssertTrue(session.undo { profile.setCustomization($0, for: .landscape) })
        for variant in bank.variants {
            let result = resolve(profile, variant)
            let expected = variant.appearance.applying(to: saved)
            XCTAssertEqual(result, expected)
        }
        session.resetToEntry { profile.setCustomization($0, for: .landscape) }
        XCTAssertEqual(profile.customization, canonical)
        XCTAssertEqual(profile.appearanceBank, bank)
    }

    func testStyleAndArtworkEditsMatchIDsAndRetainVariantOnlyContent() throws {
        var profile = try makeCandidate()
        var local = profile.customization
        local.styleLibrary.styles[0].visualStyle.normal.strokeWidth = 6
        local.styleLibrary.styles[0].name = "My reusable style"
        let art = try XCTUnwrap(local.artworkLayers.firstIndex { $0.id == "shared-art" })
        local.artworkLayers[art].opacity = 0.4
        profile.customization = local
        for variant in try XCTUnwrap(profile.appearanceBank).variants {
            let result = resolve(profile, variant)
            let expected = variant.appearance.applying(to: local)
            XCTAssertEqual(result.styleLibrary.styles[0].visualStyle.normal.fillStyle,
                expected.styleLibrary.styles[0].visualStyle.normal.fillStyle)
            XCTAssertEqual(result.styleLibrary.styles[0].visualStyle.normal.strokeWidth, 6)
            XCTAssertEqual(result.styleLibrary.styles[0].name, "My reusable style")
            XCTAssertEqual(result.artworkLayers.first { $0.id == "shared-art" }?.opacity, 0.4)
            XCTAssertTrue(result.artworkLayers.contains { $0.id == "\(variant.colorScheme.rawValue)-only-art" })
            if variant.colorScheme == .dark { XCTAssertFalse(result.artworkLayers.contains { $0.id == "light-only-art" }) }
        }
        local.artworkLayers.removeAll { $0.id == "shared-art" }
        profile.customization = local
        for variant in try XCTUnwrap(profile.appearanceBank).variants {
            XCTAssertFalse(resolve(profile, variant).artworkLayers.contains { $0.id == "shared-art" })
        }
        local.artworkLayers.removeAll()
        profile.customization = local
        for variant in try XCTUnwrap(profile.appearanceBank).variants { XCTAssertTrue(resolve(profile, variant).artworkLayers.isEmpty) }
    }

    func testBankRejectsIncompleteDuplicateAndInconsistentStateSets() throws {
        let bank = try XCTUnwrap(makeCandidate().appearanceBank)
        XCTAssertThrowsError(try GamepadAppearanceBank(variants: Array(bank.variants.dropLast())))
        var duplicate = bank.variants
        duplicate[0] = duplicate[1]
        XCTAssertThrowsError(try GamepadAppearanceBank(variants: duplicate))
        var inconsistent = bank.variants
        inconsistent[0] = .init(colorScheme: inconsistent[0].colorScheme, actionSet: inconsistent[0].actionSet,
            appearance: .init(.blankCanvas))
        XCTAssertThrowsError(try GamepadAppearanceBank(variants: inconsistent))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(bank)) as? [String: Any])
        json["packageIdentifier"] = "retired-package"
        XCTAssertThrowsError(try JSONDecoder().decodeUnique(GamepadAppearanceBank.self, from: JSONSerialization.data(withJSONObject: json)))
    }

    func testVersionFourEnvelopeCannotSilentlyCarryAppearanceBanks() throws {
        let profile = try makeCandidate()
        let envelope = ThumbleKeypadConfigurationExport(profiles: [profile], activeProfileID: profile.id, defaultProfileID: profile.id)
        XCTAssertThrowsError(try JSONEncoder().encode(envelope))
        let rawProfile = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile))
        let raw: [String: Any] = ["schema": ThumbleKeypadConfigurationExport.schemaIdentifier, "version": 4,
            "profiles": [rawProfile], "activeProfileID": profile.id.uuidString, "defaultProfileID": profile.id.uuidString]
        XCTAssertThrowsError(try JSONDecoder().decodeUnique(ThumbleKeypadConfigurationExport.self,
            from: JSONSerialization.data(withJSONObject: raw)))
    }

    @MainActor
    func testDesktopPreviewResolvesOwnedAppearanceWithoutLoadingPackage() throws {
        let profile = try makeCandidate()
        let cache = ThumbleSkinEditorPreviewCache()
        let actual = cache.resolve(profile: profile, orientation: .landscape, colorScheme: .dark) {
            XCTFail("Owned appearance must not request a package")
            return nil
        }
        XCTAssertEqual(actual, profile.resolvedCustomization(for: .landscape, colorScheme: .dark, skinPackage: nil))
        XCTAssertNotEqual(actual, profile.customization)
    }
}
