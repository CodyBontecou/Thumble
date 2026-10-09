import XCTest

final class OrientationPreferenceTests: XCTestCase {
    private let profileID = UUID(uuidString: "00000000-0000-0000-0000-00000000F001")!

    func testDeclaredProfileJSONDefaultsOrientationToAutomatic() throws {
        let json = """
        {
          "id": "\(profileID.uuidString)",
          "name": "Legacy",
          "customization": {"elements": []}
        }
        """

        let profile = try JSONDecoder().decode(
            GamepadConfigurationProfile.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(profile.orientationPreference, .automatic)
    }

    func testOrientationPreferenceRoundTripsAndSurvivesNormalizationAndCopy() throws {
        var profile = GamepadConfigurationProfile(
            id: profileID,
            name: "  Locked Setup  ",
            customization: .defaultValue,
            orientationPreference: .landscape
        )
        profile.copyLayoutVariant(from: .landscape, to: .portrait)

        XCTAssertEqual(profile.normalized.orientationPreference, .landscape)
        XCTAssertEqual(profile.orientationPreference, .landscape)

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(GamepadConfigurationProfile.self, from: data)
        XCTAssertEqual(decoded.orientationPreference, .landscape)
        XCTAssertEqual(decoded.normalized.name, "Locked Setup")
    }

    func testLegacyControllerMessageDecodesWithoutCapabilitiesOrMutation() throws {
        let data = Data(
            #"{"type":"gamepad_profiles","timestamp":0,"gamepadProfileID":"00000000-0000-0000-0000-00000000F001"}"#.utf8
        )
        let decoded = try JSONDecoder().decode(ControllerMessage.self, from: data)

        XCTAssertNil(decoded.capabilities)
        XCTAssertNil(decoded.gamepadProfileOrientationPreferenceMutation)
    }

    func testOrientationMutationMessageRoundTripsExplicitFields() throws {
        let message = ControllerMessage(
            type: .gamepadProfileOrientationPreferenceMutation,
            timestamp: 0,
            gamepadProfileID: profileID,
            capabilities: [.gamepadProfileOrientationPreferenceMutation],
            gamepadProfileOrientationPreferenceMutation: .portrait
        )

        let data = try ControllerWireCodec.encode(message, using: JSONEncoder())
        let decoded = try ControllerWireCodec.decode(data, using: JSONDecoder())

        XCTAssertEqual(decoded.type, .gamepadProfileOrientationPreferenceMutation)
        XCTAssertEqual(decoded.gamepadProfileID, profileID)
        XCTAssertEqual(decoded.capabilities, [.gamepadProfileOrientationPreferenceMutation])
        XCTAssertEqual(decoded.gamepadProfileOrientationPreferenceMutation, .portrait)
    }

    func testOrientationCLIParserSupportsGetAndSet() throws {
        XCTAssertEqual(
            try GamepadProfileOrientationCLIParser.parse(["get", "--profile", "Arcade", "--json"]),
            .get(profile: "Arcade", json: true)
        )
        XCTAssertEqual(
            try GamepadProfileOrientationCLIParser.parse(["set", "landscape", "--profile", profileID.uuidString]),
            .set(.landscape, profile: profileID.uuidString)
        )
        XCTAssertEqual(
            try GamepadProfileOrientationCLIParser.parsePreference("follow-device"),
            .automatic
        )
        XCTAssertThrowsError(try GamepadProfileOrientationCLIParser.parse(["set", "sideways"]))
    }

    func testOrientationMutationRoutingRequiresAuthenticationCapabilityAndPayload() {
        let message = ControllerMessage(
            type: .gamepadProfileOrientationPreferenceMutation,
            gamepadProfileID: profileID,
            gamepadProfileOrientationPreferenceMutation: .portrait
        )
        let capability: Set<ControllerCapability> = [.gamepadProfileOrientationPreferenceMutation]

        XCTAssertEqual(
            ControllerProfileOrientationMutationRouter.route(
                message: message,
                isAuthenticated: true,
                advertisedCapabilities: capability
            ),
            .accept(profileID: profileID, preference: .portrait)
        )
        XCTAssertEqual(
            ControllerProfileOrientationMutationRouter.route(
                message: message,
                isAuthenticated: false,
                advertisedCapabilities: capability
            ),
            .rejectUnauthenticated
        )
        XCTAssertEqual(
            ControllerProfileOrientationMutationRouter.route(
                message: message,
                isAuthenticated: true,
                advertisedCapabilities: []
            ),
            .rejectUnsupportedCapability
        )
        XCTAssertEqual(
            ControllerProfileOrientationMutationRouter.route(
                message: ControllerMessage(type: .gamepadProfileOrientationPreferenceMutation),
                isAuthenticated: true,
                advertisedCapabilities: capability
            ),
            .rejectMalformed
        )
    }
}
