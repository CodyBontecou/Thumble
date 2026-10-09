import Foundation

/// The identity of one actual keypad element. It has no action semantics and
/// no bounded pool of slots. Labels and outputs belong to the element itself.
public struct KeypadElementID: RawRepresentable, Codable, Identifiable, Hashable, Sendable {
    public let uuid: UUID
    public var rawValue: String { uuid.uuidString }
    public var id: String { rawValue }

    public init(_ uuid: UUID = UUID()) { self.uuid = uuid }

    public init?(rawValue: String) {
        guard let uuid = UUID(uuidString: rawValue) else { return nil }
        self.uuid = uuid
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let id = Self(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a keypad element UUID. Named input slots are no longer supported."
            )
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Stable identities used only when constructing the built-in starter layout.
    /// New controls always use their own UUID, never an available preset identity.
    public static func preset(_ number: Int) -> Self {
        Self(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", 0x100 + number))!)
    }

    public var displayName: String {
        DefaultKeypadElements.titles[self] ?? "Button \(rawValue.prefix(8))"
    }
}

/// Appearance anchors for the starter layout, not a routing or binding table.
enum DefaultKeypadElements {
    static let ids = (1...10).map(KeypadElementID.preset)
    static let titles = Dictionary(uniqueKeysWithValues: zip(ids, [
        "Up", "Down", "Left", "Right", "Action 1", "Action 2", "Action 3", "Action 4", "Menu", "Pause"
    ]))

    static func initialBinding(for id: KeypadElementID) -> KeypadElementOutputBinding? {
        guard let index = ids.firstIndex(of: id) else { return nil }
        let keys: [UInt16] = [126, 125, 123, 124, 36, 48, 40, 11, 35, 53]
        let modifiers: [UInt8] = [0, 0, 0, 0, 0, 0, 1, 8, 3, 0]
        let buttons: [VirtualGamepadButton] = [
            .dpadUp, .dpadDown, .dpadLeft, .dpadRight, .south, .east, .west, .north, .select, .start
        ]
        return KeypadElementOutputBinding(
            keyboard: KeypadKeyboardBinding(keyCode: keys[index], modifiersRawValue: modifiers[index]),
            gamepadButtons: [buttons[index]]
        )
    }
}

enum KeypadElementSchema {
    private struct Field: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    static func requireUUIDBindingKeys(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: Field.self)
        func validate(_ decoder: Decoder) throws {
            let map = try decoder.container(keyedBy: Field.self)
            var seen = Set<UUID>()
            for key in map.allKeys {
                guard let id = KeypadElementID(rawValue: key.stringValue), seen.insert(id.uuid).inserted else {
                    throw DecodingError.dataCorruptedError(forKey: key, in: map, debugDescription: "Binding keys must be element UUIDs. Named input slots are no longer supported.")
                }
            }
        }
        for name in ["keyBindings", "outputBindings"] {
            let key = Field(stringValue: name)!
            if root.contains(key), try !root.decodeNil(forKey: key) {
                try validate(root.superDecoder(forKey: key))
            }
        }
        for name in ["profileKeyBindings", "profileOutputBindings"] {
            let key = Field(stringValue: name)!
            guard root.contains(key), try !root.decodeNil(forKey: key) else { continue }
            let maps = try root.nestedContainer(keyedBy: Field.self, forKey: key)
            for profile in maps.allKeys { try validate(maps.superDecoder(forKey: profile)) }
        }
    }

    static func requireProfileBindingOwners(from decoder: Decoder, profiles: [GamepadConfigurationProfile]) throws {
        let root = try decoder.container(keyedBy: Field.self)
        let declared = Dictionary(uniqueKeysWithValues: profiles.map { profile in
            var ids = Set(profile.customization.elements.map(\.id))
            if let landscape = profile.landscapeCustomization { ids.formUnion(landscape.elements.map(\.id)) }
            if let portrait = profile.portraitCustomization { ids.formUnion(portrait.elements.map(\.id)) }
            return (profile.id, ids)
        })
        for name in ["keyBindings", "outputBindings"] {
            let field = Field(stringValue: name)!
            guard !root.contains(field) else {
                throw DecodingError.dataCorruptedError(forKey: field, in: root, debugDescription: "Configuration envelopes use profile-owned binding maps, not authority-global maps.")
            }
        }
        for name in ["profileKeyBindings", "profileOutputBindings"] {
            let field = Field(stringValue: name)!
            guard root.contains(field) else { continue }
            let maps = try root.nestedContainer(keyedBy: Field.self, forKey: field)
            var seenProfiles = Set<UUID>()
            for key in maps.allKeys {
                guard let profileID = UUID(uuidString: key.stringValue),
                      let owners = declared[profileID], seenProfiles.insert(profileID).inserted else {
                    throw DecodingError.dataCorruptedError(forKey: key, in: maps, debugDescription: "Binding maps must reference unique declared profile UUIDs.")
                }
                let entries = try maps.nestedContainer(keyedBy: Field.self, forKey: key)
                var seen = Set<UUID>()
                for element in entries.allKeys {
                    guard let id = UUID(uuidString: element.stringValue), owners.contains(id), seen.insert(id).inserted else {
                        throw DecodingError.dataCorruptedError(forKey: element, in: entries, debugDescription: "Binding maps must reference unique declared element UUIDs; incompatible references are not repaired.")
                    }
                }
            }
        }
    }

    static func requireDeclaredAppearanceKeys(from decoder: Decoder, declaredIDs: Set<UUID>) throws {
        let root = try decoder.container(keyedBy: Field.self)
        for name in ["labelOverrides", "buttonCustomizations"] {
            let field = Field(stringValue: name)!
            guard root.contains(field), try !root.decodeNil(forKey: field) else { continue }
            let mapDecoder = try root.superDecoder(forKey: field)
            var seen = Set<UUID>()
            func validate(_ raw: String) throws {
                guard let id = UUID(uuidString: raw), declaredIDs.contains(id), seen.insert(id).inserted else {
                    throw DecodingError.dataCorruptedError(forKey: field, in: root, debugDescription: "Appearance maps must reference unique declared element UUIDs; incompatible references are not repaired.")
                }
            }
            if var pairs = try? mapDecoder.unkeyedContainer() {
                while !pairs.isAtEnd {
                    try validate(pairs.decode(String.self))
                    _ = try pairs.superDecoder()
                }
            } else {
                let map = try mapDecoder.container(keyedBy: Field.self)
                for key in map.allKeys { try validate(key.stringValue) }
            }
        }
    }

    static func requireIndependentIdentity(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Field.self)
        for name in ["button", "mappedButton", "builtInButton", "legacySlot", "inputID", "defaultControlID"] {
            let field = Field(stringValue: name)!
            if container.contains(field) {
                throw DecodingError.dataCorruptedError(
                    forKey: field,
                    in: container,
                    debugDescription: "Input-slot routing is no longer supported. Use an element id and explicit output bindings."
                )
            }
        }
    }
}

public enum KeypadElementInputPart: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case primary
    case joystickUp = "joystick_up"
    case joystickDown = "joystick_down"
    case joystickLeft = "joystick_left"
    case joystickRight = "joystick_right"
    case triggerDigital = "trigger_digital"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .primary: "Press"
        case .joystickUp: "Joystick Up"
        case .joystickDown: "Joystick Down"
        case .joystickLeft: "Joystick Left"
        case .joystickRight: "Joystick Right"
        case .triggerDigital: "Trigger Press"
        }
    }

    public init(direction: GamepadJoystickDirection) {
        switch direction {
        case .up: self = .joystickUp
        case .down: self = .joystickDown
        case .left: self = .joystickLeft
        case .right: self = .joystickRight
        }
    }
}

public struct KeypadElementInputID: Codable, Hashable, Identifiable, Sendable {
    public var elementID: UUID
    public var part: KeypadElementInputPart

    public init(elementID: UUID, part: KeypadElementInputPart = .primary) {
        self.elementID = elementID
        self.part = part
    }

    public var id: String { storageKey }

    public var storageKey: String {
        part == .primary ? elementID.uuidString : "\(elementID.uuidString)#\(part.rawValue)"
    }

    public init?(storageKey: String) {
        let pieces = storageKey.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = pieces.first,
              let id = UUID(uuidString: String(first))
        else { return nil }
        elementID = id
        if pieces.count > 1 {
            guard let parsedPart = KeypadElementInputPart(rawValue: String(pieces[1])) else { return nil }
            part = parsedPart
        } else {
            part = .primary
        }
    }
}

public enum ThumbleMacIPC {
    // These identifiers remain stable so existing installs, pairings, and CLI/app IPC survive the rename.
    public static let appDefaultsDomain = "com.codybontecou.PocketPadMac"
    public static let commandNotificationName = "com.codybontecou.PocketPadMac.cliCommand"
    public static let commandDataKey = "commandData"
    public static let runtimeStatusDefaultsKey = "PocketPadMac.runtimeStatus.v1"
    public static let onboardingCompletedDefaultsKey = "PocketPadMac.onboarding.completed.v1"
    public static let editorFirstKeypadOnboardingCompletedDefaultsKey = "PocketPad.GamepadEditor.firstKeypadOnboardingCompleted.v1"
    public static let editorFirstKeypadOnboardingReplayRequestedDefaultsKey = "PocketPad.GamepadEditor.firstKeypadOnboardingReplayRequested.v1"
    public static let captureLogPath = "/tmp/thumble-capture.jsonl"
    public static let legacyThumbConsoleCaptureLogPath = "/tmp/thumbconsole-capture.jsonl"
    public static let legacyThumbleCaptureLogPath = "/tmp/pocketpad-capture.jsonl"
}

public enum ThumbleMacCLICommand: String, Codable, Sendable {
    case publishStatus
    case start
    case stop
    case restart
    case cancelPairing
    case refreshAccessibility
    case promptAccessibility
    case openAccessibilitySettings
    case releaseAll
    case retryGamepad
    case testGamepad
    case testDown
    case testUp
}

public struct ThumbleCaptureEvent: Codable, Sendable {
    public var schemaVersion: Int
    public var sequence: UInt64?
    public var recordedAt: Int64
    public var uptimeNanoseconds: UInt64?
    public var kind: String
    public var source: String?
    public var messageType: ControllerMessageType?
    public var button: KeypadElementID?
    public var elementInput: KeypadElementInputID?
    public var elementLabel: String?
    public var state: ButtonPressState?
    public var binding: String?
    public var pointerEvent: ControllerPointerEventKind?
    public var pointerButton: ControllerPointerButton?
    public var deltaX: Double?
    public var deltaY: Double?
    public var analogStick: VirtualGamepadStick?
    public var analogTrigger: VirtualGamepadTrigger?
    public var analogX: Double?
    public var analogY: Double?
    public var analogValue: Double?
    public var inputGeneration: UInt64?
    public var inputSequence: UInt64?
    public var expectedSequence: UInt64?
    public var receivedSequence: UInt64?
    public var missedFrameCount: UInt64?
    public var totalMissedButtonFrames: Int?
    public var pressIdentifier: UInt64?
    public var latencyMS: Int?
    public var decodeLatencyMS: Double?
    public var receiveToProcessedMS: Double?
    public var reorderWaitMS: Double?
    public var processingToCompletionMS: Double?
    public var bindingLookupMS: Double?
    public var outputInjectionMS: Double?
    public var postInjectionMS: Double?
    public var outputDeferred: Bool?
    public var pressedButtons: [KeypadElementID]?
    public var pressedElementInputs: [String]?
    public var activePointerButtons: [ControllerPointerButton]?
    public var statusText: String?
    public var clientName: String?
    public var isClientConnected: Bool?
    public var detail: String?

    public init(
        schemaVersion: Int = 1,
        sequence: UInt64? = nil,
        recordedAt: Int64 = Date.currentMilliseconds,
        uptimeNanoseconds: UInt64? = nil,
        kind: String,
        source: String? = nil,
        messageType: ControllerMessageType? = nil,
        button: KeypadElementID? = nil,
        elementInput: KeypadElementInputID? = nil,
        elementLabel: String? = nil,
        state: ButtonPressState? = nil,
        binding: String? = nil,
        pointerEvent: ControllerPointerEventKind? = nil,
        pointerButton: ControllerPointerButton? = nil,
        deltaX: Double? = nil,
        deltaY: Double? = nil,
        analogStick: VirtualGamepadStick? = nil,
        analogTrigger: VirtualGamepadTrigger? = nil,
        analogX: Double? = nil,
        analogY: Double? = nil,
        analogValue: Double? = nil,
        inputGeneration: UInt64? = nil,
        inputSequence: UInt64? = nil,
        expectedSequence: UInt64? = nil,
        receivedSequence: UInt64? = nil,
        missedFrameCount: UInt64? = nil,
        totalMissedButtonFrames: Int? = nil,
        pressIdentifier: UInt64? = nil,
        latencyMS: Int? = nil,
        decodeLatencyMS: Double? = nil,
        receiveToProcessedMS: Double? = nil,
        reorderWaitMS: Double? = nil,
        processingToCompletionMS: Double? = nil,
        bindingLookupMS: Double? = nil,
        outputInjectionMS: Double? = nil,
        postInjectionMS: Double? = nil,
        outputDeferred: Bool? = nil,
        pressedButtons: [KeypadElementID]? = nil,
        pressedElementInputs: [String]? = nil,
        activePointerButtons: [ControllerPointerButton]? = nil,
        statusText: String? = nil,
        clientName: String? = nil,
        isClientConnected: Bool? = nil,
        detail: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.sequence = sequence
        self.recordedAt = recordedAt
        self.uptimeNanoseconds = uptimeNanoseconds
        self.kind = kind
        self.source = source
        self.messageType = messageType
        self.button = button
        self.elementInput = elementInput
        self.elementLabel = elementLabel
        self.state = state
        self.binding = binding
        self.pointerEvent = pointerEvent
        self.pointerButton = pointerButton
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.analogStick = analogStick
        self.analogTrigger = analogTrigger
        self.analogX = analogX
        self.analogY = analogY
        self.analogValue = analogValue
        self.inputGeneration = inputGeneration
        self.inputSequence = inputSequence
        self.expectedSequence = expectedSequence
        self.receivedSequence = receivedSequence
        self.missedFrameCount = missedFrameCount
        self.totalMissedButtonFrames = totalMissedButtonFrames
        self.pressIdentifier = pressIdentifier
        self.latencyMS = latencyMS
        self.decodeLatencyMS = decodeLatencyMS
        self.receiveToProcessedMS = receiveToProcessedMS
        self.reorderWaitMS = reorderWaitMS
        self.processingToCompletionMS = processingToCompletionMS
        self.bindingLookupMS = bindingLookupMS
        self.outputInjectionMS = outputInjectionMS
        self.postInjectionMS = postInjectionMS
        self.outputDeferred = outputDeferred
        self.pressedButtons = pressedButtons
        self.pressedElementInputs = pressedElementInputs
        self.activePointerButtons = activePointerButtons
        self.statusText = statusText
        self.clientName = clientName
        self.isClientConnected = isClientConnected
        self.detail = detail
    }
}

public struct ControllerClientDeviceInsets: Codable, Equatable, Sendable {
    public var top: Double
    public var leading: Double
    public var bottom: Double
    public var trailing: Double

    public init(top: Double, leading: Double, bottom: Double, trailing: Double) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }
}

public struct ControllerClientDeviceInfo: Codable, Equatable, Sendable {
    public var deviceName: String
    public var modelIdentifier: String?
    public var systemName: String
    public var systemVersion: String
    public var screenBoundsWidth: Double
    public var screenBoundsHeight: Double
    public var nativeBoundsWidth: Double
    public var nativeBoundsHeight: Double
    public var scale: Double
    public var nativeScale: Double
    public var safeAreaInsets: ControllerClientDeviceInsets?
    public var interfaceOrientation: String?
    public var interfaceStyle: String?

    public init(
        deviceName: String,
        modelIdentifier: String?,
        systemName: String,
        systemVersion: String,
        screenBoundsWidth: Double,
        screenBoundsHeight: Double,
        nativeBoundsWidth: Double,
        nativeBoundsHeight: Double,
        scale: Double,
        nativeScale: Double,
        safeAreaInsets: ControllerClientDeviceInsets? = nil,
        interfaceOrientation: String? = nil,
        interfaceStyle: String? = nil
    ) {
        self.deviceName = deviceName
        self.modelIdentifier = modelIdentifier
        self.systemName = systemName
        self.systemVersion = systemVersion
        self.screenBoundsWidth = screenBoundsWidth
        self.screenBoundsHeight = screenBoundsHeight
        self.nativeBoundsWidth = nativeBoundsWidth
        self.nativeBoundsHeight = nativeBoundsHeight
        self.scale = scale
        self.nativeScale = nativeScale
        self.safeAreaInsets = safeAreaInsets
        self.interfaceOrientation = interfaceOrientation
        self.interfaceStyle = interfaceStyle
    }
}

public struct ThumbleMacCLICommandPayload: Codable, Sendable {
    public var command: ThumbleMacCLICommand
    public var button: KeypadElementID?
    public var elementInput: KeypadElementInputID?
    public var reason: String?
    public var requestID: String?
    public var holdMilliseconds: Int?
    public var runtimeInstanceID: String?

    public init(
        command: ThumbleMacCLICommand,
        button: KeypadElementID? = nil,
        elementInput: KeypadElementInputID? = nil,
        reason: String? = nil,
        requestID: String? = nil,
        holdMilliseconds: Int? = nil,
        runtimeInstanceID: String? = nil
    ) {
        self.command = command
        self.button = button
        self.elementInput = elementInput
        self.reason = reason
        self.requestID = requestID
        self.holdMilliseconds = holdMilliseconds
        self.runtimeInstanceID = runtimeInstanceID
    }
}

public enum ThumbleEditorDeliveryState: String, Codable, Equatable, Sendable {
    case localSave = "local_save"
    case sending
    case sent
    case offline
    case failure
}

public struct ThumbleMacRuntimeStatus: Codable, Sendable {
    public var updatedAt: Int64
    public var statusText: String
    public var isRunning: Bool
    public var isClientConnected: Bool
    public var localURLs: [String]
    public var bonjourServiceName: String?
    public var bonjourServiceType: String?
    public var bonjourServiceDomain: String?
    public var serverID: String?
    public var pairingCode: String
    public var isPairingPending: Bool
    public var pendingPairingClientName: String?
    public var clientName: String
    public var lastHeartbeatMilliseconds: Int64?
    public var lastReceivedEvent: String
    public var estimatedLatencyMS: Int?
    public var roundTripLatencyMS: Int?
    public var inputPipelineP50MS: Double?
    public var inputPipelineP95MS: Double?
    public var inputPipelineP99MS: Double?
    public var inputProcessingP95MS: Double?
    public var bindingLookupP95MS: Double?
    public var outputInjectionP50MS: Double?
    public var outputInjectionP95MS: Double?
    public var outputInjectionP99MS: Double?
    public var postInjectionP95MS: Double?
    public var inputProtocolVersion: Int?
    public var activeInputGeneration: UInt64?
    public var staleInputGenerationDrops: Int?
    public var pressedButtons: [KeypadElementID]
    public var pressedElementInputs: [KeypadElementInputID]?
    public var editorDeliveryState: ThumbleEditorDeliveryState?
    public var editorDeliveryDetail: String?
    public var editorDeliveryUpdatedAt: Int64?
    public var missedButtonFrames: Int
    public var ignoredButtonEdges: Int
    public var recoveredButtonEdges: Int
    public var accessibilityTrusted: Bool
    public var port: UInt16
    public var activeGamepadProfileID: UUID
    public var defaultGamepadProfileID: UUID
    public var activeGamepadProfileOrientationPreference: GamepadProfileOrientationPreference?
    public var clientDeviceInfo: ControllerClientDeviceInfo?
    public var virtualGamepadActive: Bool?
    public var virtualGamepadAvailable: Bool?
    public var virtualGamepadLastError: String?
    public var virtualGamepadPressedButtons: [VirtualGamepadButton]?
    public var virtualGamepadLeftStickX: Double?
    public var virtualGamepadLeftStickY: Double?
    public var virtualGamepadRightStickX: Double?
    public var virtualGamepadRightStickY: Double?
    public var virtualGamepadLeftTrigger: Double?
    public var virtualGamepadRightTrigger: Double?
    public var captureLogPath: String?
    public var virtualGamepadStatus: VirtualGamepadStatus?
    public var runtimeProcessID: Int32?
    public var runtimeInstanceID: String?
    public var runtimeStatusRequestID: String?

    public init(
        updatedAt: Int64,
        statusText: String,
        isRunning: Bool,
        isClientConnected: Bool,
        localURLs: [String],
        bonjourServiceName: String? = nil,
        bonjourServiceType: String? = nil,
        bonjourServiceDomain: String? = nil,
        serverID: String? = nil,
        pairingCode: String,
        isPairingPending: Bool,
        pendingPairingClientName: String?,
        clientName: String,
        lastHeartbeatMilliseconds: Int64?,
        lastReceivedEvent: String,
        estimatedLatencyMS: Int?,
        roundTripLatencyMS: Int? = nil,
        inputPipelineP50MS: Double? = nil,
        inputPipelineP95MS: Double? = nil,
        inputPipelineP99MS: Double? = nil,
        inputProcessingP95MS: Double? = nil,
        bindingLookupP95MS: Double? = nil,
        outputInjectionP50MS: Double? = nil,
        outputInjectionP95MS: Double? = nil,
        outputInjectionP99MS: Double? = nil,
        postInjectionP95MS: Double? = nil,
        inputProtocolVersion: Int? = nil,
        activeInputGeneration: UInt64? = nil,
        staleInputGenerationDrops: Int? = nil,
        pressedButtons: [KeypadElementID],
        pressedElementInputs: [KeypadElementInputID]? = nil,
        editorDeliveryState: ThumbleEditorDeliveryState? = nil,
        editorDeliveryDetail: String? = nil,
        editorDeliveryUpdatedAt: Int64? = nil,
        missedButtonFrames: Int,
        ignoredButtonEdges: Int,
        recoveredButtonEdges: Int,
        accessibilityTrusted: Bool,
        port: UInt16,
        activeGamepadProfileID: UUID,
        defaultGamepadProfileID: UUID,
        activeGamepadProfileOrientationPreference: GamepadProfileOrientationPreference? = nil,
        clientDeviceInfo: ControllerClientDeviceInfo? = nil,
        virtualGamepadActive: Bool? = nil,
        virtualGamepadAvailable: Bool? = nil,
        virtualGamepadLastError: String? = nil,
        virtualGamepadPressedButtons: [VirtualGamepadButton]? = nil,
        virtualGamepadLeftStickX: Double? = nil,
        virtualGamepadLeftStickY: Double? = nil,
        virtualGamepadRightStickX: Double? = nil,
        virtualGamepadRightStickY: Double? = nil,
        virtualGamepadLeftTrigger: Double? = nil,
        virtualGamepadRightTrigger: Double? = nil,
        captureLogPath: String? = nil,
        virtualGamepadStatus: VirtualGamepadStatus? = nil,
        runtimeProcessID: Int32? = nil,
        runtimeInstanceID: String? = nil,
        runtimeStatusRequestID: String? = nil
    ) {
        self.updatedAt = updatedAt
        self.statusText = statusText
        self.isRunning = isRunning
        self.isClientConnected = isClientConnected
        self.localURLs = localURLs
        self.bonjourServiceName = bonjourServiceName
        self.bonjourServiceType = bonjourServiceType
        self.bonjourServiceDomain = bonjourServiceDomain
        self.serverID = serverID
        self.pairingCode = pairingCode
        self.isPairingPending = isPairingPending
        self.pendingPairingClientName = pendingPairingClientName
        self.clientName = clientName
        self.lastHeartbeatMilliseconds = lastHeartbeatMilliseconds
        self.lastReceivedEvent = lastReceivedEvent
        self.estimatedLatencyMS = estimatedLatencyMS
        self.roundTripLatencyMS = roundTripLatencyMS ?? estimatedLatencyMS
        self.inputPipelineP50MS = inputPipelineP50MS
        self.inputPipelineP95MS = inputPipelineP95MS
        self.inputPipelineP99MS = inputPipelineP99MS
        self.inputProcessingP95MS = inputProcessingP95MS
        self.bindingLookupP95MS = bindingLookupP95MS
        self.outputInjectionP50MS = outputInjectionP50MS
        self.outputInjectionP95MS = outputInjectionP95MS
        self.outputInjectionP99MS = outputInjectionP99MS
        self.postInjectionP95MS = postInjectionP95MS
        self.inputProtocolVersion = inputProtocolVersion
        self.activeInputGeneration = activeInputGeneration
        self.staleInputGenerationDrops = staleInputGenerationDrops
        self.pressedButtons = pressedButtons
        self.pressedElementInputs = pressedElementInputs
        self.editorDeliveryState = editorDeliveryState
        self.editorDeliveryDetail = editorDeliveryDetail
        self.editorDeliveryUpdatedAt = editorDeliveryUpdatedAt
        self.missedButtonFrames = missedButtonFrames
        self.ignoredButtonEdges = ignoredButtonEdges
        self.recoveredButtonEdges = recoveredButtonEdges
        self.accessibilityTrusted = accessibilityTrusted
        self.port = port
        self.activeGamepadProfileID = activeGamepadProfileID
        self.defaultGamepadProfileID = defaultGamepadProfileID
        self.activeGamepadProfileOrientationPreference = activeGamepadProfileOrientationPreference
        self.clientDeviceInfo = clientDeviceInfo
        self.virtualGamepadActive = virtualGamepadActive
        self.virtualGamepadAvailable = virtualGamepadAvailable
        self.virtualGamepadLastError = virtualGamepadLastError
        self.virtualGamepadPressedButtons = virtualGamepadPressedButtons
        self.virtualGamepadLeftStickX = virtualGamepadLeftStickX
        self.virtualGamepadLeftStickY = virtualGamepadLeftStickY
        self.virtualGamepadRightStickX = virtualGamepadRightStickX
        self.virtualGamepadRightStickY = virtualGamepadRightStickY
        self.virtualGamepadLeftTrigger = virtualGamepadLeftTrigger
        self.virtualGamepadRightTrigger = virtualGamepadRightTrigger
        self.captureLogPath = captureLogPath
        self.virtualGamepadStatus = virtualGamepadStatus
        self.runtimeProcessID = runtimeProcessID
        self.runtimeInstanceID = runtimeInstanceID
        self.runtimeStatusRequestID = runtimeStatusRequestID
    }
}

public enum ButtonPressState: String, Codable, Sendable {
    case down
    case up
}

public enum ControllerPointerEventKind: String, Codable, Sendable {
    case move
    case scroll
    case button
}

public enum ControllerPointerButton: String, Codable, Sendable {
    case left
    case right
    case middle
}

public enum ControllerCapability: String, Codable, CaseIterable, Sendable {
    /// The Mac accepts authenticated, profile-scoped orientation preference mutations
    /// and responds by broadcasting the complete authoritative profile state.
    case gamepadProfileOrientationPreferenceMutation = "gamepad_profile_orientation_preference_mutation"
    /// Profile synchronization includes validated appearance-only `.pocketpad` archives.
    case skinPackages = "skin_packages"
    /// The peer accepts profile-scoped skin apply/detach mutations.
    case gamepadProfileSkinSelection = "gamepad_profile_skin_selection"
    /// The paired Mac accepts bounded portable artifact v1 uploads for explicit adoption.
    case profileArtifactAdoptionV1 = "profile_artifact_adoption_v1"
}

public enum ControllerMessageType: String, Codable, Sendable {
    case hello
    case pairingRequest = "pairing_request"
    case pairingChallenge = "pairing_challenge"
    case pairingAccepted = "pairing_accepted"
    case button
    case elementInput = "element_input"
    case pointer
    case gamepadAnalog = "gamepad_analog"
    case releaseAll = "release_all"
    case heartbeat
    case ping
    case pong
    case gamepadCustomization = "gamepad_customization"
    case gamepadProfiles = "gamepad_profiles"
    case skinPackages = "skin_packages"
    case skinPackageRemoval = "skin_package_removal"
    case gamepadProfileSkinSelection = "gamepad_profile_skin_selection"
    case gamepadProfileSelection = "gamepad_profile_selection"
    case gamepadDefaultProfile = "gamepad_default_profile"
    /// Sent only after the Mac advertises the matching capability. Older peers never
    /// receive this message type and continue to treat orientation as automatic.
    case gamepadProfileOrientationPreferenceMutation = "gamepad_profile_orientation_preference_mutation"
    case launchProfileTarget = "launch_profile_target"
    case profileArtifactAdoptionBegin = "profile_artifact_adoption_begin"
    case profileArtifactAdoptionChunk = "profile_artifact_adoption_chunk"
    case profileArtifactAdoptionCommit = "profile_artifact_adoption_commit"
    case profileArtifactAdoptionCancel = "profile_artifact_adoption_cancel"
    case profileArtifactAdoptionResult = "profile_artifact_adoption_result"
    case error
}

public struct ControllerMessage: Codable, Sendable {
    public var type: ControllerMessageType
    public var button: KeypadElementID?
    public var elementID: UUID?
    public var elementPart: KeypadElementInputPart?
    public var state: ButtonPressState?
    public var timestamp: Int64
    public var sentAt: Int64?
    public var pairingCode: String?
    public var clientName: String?
    public var message: String?
    public var realtimeToken: String?
    public var authToken: String?
    public var serverID: String?
    public var gamepadCustomization: GamepadCustomization?
    public var gamepadProfiles: [GamepadConfigurationProfile]?
    public var skinPackages: [Data]?
    public var skinReference: ThumbleSkinReference?
    public var bindingPresentations: [GamepadProfileBindingPresentations]?
    public var gamepadProfileID: UUID?
    public var defaultGamepadProfileID: UUID?
    public var capabilities: [ControllerCapability]?
    /// A profile-scoped mutation payload. It is valid only with
    /// `gamepadProfileOrientationPreferenceMutation` and `gamepadProfileID`.
    public var gamepadProfileOrientationPreferenceMutation: GamepadProfileOrientationPreference?
    public var clientDeviceInfo: ControllerClientDeviceInfo?
    public var pointerEvent: ControllerPointerEventKind?
    public var pointerButton: ControllerPointerButton?
    public var deltaX: Double?
    public var deltaY: Double?
    public var analogStick: VirtualGamepadStick?
    public var analogTrigger: VirtualGamepadTrigger?
    public var analogX: Double?
    public var analogY: Double?
    public var analogValue: Double?
    public var analogSequence: UInt64?
    public var inputProtocolVersion: Int?
    public var inputGeneration: UInt64?
    public var inputSequence: UInt64?
    public var pressIdentifier: UInt64?
    public var profileArtifactAdoptionMetadata: ProfileArtifactAdoptionMetadata?
    public var profileArtifactAdoptionOperationID: UUID?
    public var profileArtifactAdoptionChunkIndex: Int?
    public var profileArtifactAdoptionChunkData: Data?
    public var profileArtifactAdoptionResult: ProfileArtifactAdoptionResult?
    public var virtualGamepadStatus: VirtualGamepadStatus?

    public init(
        type: ControllerMessageType,
        button: KeypadElementID? = nil,
        elementID: UUID? = nil,
        elementPart: KeypadElementInputPart? = nil,
        state: ButtonPressState? = nil,
        timestamp: Int64 = Date.currentMilliseconds,
        sentAt: Int64? = nil,
        pairingCode: String? = nil,
        clientName: String? = nil,
        message: String? = nil,
        realtimeToken: String? = nil,
        authToken: String? = nil,
        serverID: String? = nil,
        gamepadCustomization: GamepadCustomization? = nil,
        gamepadProfiles: [GamepadConfigurationProfile]? = nil,
        skinPackages: [Data]? = nil,
        skinReference: ThumbleSkinReference? = nil,
        bindingPresentations: [GamepadProfileBindingPresentations]? = nil,
        gamepadProfileID: UUID? = nil,
        defaultGamepadProfileID: UUID? = nil,
        capabilities: [ControllerCapability]? = nil,
        gamepadProfileOrientationPreferenceMutation: GamepadProfileOrientationPreference? = nil,
        clientDeviceInfo: ControllerClientDeviceInfo? = nil,
        pointerEvent: ControllerPointerEventKind? = nil,
        pointerButton: ControllerPointerButton? = nil,
        deltaX: Double? = nil,
        deltaY: Double? = nil,
        analogStick: VirtualGamepadStick? = nil,
        analogTrigger: VirtualGamepadTrigger? = nil,
        analogX: Double? = nil,
        analogY: Double? = nil,
        analogValue: Double? = nil,
        analogSequence: UInt64? = nil,
        inputProtocolVersion: Int? = nil,
        inputGeneration: UInt64? = nil,
        inputSequence: UInt64? = nil,
        pressIdentifier: UInt64? = nil,
        profileArtifactAdoptionMetadata: ProfileArtifactAdoptionMetadata? = nil,
        profileArtifactAdoptionOperationID: UUID? = nil,
        profileArtifactAdoptionChunkIndex: Int? = nil,
        profileArtifactAdoptionChunkData: Data? = nil,
        profileArtifactAdoptionResult: ProfileArtifactAdoptionResult? = nil,
        virtualGamepadStatus: VirtualGamepadStatus? = nil
    ) {
        self.type = type
        self.button = button
        self.elementID = elementID
        self.elementPart = elementPart
        self.state = state
        self.timestamp = timestamp
        self.sentAt = sentAt
        self.pairingCode = pairingCode
        self.clientName = clientName
        self.message = message
        self.realtimeToken = realtimeToken
        self.authToken = authToken
        self.serverID = serverID
        self.gamepadCustomization = gamepadCustomization
        self.gamepadProfiles = gamepadProfiles
        self.skinPackages = skinPackages
        self.skinReference = skinReference
        self.bindingPresentations = bindingPresentations
        self.gamepadProfileID = gamepadProfileID
        self.defaultGamepadProfileID = defaultGamepadProfileID
        self.capabilities = capabilities
        self.gamepadProfileOrientationPreferenceMutation = gamepadProfileOrientationPreferenceMutation
        self.clientDeviceInfo = clientDeviceInfo
        self.pointerEvent = pointerEvent
        self.pointerButton = pointerButton
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.analogStick = analogStick
        self.analogTrigger = analogTrigger
        self.analogX = analogX
        self.analogY = analogY
        self.analogValue = analogValue
        self.analogSequence = analogSequence
        self.inputProtocolVersion = inputProtocolVersion
        self.inputGeneration = inputGeneration
        self.inputSequence = inputSequence
        self.pressIdentifier = pressIdentifier
        self.profileArtifactAdoptionMetadata = profileArtifactAdoptionMetadata
        self.profileArtifactAdoptionOperationID = profileArtifactAdoptionOperationID
        self.profileArtifactAdoptionChunkIndex = profileArtifactAdoptionChunkIndex
        self.profileArtifactAdoptionChunkData = profileArtifactAdoptionChunkData
        self.profileArtifactAdoptionResult = profileArtifactAdoptionResult
        self.virtualGamepadStatus = virtualGamepadStatus
    }
}

struct ButtonSequenceInspection: Equatable {
    var hasSequence = false
    var missedFrameBeforeButton = false
    var expectedSequence: UInt64?
    var receivedSequence: UInt64?
    var missedFrameCount: UInt64 = 0
    var totalMissedFrameCount = 0
    var isOutOfOrderOrReset = false
}

struct ButtonSequenceTracker {
    private var nextExpectedButtonSequence: UInt64?
    private var acceptsNextSequenceAsBaseline = false
    private(set) var totalMissedFrameCount = 0

    var nextExpectedSequenceNumber: UInt64? {
        nextExpectedButtonSequence
    }

    var isAcceptingNextSequenceAsBaseline: Bool {
        acceptsNextSequenceAsBaseline
    }

    mutating func inspect(_ message: ControllerMessage) -> ButtonSequenceInspection {
        guard let sequenceNumber = ControllerWireCodec.buttonSequenceNumber(from: message) else {
            return ButtonSequenceInspection()
        }

        var inspection = ButtonSequenceInspection(
            hasSequence: true,
            receivedSequence: sequenceNumber,
            totalMissedFrameCount: totalMissedFrameCount
        )

        if acceptsNextSequenceAsBaseline {
            acceptsNextSequenceAsBaseline = false
        } else if let expectedSequence = nextExpectedButtonSequence, sequenceNumber != expectedSequence {
            inspection.expectedSequence = expectedSequence
            if sequenceNumber > expectedSequence {
                inspection.missedFrameBeforeButton = true
                inspection.missedFrameCount = sequenceNumber - expectedSequence
                inspection.totalMissedFrameCount = recordMissedFrames(inspection.missedFrameCount)
            } else {
                inspection.isOutOfOrderOrReset = true
                return inspection
            }
        } else if nextExpectedButtonSequence == nil, sequenceNumber > 1 {
            inspection.expectedSequence = 1
            inspection.missedFrameBeforeButton = true
            inspection.missedFrameCount = sequenceNumber - 1
            inspection.totalMissedFrameCount = recordMissedFrames(inspection.missedFrameCount)
        }

        if sequenceNumber >= ControllerWireCodec.maximumButtonSequenceNumber {
            nextExpectedButtonSequence = 1
        } else {
            nextExpectedButtonSequence = sequenceNumber + 1
        }

        return inspection
    }

    mutating func reset() {
        nextExpectedButtonSequence = nil
        acceptsNextSequenceAsBaseline = false
        totalMissedFrameCount = 0
    }

    mutating func resetAcceptingNextSequenceAsBaseline() {
        nextExpectedButtonSequence = nil
        acceptsNextSequenceAsBaseline = true
        totalMissedFrameCount = 0
    }

    @discardableResult
    private mutating func recordMissedFrames(_ count: UInt64) -> Int {
        let clampedMissedFrameCount = Int(min(count, UInt64(Int.max)))
        if Int.max - totalMissedFrameCount <= clampedMissedFrameCount {
            totalMissedFrameCount = Int.max
        } else {
            totalMissedFrameCount += clampedMissedFrameCount
        }
        return totalMissedFrameCount
    }
}

private final class ControllerCodecExpandedStackJob<Value>: @unchecked Sendable {
    private let operation: () throws -> Value
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    let completed = DispatchSemaphore(value: 0)

    init(operation: @escaping () throws -> Value) {
        self.operation = operation
    }

    func run() {
        let result = Result { try operation() }
        lock.lock()
        self.result = result
        lock.unlock()
        completed.signal()
    }

    func takeResult() -> Result<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

public enum ControllerWireCodecError: LocalizedError, Equatable {
    case inboundPayloadTooLarge(actualBytes: Int, maximumBytes: Int)

    public var errorDescription: String? {
        switch self {
        case .inboundPayloadTooLarge(let actualBytes, let maximumBytes):
            "Controller payload is \(actualBytes) bytes; the maximum is \(maximumBytes) bytes."
        }
    }
}

public enum ControllerWireCodec {
    public static let currentInputProtocolVersion = 3
    public static let maximumInboundPayloadSize = 8 * 1024 * 1024

    private static let magic: [UInt8] = [0x50, 0x50] // "PP"
    private static let version: UInt8 = 1
    private static let inputVersion: UInt8 = UInt8(currentInputProtocolVersion)
    private static let emptyField: UInt8 = UInt8.max
    private static let compactMessageSize = 14
    private static let compactInputMessageSize = 56
    private static let buttonSequenceMarker: UInt64 = UInt64(1) << 63
    private static let buttonSequenceBitCount: UInt64 = 48
    private static let buttonSequenceMask: UInt64 = (UInt64(1) << buttonSequenceBitCount) - 1
    private static let buttonPressIdentifierShift = buttonSequenceBitCount
    private static let buttonPressIdentifierMask: UInt64 = (UInt64(1) << 15) - 1
    // Swift's Debug Codable path for complete profiles can exceed the 512 KiB stack
    // used by Network.framework and dispatch workers even when our own frames are
    // small. Heavy control-plane payloads run synchronously on a bounded 4 MiB stack;
    // compact and latency-sensitive input messages stay on their current thread.
    private static let expandedCodableStackSize = 4 * 1024 * 1024
    private static let expandedDecodeSizeThreshold = 32 * 1024
    private static let expandedDecodeFieldNames: Set<String> = [
        "gamepadCustomization",
        "gamepadProfiles",
        "skinPackages",
        "bindingPresentations",
        "profileArtifactAdoptionChunkData"
    ]
    private static let expandedDecodeKeyMarkers = expandedDecodeFieldNames.map {
        Data("\"\($0)\"".utf8)
    }
    public static let maximumButtonSequenceNumber = buttonSequenceMask
    public static let maximumButtonPressIdentifier = buttonPressIdentifierMask
    public static func encode(_ message: ControllerMessage, using encoder: JSONEncoder) throws -> Data {
        if let compactData = compactData(for: message) {
            return compactData
        }
        if requiresExpandedStack(for: message) {
            return try withExpandedCodableStack {
                try encoder.encode(message)
            }
        }
        return try encoder.encode(message)
    }

    public static func decode(_ data: Data, using decoder: JSONDecoder) throws -> ControllerMessage {
        guard data.count <= maximumInboundPayloadSize else {
            throw ControllerWireCodecError.inboundPayloadTooLarge(
                actualBytes: data.count,
                maximumBytes: maximumInboundPayloadSize
            )
        }
        if let compactMessage = compactMessage(from: data) {
            return compactMessage
        }
        if requiresExpandedStackForDecoding(data) {
            return try withExpandedCodableStack {
                try decoder.decodeUnique(ControllerMessage.self, from: data)
            }
        }
        return try decoder.decodeUnique(ControllerMessage.self, from: data)
    }

    private static func requiresExpandedStack(for message: ControllerMessage) -> Bool {
        message.gamepadCustomization != nil
            || message.gamepadProfiles != nil
            || message.skinPackages != nil
            || message.bindingPresentations != nil
            || message.profileArtifactAdoptionChunkData != nil
    }

    static func requiresExpandedStackForDecoding(_ data: Data) -> Bool {
        if data.count >= expandedDecodeSizeThreshold { return true }
        if expandedDecodeKeyMarkers.contains(where: { data.range(of: $0) != nil }) {
            return true
        }
        // Our encoder emits canonical ASCII keys, but JSON also permits escaped key
        // spellings (for example, "\\u0067amepadProfiles"). Only take the slower
        // structural fallback when an escape is present. Malformed escaped JSON also
        // uses the expanded stack so an invalid control-plane payload cannot bypass
        // the safety boundary before JSONDecoder reports its error.
        guard data.contains(UInt8(ascii: "\\")) else { return false }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any]
        else { return true }
        return !expandedDecodeFieldNames.isDisjoint(with: fields.keys)
    }

    private static func withExpandedCodableStack<Value>(
        _ operation: @escaping () throws -> Value
    ) throws -> Value {
        let job = ControllerCodecExpandedStackJob(operation: operation)
        let thread = Thread { job.run() }
        thread.name = "Thumble.Codable"
        thread.qualityOfService = .userInteractive
        thread.stackSize = expandedCodableStackSize
        thread.start()
        job.completed.wait()
        guard let result = job.takeResult() else {
            preconditionFailure("Expanded-stack Codable worker completed without a result")
        }
        return try result.get()
    }

    public static func encodeButton(_ button: KeypadElementID, state: ButtonPressState) -> Data {
        compactInputData(for: ControllerMessage(type: .button, button: button, state: state, timestamp: 0))!
    }

    public static func encodeButton(
        _ button: KeypadElementID,
        state: ButtonPressState,
        sequenceNumber: UInt64,
        pressIdentifier: UInt64? = nil,
        generation: UInt64? = nil
    ) -> Data {
        compactInputData(for: ControllerMessage(
            type: .button,
            button: button,
            state: state,
            timestamp: inputSequenceTimestamp(for: sequenceNumber, pressIdentifier: pressIdentifier),
            inputProtocolVersion: currentInputProtocolVersion,
            inputGeneration: generation,
            inputSequence: sequenceNumber,
            pressIdentifier: pressIdentifier
        ))!
    }

    public static func inputSequenceTimestamp(for sequenceNumber: UInt64, pressIdentifier: UInt64? = nil) -> Int64 {
        let sequence = min(max(sequenceNumber, 1), maximumButtonSequenceNumber)
        let identifier = min(pressIdentifier ?? 0, maximumButtonPressIdentifier)
        return Int64(bitPattern: buttonSequenceMarker | (identifier << buttonPressIdentifierShift) | sequence)
    }

    public static func buttonSequenceNumber(from message: ControllerMessage) -> UInt64? {
        inputSequenceNumber(from: message)
    }

    public static func inputSequenceNumber(from message: ControllerMessage) -> UInt64? {
        if let sequence = message.inputSequence { return sequence }
        guard message.type == .button || message.type == .elementInput else { return nil }
        let bits = UInt64(bitPattern: message.timestamp)
        guard bits & buttonSequenceMarker != 0 else { return nil }
        let sequence = bits & buttonSequenceMask
        return sequence == 0 ? nil : sequence
    }

    public static func buttonPressIdentifier(from message: ControllerMessage) -> UInt64? {
        inputPressIdentifier(from: message)
    }

    public static func inputPressIdentifier(from message: ControllerMessage) -> UInt64? {
        if let identifier = message.pressIdentifier { return identifier }
        guard message.type == .button || message.type == .elementInput else { return nil }
        let bits = UInt64(bitPattern: message.timestamp)
        guard bits & buttonSequenceMarker != 0 else { return nil }
        let identifier = (bits >> buttonPressIdentifierShift) & buttonPressIdentifierMask
        return identifier == 0 ? nil : identifier
    }

    private static func compactData(for message: ControllerMessage) -> Data? {
        guard message.sentAt == nil,
              message.pairingCode == nil,
              message.clientName == nil,
              message.message == nil,
              message.realtimeToken == nil,
              message.authToken == nil,
              message.serverID == nil,
              message.gamepadCustomization == nil,
              message.gamepadProfiles == nil,
              message.virtualGamepadStatus == nil,
              message.skinPackages == nil,
              message.skinReference == nil,
              message.bindingPresentations == nil,
              message.gamepadProfileID == nil,
              message.defaultGamepadProfileID == nil,
              message.capabilities == nil,
              message.gamepadProfileOrientationPreferenceMutation == nil,
              message.clientDeviceInfo == nil,
              message.pointerEvent == nil,
              message.pointerButton == nil,
              message.deltaX == nil,
              message.deltaY == nil,
              message.analogStick == nil,
              message.analogTrigger == nil,
              message.analogX == nil,
              message.analogY == nil,
              message.analogValue == nil,
              message.analogSequence == nil,
              message.profileArtifactAdoptionMetadata == nil,
              message.profileArtifactAdoptionOperationID == nil,
              message.profileArtifactAdoptionChunkIndex == nil,
              message.profileArtifactAdoptionChunkData == nil,
              message.profileArtifactAdoptionResult == nil,
              let typeCode = message.type.compactWireCode
        else { return nil }

        if message.type == .button || message.type == .elementInput {
            return compactInputData(for: message)
        }
        guard message.button == nil, message.elementID == nil, message.elementPart == nil,
              message.state == nil, message.inputProtocolVersion == nil,
              message.inputGeneration == nil, message.inputSequence == nil,
              message.pressIdentifier == nil
        else { return nil }
        var data = Data(count: compactMessageSize)
        data.withUnsafeMutableBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self).baseAddress!
            bytes[0] = magic[0]; bytes[1] = magic[1]; bytes[2] = version; bytes[3] = typeCode
            writeLittleEndian(UInt64(bitPattern: message.timestamp), to: bytes, startingAt: 4)
            bytes[12] = emptyField; bytes[13] = emptyField
        }
        return data
    }

    // v3 UUID input: header 0...3, UUID 4...19, part 20, state 21, flags 22,
    // reserved 23, generation 24...31, sequence 32...39, press 40...47,
    // timestamp 48...55. Old slot-index input frames are intentionally rejected.
    private static func compactInputData(for message: ControllerMessage) -> Data? {
        guard let state = message.state,
              message.inputProtocolVersion == nil || message.inputProtocolVersion == currentInputProtocolVersion
        else { return nil }
        let id: UUID
        if message.type == .button {
            guard let button = message.button, message.elementID == nil, message.elementPart == nil else { return nil }
            id = button.uuid
        } else {
            guard message.type == .elementInput, let elementID = message.elementID, message.button == nil else { return nil }
            id = elementID
        }
        let part = message.elementPart ?? .primary
        let partCode = UInt8(KeypadElementInputPart.allCases.firstIndex(of: part)!)
        var data = Data(count: compactInputMessageSize)
        data.withUnsafeMutableBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self).baseAddress!
            bytes[0] = magic[0]; bytes[1] = magic[1]; bytes[2] = inputVersion
            bytes[3] = message.type.compactWireCode!
            var uuid = id.uuid
            withUnsafeBytes(of: &uuid) { source in
                for index in 0..<16 { bytes[4 + index] = source[index] }
            }
            bytes[20] = partCode; bytes[21] = state.compactWireCode
            bytes[22] = (message.pressIdentifier == nil ? 0 : 1)
                | (message.inputGeneration == nil ? 0 : 2)
                | (message.inputSequence == nil ? 0 : 4)
                | (message.inputProtocolVersion == nil ? 0 : 8)
            bytes[23] = 0
            writeLittleEndian(message.inputGeneration ?? 0, to: bytes, startingAt: 24)
            writeLittleEndian(message.inputSequence ?? 0, to: bytes, startingAt: 32)
            writeLittleEndian(message.pressIdentifier ?? 0, to: bytes, startingAt: 40)
            writeLittleEndian(UInt64(bitPattern: message.timestamp), to: bytes, startingAt: 48)
        }
        return data
    }

    private static func writeLittleEndian(_ value: UInt64, to bytes: UnsafeMutablePointer<UInt8>, startingAt start: Int) {
        for offset in 0..<8 { bytes[start + offset] = UInt8(truncatingIfNeeded: value >> UInt64(offset * 8)) }
    }

    private static func readLittleEndian(from bytes: UnsafePointer<UInt8>, startingAt start: Int) -> UInt64 {
        var value: UInt64 = 0
        for offset in 0..<8 { value |= UInt64(bytes[start + offset]) << UInt64(offset * 8) }
        return value
    }

    private static func compactMessage(from data: Data) -> ControllerMessage? {
        if data.count == compactInputMessageSize { return compactInputMessage(from: data) }
        guard data.count == compactMessageSize else { return nil }
        return data.withUnsafeBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self).baseAddress!
            guard bytes[0] == magic[0], bytes[1] == magic[1], bytes[2] == version,
                  let type = ControllerMessageType(compactWireCode: bytes[3]),
                  type != .button, type != .elementInput,
                  bytes[12] == emptyField, bytes[13] == emptyField
            else { return nil }
            return ControllerMessage(type: type, timestamp: Int64(bitPattern: readLittleEndian(from: bytes, startingAt: 4)))
        }
    }

    private static func compactInputMessage(from data: Data) -> ControllerMessage? {
        data.withUnsafeBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self).baseAddress!
            guard bytes[0] == magic[0], bytes[1] == magic[1], bytes[2] == inputVersion,
                  let type = ControllerMessageType(compactWireCode: bytes[3]),
                  type == .button || type == .elementInput,
                  Int(bytes[20]) < KeypadElementInputPart.allCases.count,
                  type != .button || bytes[20] == 0,
                  let state = ButtonPressState(compactWireCode: bytes[21]),
                  bytes[22] & ~15 == 0, bytes[23] == 0
            else { return nil }
            let uuid = UUID(uuid: (
                bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15], bytes[16], bytes[17], bytes[18], bytes[19]
            ))
            let flags = bytes[22]
            return ControllerMessage(
                type: type,
                button: type == .button ? KeypadElementID(uuid) : nil,
                elementID: type == .elementInput ? uuid : nil,
                elementPart: type == .elementInput ? KeypadElementInputPart.allCases[Int(bytes[20])] : nil,
                state: state,
                timestamp: Int64(bitPattern: readLittleEndian(from: bytes, startingAt: 48)),
                inputProtocolVersion: flags & 8 == 0 ? nil : currentInputProtocolVersion,
                inputGeneration: flags & 2 == 0 ? nil : readLittleEndian(from: bytes, startingAt: 24),
                inputSequence: flags & 4 == 0 ? nil : readLittleEndian(from: bytes, startingAt: 32),
                pressIdentifier: flags & 1 == 0 ? nil : readLittleEndian(from: bytes, startingAt: 40)
            )
        }
    }
}

private extension ControllerMessageType {
    var compactWireCode: UInt8? {
        switch self {
        case .button: 1
        case .elementInput: 6
        case .releaseAll: 2
        case .heartbeat: 3
        case .ping: 4
        case .pong: 5
        case .hello, .pairingRequest, .pairingChallenge, .pairingAccepted, .pointer, .gamepadAnalog, .gamepadCustomization, .gamepadProfiles, .skinPackages, .skinPackageRemoval, .gamepadProfileSkinSelection, .gamepadProfileSelection, .gamepadDefaultProfile, .gamepadProfileOrientationPreferenceMutation, .launchProfileTarget, .profileArtifactAdoptionBegin, .profileArtifactAdoptionChunk, .profileArtifactAdoptionCommit, .profileArtifactAdoptionCancel, .profileArtifactAdoptionResult, .error: nil
        }
    }

    init?(compactWireCode: UInt8) {
        switch compactWireCode {
        case 1: self = .button
        case 6: self = .elementInput
        case 2: self = .releaseAll
        case 3: self = .heartbeat
        case 4: self = .ping
        case 5: self = .pong
        default: return nil
        }
    }
}

private extension ButtonPressState {
    var compactWireCode: UInt8 {
        switch self {
        case .down: 1
        case .up: 2
        }
    }

    init?(compactWireCode: UInt8) {
        switch compactWireCode {
        case 1: self = .down
        case 2: self = .up
        default: return nil
        }
    }
}

public extension Date {
    static var currentMilliseconds: Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
