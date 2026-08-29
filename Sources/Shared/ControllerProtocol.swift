import Foundation

public enum GameButton: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case up
    case down
    case left
    case right
    case jump
    case attack
    case dash
    case focus
    case map
    case pause
    case custom1
    case custom2
    case custom3
    case custom4
    case custom5
    case custom6
    case custom7
    case custom8

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .up: "Up"
        case .down: "Down"
        case .left: "Left"
        case .right: "Right"
        case .jump: "Action 1"
        case .attack: "Action 2"
        case .dash: "Action 3"
        case .focus: "Action 4"
        case .map: "Menu"
        case .pause: "Pause"
        case .custom1: "Custom Key 1"
        case .custom2: "Custom Key 2"
        case .custom3: "Custom Key 3"
        case .custom4: "Custom Key 4"
        case .custom5: "Custom Key 5"
        case .custom6: "Custom Key 6"
        case .custom7: "Custom Key 7"
        case .custom8: "Custom Key 8"
        }
    }

    static var builtInControls: [GameButton] {
        [.up, .down, .left, .right, .jump, .attack, .dash, .focus, .map, .pause]
    }

    static var customSlots: [GameButton] {
        [.custom1, .custom2, .custom3, .custom4, .custom5, .custom6, .custom7, .custom8]
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
    public var button: GameButton?
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
    public var pressedButtons: [GameButton]?
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
        button: GameButton? = nil,
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
        pressedButtons: [GameButton]? = nil,
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
    public var button: GameButton?
    public var elementInput: KeypadElementInputID?
    public var reason: String?

    public init(
        command: ThumbleMacCLICommand,
        button: GameButton? = nil,
        elementInput: KeypadElementInputID? = nil,
        reason: String? = nil
    ) {
        self.command = command
        self.button = button
        self.elementInput = elementInput
        self.reason = reason
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
    public var pressedButtons: [GameButton]
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
        pressedButtons: [GameButton],
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
        captureLogPath: String? = nil
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
    public var button: GameButton?
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

    public init(
        type: ControllerMessageType,
        button: GameButton? = nil,
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
        profileArtifactAdoptionResult: ProfileArtifactAdoptionResult? = nil
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
    public static let currentInputProtocolVersion = 2
    public static let maximumInboundPayloadSize = 8 * 1024 * 1024

    private static let magic: [UInt8] = [0x50, 0x50] // "PP"
    private static let version: UInt8 = 1
    private static let inputVersion: UInt8 = UInt8(currentInputProtocolVersion)
    private static let emptyField: UInt8 = UInt8.max
    private static let compactMessageSize = 14
    // v2 button: 0...1 magic, 2 version, 3 type, 4 button, 5 state, 6 flags,
    // 7 reserved, 8...15 generation LE, 16...23 sequence LE, 24...31 press identifier LE.
    private static let compactInputMessageSize = 32
    private static let compactInputPressIdentifierPresent: UInt8 = 1 << 0
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
    private static let buttonDownFrames = GameButton.allCases.map {
        compactData(
            typeCode: ControllerMessageType.button.compactWireCode!,
            timestamp: 0,
            buttonCode: $0.compactWireCode,
            stateCode: ButtonPressState.down.compactWireCode
        )
    }
    private static let buttonUpFrames = GameButton.allCases.map {
        compactData(
            typeCode: ControllerMessageType.button.compactWireCode!,
            timestamp: 0,
            buttonCode: $0.compactWireCode,
            stateCode: ButtonPressState.up.compactWireCode
        )
    }

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
                try decoder.decode(ControllerMessage.self, from: data)
            }
        }
        return try decoder.decode(ControllerMessage.self, from: data)
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

    public static func encodeButton(_ button: GameButton, state: ButtonPressState) -> Data {
        switch state {
        case .down: buttonDownFrames[button.compactFrameIndex]
        case .up: buttonUpFrames[button.compactFrameIndex]
        }
    }

    public static func encodeButton(
        _ button: GameButton,
        state: ButtonPressState,
        sequenceNumber: UInt64,
        pressIdentifier: UInt64? = nil,
        generation: UInt64? = nil
    ) -> Data {
        if let generation {
            return compactInputData(
                button: button,
                state: state,
                generation: generation,
                sequenceNumber: sequenceNumber,
                pressIdentifier: pressIdentifier
            )
        }

        return compactData(
            typeCode: ControllerMessageType.button.compactWireCode!,
            timestamp: buttonSequenceTimestamp(
                for: sequenceNumber,
                pressIdentifier: pressIdentifier
            ),
            buttonCode: button.compactWireCode,
            stateCode: state.compactWireCode
        )
    }

    public static func inputSequenceTimestamp(
        for sequenceNumber: UInt64,
        pressIdentifier: UInt64? = nil
    ) -> Int64 {
        buttonSequenceTimestamp(for: sequenceNumber, pressIdentifier: pressIdentifier)
    }

    public static func buttonSequenceNumber(from message: ControllerMessage) -> UInt64? {
        inputSequenceNumber(from: message)
    }

    public static func inputSequenceNumber(from message: ControllerMessage) -> UInt64? {
        if let inputSequence = message.inputSequence {
            return inputSequence
        }
        guard message.type == .button || message.type == .elementInput else { return nil }

        let timestampBits = UInt64(bitPattern: message.timestamp)
        guard timestampBits & buttonSequenceMarker == buttonSequenceMarker else { return nil }

        let sequenceNumber = timestampBits & buttonSequenceMask
        return sequenceNumber == 0 ? nil : sequenceNumber
    }

    public static func buttonPressIdentifier(from message: ControllerMessage) -> UInt64? {
        inputPressIdentifier(from: message)
    }

    public static func inputPressIdentifier(from message: ControllerMessage) -> UInt64? {
        if let pressIdentifier = message.pressIdentifier {
            return pressIdentifier
        }
        guard message.type == .button || message.type == .elementInput else { return nil }

        let timestampBits = UInt64(bitPattern: message.timestamp)
        guard timestampBits & buttonSequenceMarker == buttonSequenceMarker else { return nil }

        let pressIdentifier = (timestampBits >> buttonPressIdentifierShift) & buttonPressIdentifierMask
        return pressIdentifier == 0 ? nil : pressIdentifier
    }

    private static func compactData(for message: ControllerMessage) -> Data? {
        guard message.pairingCode == nil,
              message.clientName == nil,
              message.message == nil,
              message.realtimeToken == nil,
              message.authToken == nil,
              message.serverID == nil,
              message.elementID == nil,
              message.elementPart == nil,
              message.gamepadCustomization == nil,
              message.gamepadProfiles == nil,
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
              let typeCode = message.type.compactWireCode
        else {
            return nil
        }

        let hasInputProtocolFields = message.inputProtocolVersion != nil
            || message.inputGeneration != nil
            || message.inputSequence != nil
            || message.pressIdentifier != nil
        if hasInputProtocolFields {
            guard message.type == .button,
                  message.inputProtocolVersion == currentInputProtocolVersion,
                  let button = message.button,
                  let state = message.state,
                  let generation = message.inputGeneration,
                  let sequenceNumber = message.inputSequence
            else {
                return nil
            }
            return compactInputData(
                button: button,
                state: state,
                generation: generation,
                sequenceNumber: sequenceNumber,
                pressIdentifier: message.pressIdentifier
            )
        }

        if message.type == .button, (message.button == nil || message.state == nil) {
            return nil
        }

        return compactData(
            typeCode: typeCode,
            timestamp: message.timestamp,
            buttonCode: message.button?.compactWireCode,
            stateCode: message.state?.compactWireCode
        )
    }

    private static func compactData(
        typeCode: UInt8,
        timestamp: Int64,
        buttonCode: UInt8?,
        stateCode: UInt8?
    ) -> Data {
        var data = Data(count: compactMessageSize)
        data.withUnsafeMutableBytes { rawBuffer in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }

            bytes[0] = magic[0]
            bytes[1] = magic[1]
            bytes[2] = version
            bytes[3] = typeCode

            let timestampBits = UInt64(bitPattern: timestamp)
            for offset in 0..<8 {
                bytes[4 + offset] = UInt8(truncatingIfNeeded: timestampBits >> UInt64(offset * 8))
            }

            bytes[12] = buttonCode ?? emptyField
            bytes[13] = stateCode ?? emptyField
        }
        return data
    }

    private static func compactInputData(
        button: GameButton,
        state: ButtonPressState,
        generation: UInt64,
        sequenceNumber: UInt64,
        pressIdentifier: UInt64?
    ) -> Data {
        var data = Data(count: compactInputMessageSize)
        data.withUnsafeMutableBytes { rawBuffer in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }

            bytes[0] = magic[0]
            bytes[1] = magic[1]
            bytes[2] = inputVersion
            bytes[3] = ControllerMessageType.button.compactWireCode!
            bytes[4] = button.compactWireCode
            bytes[5] = state.compactWireCode
            bytes[6] = pressIdentifier == nil ? 0 : compactInputPressIdentifierPresent
            bytes[7] = 0
            writeLittleEndian(generation, to: bytes, startingAt: 8)
            writeLittleEndian(sequenceNumber, to: bytes, startingAt: 16)
            writeLittleEndian(pressIdentifier ?? 0, to: bytes, startingAt: 24)
        }
        return data
    }

    private static func writeLittleEndian(
        _ value: UInt64,
        to bytes: UnsafeMutablePointer<UInt8>,
        startingAt start: Int
    ) {
        for offset in 0..<8 {
            bytes[start + offset] = UInt8(truncatingIfNeeded: value >> UInt64(offset * 8))
        }
    }

    private static func readLittleEndian(
        from bytes: UnsafePointer<UInt8>,
        startingAt start: Int
    ) -> UInt64 {
        var value: UInt64 = 0
        for offset in 0..<8 {
            value |= UInt64(bytes[start + offset]) << UInt64(offset * 8)
        }
        return value
    }

    private static func buttonSequenceTimestamp(
        for sequenceNumber: UInt64,
        pressIdentifier: UInt64?
    ) -> Int64 {
        let boundedSequenceNumber = min(max(sequenceNumber, 1), maximumButtonSequenceNumber)
        let boundedPressIdentifier = min(pressIdentifier ?? 0, maximumButtonPressIdentifier)
        let pressIdentifierBits = boundedPressIdentifier << buttonPressIdentifierShift
        return Int64(bitPattern: buttonSequenceMarker | pressIdentifierBits | boundedSequenceNumber)
    }

    private static func compactMessage(from data: Data) -> ControllerMessage? {
        if data.count == compactInputMessageSize {
            return compactInputMessage(from: data)
        }
        guard data.count == compactMessageSize else { return nil }

        return data.withUnsafeBytes { rawBuffer -> ControllerMessage? in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress,
                  bytes[0] == magic[0],
                  bytes[1] == magic[1],
                  bytes[2] == version,
                  let type = ControllerMessageType(compactWireCode: bytes[3])
            else {
                return nil
            }

            var timestampBits: UInt64 = 0
            for offset in 0..<8 {
                timestampBits |= UInt64(bytes[4 + offset]) << UInt64(offset * 8)
            }

            let button = bytes[12] == emptyField ? nil : GameButton(compactWireCode: bytes[12])
            let state = bytes[13] == emptyField ? nil : ButtonPressState(compactWireCode: bytes[13])

            if type == .button, (button == nil || state == nil) {
                return nil
            }

            return ControllerMessage(
                type: type,
                button: button,
                state: state,
                timestamp: Int64(bitPattern: timestampBits)
            )
        }
    }

    private static func compactInputMessage(from data: Data) -> ControllerMessage? {
        data.withUnsafeBytes { rawBuffer -> ControllerMessage? in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress,
                  bytes[0] == magic[0],
                  bytes[1] == magic[1],
                  bytes[2] == inputVersion,
                  bytes[3] == ControllerMessageType.button.compactWireCode!,
                  bytes[6] & ~compactInputPressIdentifierPresent == 0,
                  bytes[7] == 0,
                  let button = GameButton(compactWireCode: bytes[4]),
                  let state = ButtonPressState(compactWireCode: bytes[5])
            else {
                return nil
            }

            let hasPressIdentifier = bytes[6] & compactInputPressIdentifierPresent != 0
            return ControllerMessage(
                type: .button,
                button: button,
                state: state,
                timestamp: 0,
                inputProtocolVersion: currentInputProtocolVersion,
                inputGeneration: readLittleEndian(from: bytes, startingAt: 8),
                inputSequence: readLittleEndian(from: bytes, startingAt: 16),
                pressIdentifier: hasPressIdentifier
                    ? readLittleEndian(from: bytes, startingAt: 24)
                    : nil
            )
        }
    }
}

private extension ControllerMessageType {
    var compactWireCode: UInt8? {
        switch self {
        case .button: 1
        case .releaseAll: 2
        case .heartbeat: 3
        case .ping: 4
        case .pong: 5
        case .hello, .pairingRequest, .pairingChallenge, .pairingAccepted, .elementInput, .pointer, .gamepadAnalog, .gamepadCustomization, .gamepadProfiles, .skinPackages, .skinPackageRemoval, .gamepadProfileSkinSelection, .gamepadProfileSelection, .gamepadDefaultProfile, .gamepadProfileOrientationPreferenceMutation, .launchProfileTarget, .profileArtifactAdoptionBegin, .profileArtifactAdoptionChunk, .profileArtifactAdoptionCommit, .profileArtifactAdoptionCancel, .profileArtifactAdoptionResult, .error: nil
        }
    }

    init?(compactWireCode: UInt8) {
        switch compactWireCode {
        case 1: self = .button
        case 2: self = .releaseAll
        case 3: self = .heartbeat
        case 4: self = .ping
        case 5: self = .pong
        default: return nil
        }
    }
}

private extension GameButton {
    var compactFrameIndex: Int {
        Int(compactWireCode - 1)
    }

    var compactWireCode: UInt8 {
        switch self {
        case .up: 1
        case .down: 2
        case .left: 3
        case .right: 4
        case .jump: 5
        case .attack: 6
        case .dash: 7
        case .focus: 8
        case .map: 9
        case .pause: 10
        case .custom1: 11
        case .custom2: 12
        case .custom3: 13
        case .custom4: 14
        case .custom5: 15
        case .custom6: 16
        case .custom7: 17
        case .custom8: 18
        }
    }

    init?(compactWireCode: UInt8) {
        switch compactWireCode {
        case 1: self = .up
        case 2: self = .down
        case 3: self = .left
        case 4: self = .right
        case 5: self = .jump
        case 6: self = .attack
        case 7: self = .dash
        case 8: self = .focus
        case 9: self = .map
        case 10: self = .pause
        case 11: self = .custom1
        case 12: self = .custom2
        case 13: self = .custom3
        case 14: self = .custom4
        case 15: self = .custom5
        case 16: self = .custom6
        case 17: self = .custom7
        case 18: self = .custom8
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
