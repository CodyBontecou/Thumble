import Darwin
import Foundation
import Network
import UIKit

private final class ControllerInputTransport {
    private struct ButtonSendSnapshot {
        let protocolVersion: Int?
        let generation: UInt64?
        let sequenceNumber: UInt64
        let mirrorGeneration: UInt64
        let reliableConnection: NWConnection
        let datagramConnection: NWConnection?
    }

    private enum AnalogPayload {
        case stick(VirtualGamepadStick, x: Double, y: Double)
        case trigger(VirtualGamepadTrigger, value: Double)

        var key: String {
            switch self {
            case .stick(let stick, _, _): "stick.\(stick.rawValue)"
            case .trigger(let trigger, _): "trigger.\(trigger.rawValue)"
            }
        }
    }

    private let networkQueue: DispatchQueue
    private let lock = NSLock()
    private var reliableConnection: NWConnection?
    private var realtimeDatagramConnection: NWConnection?
    private var isRealtimeDatagramReady = false
    private var inputProtocolVersion = 1
    private var inputGeneration: UInt64?
    private var mirrorGeneration: UInt64 = 0
    private var buttonSequenceNumber: UInt64 = 0
    private var pointerSequenceNumber: UInt64 = 0
    private var lastPointerTimestamp: Int64 = 0
    private var activeButtons = ControllerActiveInputState()
    private var activeElementIdentifiers: [KeypadElementInputID: Set<UInt64>] = [:]
    private var activeAnonymousElementCounts: [KeypadElementInputID: Int] = [:]
    private var heartbeatTimer: DispatchSourceTimer?
    private var analogSequenceNumber: UInt64 = 0
    private var activeStickValues: [VirtualGamepadStick: (x: Double, y: Double)] = [:]
    private var activeTriggerValues: [VirtualGamepadTrigger: Double] = [:]
    private var lastAnalogSendUptimeByKey: [String: UInt64] = [:]
    private var pendingAnalogPayloads: [String: AnalogPayload] = [:]
    private var pendingAnalogWorkItems: [String: DispatchWorkItem] = [:]
    private let binaryMessageContext = NWConnection.ContentContext(
        identifier: "ThumbleInputMessage",
        metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)]
    )
    private let encoder = JSONEncoder()

    // Keep TCP close behind UDP so packet-loss recovery stays below a tight
    // action-game frame budget while the UDP fast path still wins normal races.
    private static let reliableMirrorDelayNanoseconds: Int = 500_000
    // Keep several refresh opportunities inside the Mac's stale-hold window.
    // Physical iOS runs can coalesce 500 ms timers to roughly 1.5 seconds.
    private static let heartbeatIntervalNanoseconds: UInt64 = 250_000_000
    private static let analogSendIntervalNanoseconds: UInt64 = 16_000_000

    init(networkQueue: DispatchQueue) {
        self.networkQueue = networkQueue
    }

    func setReliableConnection(
        _ connection: NWConnection?,
        resetSequence: Bool,
        inputProtocolVersion: Int
    ) {
        lock.lock()
        reliableConnection = connection
        self.inputProtocolVersion = inputProtocolVersion
        if resetSequence {
            buttonSequenceNumber = 0
            pointerSequenceNumber = 0
            lastPointerTimestamp = 0
            mirrorGeneration &+= 1
            if inputProtocolVersion >= ControllerWireCodec.currentInputProtocolVersion {
                inputGeneration = Self.newInputGeneration()
            } else {
                inputGeneration = nil
            }
            activeButtons.removeAll()
            activeElementIdentifiers.removeAll()
            activeAnonymousElementCounts.removeAll()
        }
        lock.unlock()
        startHeartbeatTimer()
    }

    func setRealtimeDatagramConnection(_ connection: NWConnection?, ready: Bool) {
        lock.lock()
        realtimeDatagramConnection = connection
        isRealtimeDatagramReady = connection != nil && ready
        lock.unlock()
    }

    func setRealtimeDatagramReady(_ ready: Bool, for connection: NWConnection) {
        lock.lock()
        if realtimeDatagramConnection === connection {
            isRealtimeDatagramReady = ready
        }
        lock.unlock()
    }

    func clearRealtimeDatagramConnection(_ connection: NWConnection?) {
        lock.lock()
        if connection == nil || realtimeDatagramConnection === connection {
            realtimeDatagramConnection = nil
            isRealtimeDatagramReady = false
        }
        lock.unlock()
    }

    func disconnect() {
        lock.lock()
        reliableConnection = nil
        realtimeDatagramConnection = nil
        isRealtimeDatagramReady = false
        inputProtocolVersion = 1
        inputGeneration = nil
        mirrorGeneration &+= 1
        buttonSequenceNumber = 0
        pointerSequenceNumber = 0
        lastPointerTimestamp = 0
        activeButtons.removeAll()
        activeElementIdentifiers.removeAll()
        activeAnonymousElementCounts.removeAll()
        lock.unlock()

        networkQueue.async { [weak self] in
            guard let self else { return }
            self.heartbeatTimer?.cancel()
            self.heartbeatTimer = nil
            self.resetAnalogStateOnNetworkQueue()
        }
    }

    @discardableResult
    func sendButton(
        _ button: GameButton,
        state: ButtonPressState,
        pressIdentifier: UInt64?
    ) -> Bool {
        guard let snapshot = makeButtonSendSnapshot(
            recording: button,
            state: state,
            pressIdentifier: pressIdentifier
        ) else { return false }

        let messageContext = binaryMessageContext
        let sendQueue = networkQueue
        sendQueue.async { [weak self] in
            guard let self else { return }
            let data = ControllerWireCodec.encodeButton(
                button,
                state: state,
                sequenceNumber: snapshot.sequenceNumber,
                pressIdentifier: pressIdentifier,
                generation: snapshot.generation
            )
            self.sendRealtimeInputData(data, snapshot: snapshot, context: messageContext)
        }

        return true
    }

    @discardableResult
    func sendElementInput(
        _ input: KeypadElementInputID,
        state: ButtonPressState,
        pressIdentifier: UInt64?
    ) -> Bool {
        guard let snapshot = makeElementSendSnapshot(
            recording: input,
            state: state,
            pressIdentifier: pressIdentifier
        ) else { return false }

        let messageContext = binaryMessageContext
        let sendQueue = networkQueue
        let encoder = encoder
        sendQueue.async { [weak self] in
            guard let self else { return }
            let message = ControllerMessage(
                type: .elementInput,
                elementID: input.elementID,
                elementPart: input.part,
                state: state,
                timestamp: snapshot.generation == nil
                    ? ControllerWireCodec.inputSequenceTimestamp(
                        for: snapshot.sequenceNumber,
                        pressIdentifier: pressIdentifier
                    )
                    : 0,
                inputProtocolVersion: snapshot.protocolVersion,
                inputGeneration: snapshot.generation,
                inputSequence: snapshot.sequenceNumber,
                pressIdentifier: pressIdentifier
            )
            guard let data = try? ControllerWireCodec.encode(message, using: encoder) else { return }
            self.sendRealtimeInputData(data, snapshot: snapshot, context: messageContext)
        }

        return true
    }

    private func makeButtonSendSnapshot(
        recording button: GameButton? = nil,
        state: ButtonPressState? = nil,
        pressIdentifier: UInt64? = nil,
        expectedMirrorGeneration: UInt64? = nil,
        refreshing press: ControllerActiveInputPress? = nil
    ) -> ButtonSendSnapshot? {
        lock.lock()
        defer { lock.unlock() }

        let isRefreshStillActive = press.map { activeButtons.activePresses.contains($0) } ?? true
        guard let reliableConnection,
              expectedMirrorGeneration == nil || expectedMirrorGeneration == mirrorGeneration,
              isRefreshStillActive
        else { return nil }
        if let button, let state {
            activeButtons.record(button: button, state: state, pressIdentifier: pressIdentifier)
        }
        return makeButtonSendSnapshotLocked(reliableConnection: reliableConnection)
    }

    private func makeElementSendSnapshot(
        recording input: KeypadElementInputID? = nil,
        state: ButtonPressState? = nil,
        pressIdentifier: UInt64? = nil,
        expectedMirrorGeneration: UInt64? = nil,
        refreshing press: ControllerActiveElementInputPress? = nil
    ) -> ButtonSendSnapshot? {
        lock.lock()
        defer { lock.unlock() }

        let isRefreshStillActive = press.map(isActiveElementPressLocked) ?? true
        guard let reliableConnection,
              expectedMirrorGeneration == nil || expectedMirrorGeneration == mirrorGeneration,
              isRefreshStillActive
        else { return nil }
        if let input, let state {
            recordActiveElementLocked(input, state: state, pressIdentifier: pressIdentifier)
        }
        return makeButtonSendSnapshotLocked(reliableConnection: reliableConnection)
    }

    private func makeButtonSendSnapshotLocked(reliableConnection: NWConnection) -> ButtonSendSnapshot {
        let sequenceNumber = nextButtonSequenceNumber()
        let datagramConnection = isRealtimeDatagramReady ? realtimeDatagramConnection : nil
        return ButtonSendSnapshot(
            protocolVersion: inputGeneration == nil ? nil : inputProtocolVersion,
            generation: inputGeneration,
            sequenceNumber: sequenceNumber,
            mirrorGeneration: mirrorGeneration,
            reliableConnection: reliableConnection,
            datagramConnection: datagramConnection
        )
    }

    private func nextButtonSequenceNumber() -> UInt64 {
        if buttonSequenceNumber >= ControllerWireCodec.maximumButtonSequenceNumber {
            buttonSequenceNumber = 1
        } else {
            buttonSequenceNumber += 1
        }
        return buttonSequenceNumber
    }

    private func sendRealtimeInputData(
        _ data: Data,
        snapshot: ButtonSendSnapshot,
        context: NWConnection.ContentContext
    ) {
        if let datagramConnection = snapshot.datagramConnection {
            datagramConnection.send(
                content: data,
                contentContext: .defaultMessage,
                isComplete: true,
                completion: .idempotent
            )
            sendReliableMirror(data, snapshot: snapshot, context: context, queue: networkQueue)
        } else {
            snapshot.reliableConnection.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .idempotent
            )
        }
    }

    private func sendReliableMirror(
        _ data: Data,
        snapshot: ButtonSendSnapshot,
        context: NWConnection.ContentContext,
        queue: DispatchQueue
    ) {
        queue.asyncAfter(deadline: .now() + .nanoseconds(Self.reliableMirrorDelayNanoseconds)) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let isCurrent = self.mirrorGeneration == snapshot.mirrorGeneration
                && self.reliableConnection === snapshot.reliableConnection
            self.lock.unlock()
            guard isCurrent else { return }
            snapshot.reliableConnection.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .idempotent
            )
        }
    }

    @discardableResult
    func releaseAll(adoptingGeneration: UInt64? = nil) -> Bool {
        lock.lock()
        guard let reliableConnection else {
            activeButtons.removeAll()
            activeElementIdentifiers.removeAll()
            activeAnonymousElementCounts.removeAll()
            lock.unlock()
            networkQueue.async { [weak self] in self?.resetAnalogStateOnNetworkQueue() }
            return false
        }

        mirrorGeneration &+= 1
        if inputProtocolVersion >= ControllerWireCodec.currentInputProtocolVersion {
            inputGeneration = adoptingGeneration ?? Self.nextGeneration(after: inputGeneration)
        } else {
            inputGeneration = nil
        }
        buttonSequenceNumber = 0
        activeButtons.removeAll()
        activeElementIdentifiers.removeAll()
        activeAnonymousElementCounts.removeAll()
        let generation = inputGeneration
        let protocolVersion = inputProtocolVersion
        let datagramConnection = isRealtimeDatagramReady ? realtimeDatagramConnection : nil
        lock.unlock()

        networkQueue.async { [weak self] in
            guard let self else { return }
            self.resetAnalogStateOnNetworkQueue()
            let message = ControllerMessage(
                type: .releaseAll,
                timestamp: 0,
                inputProtocolVersion: protocolVersion,
                inputGeneration: generation
            )
            guard let data = try? ControllerWireCodec.encode(message, using: self.encoder) else { return }
            if let datagramConnection {
                datagramConnection.send(
                    content: data,
                    contentContext: .defaultMessage,
                    isComplete: true,
                    completion: .idempotent
                )
            }
            reliableConnection.send(
                content: data,
                contentContext: self.binaryMessageContext,
                isComplete: true,
                completion: .idempotent
            )
        }
        return true
    }

    @discardableResult
    func sendGamepadStick(
        _ stick: VirtualGamepadStick,
        x: Double,
        y: Double,
        isFinal: Bool
    ) -> Bool {
        guard let expectedMirrorGeneration = currentMirrorGenerationIfConnected else { return false }
        networkQueue.async { [weak self] in
            self?.queueAnalogPayload(
                .stick(stick, x: x, y: y),
                isFinal: isFinal,
                expectedMirrorGeneration: expectedMirrorGeneration
            )
        }
        return true
    }

    @discardableResult
    func sendGamepadTrigger(
        _ trigger: VirtualGamepadTrigger,
        value: Double,
        isFinal: Bool
    ) -> Bool {
        guard let expectedMirrorGeneration = currentMirrorGenerationIfConnected else { return false }
        networkQueue.async { [weak self] in
            self?.queueAnalogPayload(
                .trigger(trigger, value: value),
                isFinal: isFinal,
                expectedMirrorGeneration: expectedMirrorGeneration
            )
        }
        return true
    }

    func decoratingRealtimeMessage(_ message: ControllerMessage) -> ControllerMessage {
        lock.lock()
        defer { lock.unlock() }
        var decorated = message
        pointerSequenceNumber = pointerSequenceNumber == UInt64.max ? 1 : pointerSequenceNumber + 1
        let wallClockTimestamp = Date.currentMilliseconds
        lastPointerTimestamp = max(wallClockTimestamp, lastPointerTimestamp + 1)
        decorated.timestamp = lastPointerTimestamp
        if inputProtocolVersion >= ControllerWireCodec.currentInputProtocolVersion {
            decorated.inputProtocolVersion = inputProtocolVersion
            decorated.inputGeneration = inputGeneration
            decorated.inputSequence = pointerSequenceNumber
        }
        return decorated
    }

    private var currentMirrorGenerationIfConnected: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return reliableConnection == nil ? nil : mirrorGeneration
    }

    private func isCurrentMirrorGeneration(_ expected: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return reliableConnection != nil && mirrorGeneration == expected
    }

    private func queueAnalogPayload(
        _ payload: AnalogPayload,
        isFinal: Bool,
        expectedMirrorGeneration: UInt64
    ) {
        guard isCurrentMirrorGeneration(expectedMirrorGeneration) else { return }
        switch payload {
        case .stick(let stick, let x, let y):
            if abs(x) < 0.001, abs(y) < 0.001 {
                activeStickValues[stick] = nil
            } else {
                activeStickValues[stick] = (x, y)
            }
        case .trigger(let trigger, let value):
            activeTriggerValues[trigger] = value < 0.001 ? nil : value
        }

        let key = payload.key
        let now = DispatchTime.now().uptimeNanoseconds
        let last = lastAnalogSendUptimeByKey[key] ?? 0
        if isFinal || now >= last + Self.analogSendIntervalNanoseconds {
            pendingAnalogWorkItems[key]?.cancel()
            pendingAnalogWorkItems[key] = nil
            pendingAnalogPayloads[key] = nil
            sendAnalogPayloadOnNetworkQueue(
                payload,
                mirrorsReliably: isFinal,
                expectedMirrorGeneration: expectedMirrorGeneration
            )
            return
        }

        pendingAnalogPayloads[key] = payload
        guard pendingAnalogWorkItems[key] == nil else { return }
        let remaining = last + Self.analogSendIntervalNanoseconds - now
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingAnalogWorkItems[key] = nil
            guard self.isCurrentMirrorGeneration(expectedMirrorGeneration),
                  let latest = self.pendingAnalogPayloads.removeValue(forKey: key)
            else { return }
            self.sendAnalogPayloadOnNetworkQueue(
                latest,
                mirrorsReliably: false,
                expectedMirrorGeneration: expectedMirrorGeneration
            )
        }
        pendingAnalogWorkItems[key] = workItem
        networkQueue.asyncAfter(deadline: .now() + .nanoseconds(Int(remaining)), execute: workItem)
    }

    private func sendAnalogPayloadOnNetworkQueue(
        _ payload: AnalogPayload,
        mirrorsReliably: Bool,
        expectedMirrorGeneration: UInt64
    ) {
        lock.lock()
        guard mirrorGeneration == expectedMirrorGeneration,
              let reliableConnection
        else {
            lock.unlock()
            return
        }
        let datagramConnection = isRealtimeDatagramReady ? realtimeDatagramConnection : nil
        let protocolVersion = inputGeneration == nil ? nil : inputProtocolVersion
        let generation = inputGeneration
        lock.unlock()

        analogSequenceNumber = analogSequenceNumber >= ControllerWireCodec.maximumButtonSequenceNumber
            ? 1
            : analogSequenceNumber + 1
        let message: ControllerMessage
        switch payload {
        case .stick(let stick, let x, let y):
            message = .init(
                type: .gamepadAnalog,
                timestamp: 0,
                analogStick: stick,
                analogX: x,
                analogY: y,
                analogSequence: analogSequenceNumber,
                inputProtocolVersion: protocolVersion,
                inputGeneration: generation
            )
        case .trigger(let trigger, let value):
            message = .init(
                type: .gamepadAnalog,
                timestamp: 0,
                analogTrigger: trigger,
                analogValue: value,
                analogSequence: analogSequenceNumber,
                inputProtocolVersion: protocolVersion,
                inputGeneration: generation
            )
        }
        guard let data = try? ControllerWireCodec.encode(message, using: encoder) else { return }

        if let datagramConnection {
            datagramConnection.send(
                content: data,
                contentContext: .defaultMessage,
                isComplete: true,
                completion: .idempotent
            )
            if mirrorsReliably {
                reliableConnection.send(
                    content: data,
                    contentContext: binaryMessageContext,
                    isComplete: true,
                    completion: .idempotent
                )
            }
        } else {
            reliableConnection.send(
                content: data,
                contentContext: binaryMessageContext,
                isComplete: true,
                completion: .idempotent
            )
        }
        lastAnalogSendUptimeByKey[payload.key] = DispatchTime.now().uptimeNanoseconds
    }

    private func resetAnalogStateOnNetworkQueue() {
        pendingAnalogWorkItems.values.forEach { $0.cancel() }
        pendingAnalogWorkItems.removeAll()
        pendingAnalogPayloads.removeAll()
        lastAnalogSendUptimeByKey.removeAll()
        activeStickValues.removeAll()
        activeTriggerValues.removeAll()
        analogSequenceNumber = 0
    }

    private func startHeartbeatTimer() {
        networkQueue.async { [weak self] in
            guard let self else { return }
            self.heartbeatTimer?.cancel()
            guard self.currentMirrorGenerationIfConnected != nil else {
                self.heartbeatTimer = nil
                return
            }
            let timer = DispatchSource.makeTimerSource(queue: self.networkQueue)
            timer.schedule(
                deadline: .now() + .nanoseconds(Int(Self.heartbeatIntervalNanoseconds)),
                repeating: .nanoseconds(Int(Self.heartbeatIntervalNanoseconds)),
                leeway: .milliseconds(20)
            )
            timer.setEventHandler { [weak self] in
                self?.sendHeartbeatOnNetworkQueue()
            }
            self.heartbeatTimer = timer
            timer.resume()
        }
    }

    private func sendHeartbeatOnNetworkQueue() {
        lock.lock()
        guard let reliableConnection else {
            lock.unlock()
            return
        }
        let generation = inputGeneration
        let protocolVersion = inputProtocolVersion
        let heartbeatMirrorGeneration = mirrorGeneration
        let buttonPresses = activeButtons.activePresses
        let elementPresses = activeElementIdentifiers.flatMap { input, identifiers in
            identifiers.map { ControllerActiveElementInputPress(input: input, pressIdentifier: $0) }
        } + activeAnonymousElementCounts.flatMap { input, count in
            Array(repeating: ControllerActiveElementInputPress(input: input, pressIdentifier: nil), count: count)
        }
        lock.unlock()

        let heartbeat = ControllerMessage(
            type: .heartbeat,
            timestamp: 0,
            inputProtocolVersion: protocolVersion,
            inputGeneration: generation
        )
        if let data = try? ControllerWireCodec.encode(heartbeat, using: encoder) {
            reliableConnection.send(
                content: data,
                contentContext: binaryMessageContext,
                isComplete: true,
                completion: .idempotent
            )
        }

        for press in buttonPresses {
            sendActiveButtonRefreshOnNetworkQueue(
                press,
                expectedMirrorGeneration: heartbeatMirrorGeneration
            )
        }
        for press in elementPresses {
            sendActiveElementRefreshOnNetworkQueue(
                press,
                expectedMirrorGeneration: heartbeatMirrorGeneration
            )
        }
        for (stick, value) in activeStickValues {
            sendAnalogPayloadOnNetworkQueue(
                .stick(stick, x: value.x, y: value.y),
                mirrorsReliably: false,
                expectedMirrorGeneration: heartbeatMirrorGeneration
            )
        }
        for (trigger, value) in activeTriggerValues {
            sendAnalogPayloadOnNetworkQueue(
                .trigger(trigger, value: value),
                mirrorsReliably: false,
                expectedMirrorGeneration: heartbeatMirrorGeneration
            )
        }
    }

    private func sendActiveButtonRefreshOnNetworkQueue(
        _ press: ControllerActiveInputPress,
        expectedMirrorGeneration: UInt64
    ) {
        guard let snapshot = makeButtonSendSnapshot(
            expectedMirrorGeneration: expectedMirrorGeneration,
            refreshing: press
        ) else { return }
        let data = ControllerWireCodec.encodeButton(
            press.button,
            state: .down,
            sequenceNumber: snapshot.sequenceNumber,
            pressIdentifier: press.pressIdentifier,
            generation: snapshot.generation
        )
        sendRealtimeInputData(data, snapshot: snapshot, context: binaryMessageContext)
    }

    private func sendActiveElementRefreshOnNetworkQueue(
        _ press: ControllerActiveElementInputPress,
        expectedMirrorGeneration: UInt64
    ) {
        guard let snapshot = makeElementSendSnapshot(
            expectedMirrorGeneration: expectedMirrorGeneration,
            refreshing: press
        ) else { return }
        let message = ControllerMessage(
            type: .elementInput,
            elementID: press.input.elementID,
            elementPart: press.input.part,
            state: .down,
            timestamp: snapshot.generation == nil
                ? ControllerWireCodec.inputSequenceTimestamp(
                    for: snapshot.sequenceNumber,
                    pressIdentifier: press.pressIdentifier
                )
                : 0,
            inputProtocolVersion: snapshot.protocolVersion,
            inputGeneration: snapshot.generation,
            inputSequence: snapshot.sequenceNumber,
            pressIdentifier: press.pressIdentifier
        )
        guard let data = try? ControllerWireCodec.encode(message, using: encoder) else { return }
        sendRealtimeInputData(data, snapshot: snapshot, context: binaryMessageContext)
    }

    private func isActiveElementPressLocked(_ press: ControllerActiveElementInputPress) -> Bool {
        if let pressIdentifier = press.pressIdentifier {
            return activeElementIdentifiers[press.input]?.contains(pressIdentifier) == true
        }
        return (activeAnonymousElementCounts[press.input] ?? 0) > 0
    }

    private func recordActiveElementLocked(
        _ input: KeypadElementInputID,
        state: ButtonPressState,
        pressIdentifier: UInt64?
    ) {
        switch (state, pressIdentifier) {
        case (.down, .some(let identifier)):
            activeElementIdentifiers[input, default: []].insert(identifier)
        case (.down, .none):
            activeAnonymousElementCounts[input, default: 0] += 1
        case (.up, .some(let identifier)):
            guard var identifiers = activeElementIdentifiers[input] else { return }
            identifiers.remove(identifier)
            activeElementIdentifiers[input] = identifiers.isEmpty ? nil : identifiers
        case (.up, .none):
            let next = max((activeAnonymousElementCounts[input] ?? 0) - 1, 0)
            activeAnonymousElementCounts[input] = next == 0 ? nil : next
        }
    }

    private static func newInputGeneration() -> UInt64 {
        UInt64.random(in: 1...UInt64.max)
    }

    private static func nextGeneration(after current: UInt64?) -> UInt64 {
        guard let current else { return newInputGeneration() }
        return current == UInt64.max ? 1 : current + 1
    }
}

private struct ControllerActiveElementInputPress: Equatable, Sendable {
    var input: KeypadElementInputID
    var pressIdentifier: UInt64?
}

private struct ControllerActiveElementInputState: Equatable, Sendable {
    private var identifiedPressesByInput: [KeypadElementInputID: Set<UInt64>] = [:]
    private var anonymousPressCountsByInput: [KeypadElementInputID: Int] = [:]

    var activePresses: [ControllerActiveElementInputPress] {
        var presses: [ControllerActiveElementInputPress] = []
        for input in Set(identifiedPressesByInput.keys).union(anonymousPressCountsByInput.keys).sorted(by: { $0.storageKey < $1.storageKey }) {
            for identifier in (identifiedPressesByInput[input] ?? []).sorted() {
                presses.append(.init(input: input, pressIdentifier: identifier))
            }
            let anonymousCount = anonymousPressCountsByInput[input] ?? 0
            for _ in 0..<anonymousCount {
                presses.append(.init(input: input, pressIdentifier: nil))
            }
        }
        return presses
    }

    var isEmpty: Bool {
        identifiedPressesByInput.isEmpty && anonymousPressCountsByInput.isEmpty
    }

    mutating func record(input: KeypadElementInputID, state: ButtonPressState, pressIdentifier: UInt64?) {
        switch state {
        case .down:
            if let pressIdentifier {
                identifiedPressesByInput[input, default: []].insert(pressIdentifier)
            } else {
                anonymousPressCountsByInput[input, default: 0] += 1
            }
        case .up:
            if let pressIdentifier {
                guard var identifiers = identifiedPressesByInput[input] else { return }
                identifiers.remove(pressIdentifier)
                identifiedPressesByInput[input] = identifiers.isEmpty ? nil : identifiers
            } else {
                guard let count = anonymousPressCountsByInput[input], count > 0 else { return }
                anonymousPressCountsByInput[input] = count == 1 ? nil : count - 1
            }
        }
    }

    mutating func removeAll() {
        identifiedPressesByInput.removeAll()
        anonymousPressCountsByInput.removeAll()
    }
}

private struct MacServiceResolution: Equatable {
    let serviceName: String
    let serviceType: String
    let serviceDomain: String
    let hostName: String?
    let port: Int
    let serverID: String?
    let displayName: String

    var endpoint: NWEndpoint {
        .service(name: serviceName, type: serviceType, domain: serviceDomain, interface: nil)
    }

    var url: URL? {
        guard let hostName, !hostName.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "ws"
        components.host = hostName
        components.port = port
        return components.url
    }
}

private enum ControllerConnectionTarget {
    case url(URL)
    case service(MacServiceResolution)

    var endpoint: NWEndpoint {
        switch self {
        case .url(let url):
            return .url(url)
        case .service(let resolution):
            return resolution.endpoint
        }
    }

    var displayURL: URL? {
        switch self {
        case .url(let url):
            return url
        case .service(let resolution):
            return resolution.url
        }
    }

    var serviceResolution: MacServiceResolution? {
        switch self {
        case .url:
            return nil
        case .service(let resolution):
            return resolution
        }
    }
}

private struct PendingSkinSelectionMutation: Codable, Equatable {
    var profileID: UUID
    var skinReference: ThumbleSkinReference?
    var updatedAt: Int64
}

@MainActor
final class ControllerClient: ObservableObject {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case pairingCodeRequired
        case connected
        case failed(String)

        var label: String {
            switch self {
            case .disconnected: "Disconnected"
            case .connecting: "Connecting…"
            case .pairingCodeRequired: "Enter pairing code"
            case .connected: "Connected"
            case .failed(let message): "Failed: \(message)"
            }
        }
    }

    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var lastSentEvent = "None"
    @Published private(set) var lastError: String?
    @Published private(set) var gamepadCustomization: GamepadCustomization
    @Published private(set) var gamepadProfiles: [GamepadConfigurationProfile]
    @Published private(set) var installedSkins: [ThumbleInstalledSkin]
    @Published private(set) var bindingPresentations: [GamepadProfileBindingPresentations]
    @Published private(set) var pendingKeypadLayoutEdits: [PendingKeypadLayoutEdit]
    @Published private(set) var selectedGamepadProfileID: UUID
    @Published private(set) var defaultGamepadProfileID: UUID
    @Published private(set) var serverCapabilities: Set<ControllerCapability> = []
    @Published private(set) var hasSavedKeypadSnapshot = false
    @Published private(set) var smartConnectStatus: String?
    @Published private(set) var isPracticeModeEnabled: Bool
    @Published private(set) var builderArtifactPracticePreview: IOSBuilderArtifactPracticePreview?
    @Published private(set) var builderArtifactAdoptionState: IOSBuilderArtifactAdoptionState?

    private let networkQueue = DispatchQueue(label: "Thumble.iOS.Network", qos: .userInteractive)
    private let skinStore: ThumbleSkinStore
    private var skinPackagesByReference: [ThumbleSkinReference: ThumbleSkinPackage]
    private var pendingSkinSelectionMutations: [PendingSkinSelectionMutation]
    private var pendingSkinRemovals: [ThumbleSkinReference]
    private let inputTransport: ControllerInputTransport
    private var connection: NWConnection?
    private var controlURL: URL?
    private var trustedMacCredential: TrustedMacCredential?
    private var currentAuthToken: String?
    private var currentExpectedServerID: String?
    private var currentServiceResolution: MacServiceResolution?
    private var smartDiscovery: MacServiceDiscovery?
    private var pairingDiscovery: MacServiceDiscovery?
    private var reconnectTask: Task<Void, Never>?
    private var autoReconnectEnabled = false
    private var realtimeDatagramConnection: NWConnection?
    private var isRealtimeDatagramReady = false
    private var realtimeDatagramHandshakeTask: Task<Void, Never>?
    private var lastSentEventUpdateTask: Task<Void, Never>?
    private var pendingLastSentEvent = "None"
    private let binaryMessageContext = NWConnection.ContentContext(
        identifier: "ThumbleMessage",
        metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)]
    )
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private static let liveInputStatusUpdatesEnabled = false
    private static let defaultPort: UInt16 = 8765
    private static let trustedMacCredentialDefaultsKey = "PocketPad.iOS.trustedMacCredential.v1"
    private static let hasSavedKeypadSnapshotDefaultsKey = "PocketPad.iOS.hasSavedKeypadSnapshot.v1"
    private static let pendingSkinSelectionDefaultsKey = "PocketPad.iOS.pendingSkinSelections.v1"
    private static let pendingSkinRemovalDefaultsKey = "PocketPad.iOS.pendingSkinRemovals.v1"

    private static func makeSkinStore() -> ThumbleSkinStore {
        if let store = try? ThumbleSkinStore() { return store }
        let fallback = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketPad-iOS-Skins", isDirectory: true)
        return try! ThumbleSkinStore(rootURL: fallback)
    }

    var isConnected: Bool {
        state == .connected
    }

    var canViewSavedKeypadOffline: Bool {
        hasSavedKeypadSnapshot || trustedMacCredential != nil
    }

    var savedKeypadMacName: String? {
        trustedMacCredential?.macName
    }

    var isAwaitingPairingCode: Bool {
        state == .pairingCodeRequired
    }

    var selectedGamepadProfile: GamepadConfigurationProfile? {
        gamepadProfiles.first { $0.id == selectedGamepadProfileID }
    }

    var selectedGamepadProfileName: String {
        selectedGamepadProfile?.name ?? "Keypad"
    }

    var isBuilderArtifactPracticePreviewActive: Bool {
        builderArtifactPracticePreview != nil
    }

    var renderedGamepadProfile: GamepadConfigurationProfile? {
        builderArtifactPracticePreview?.selectedProfile ?? selectedGamepadProfile
    }

    var renderedGamepadProfileName: String {
        renderedGamepadProfile?.name ?? "Keypad"
    }

    func bindingPresentation(
        profileID: UUID,
        orientation: GamepadEditorDeviceOrientation,
        input: KeypadElementInputID
    ) -> KeypadBindingPresentation? {
        bindingPresentations.bindingPresentation(
            profileID: profileID,
            orientation: orientation,
            input: input
        )
    }

    func bindingPresentation(
        orientation: GamepadEditorDeviceOrientation,
        input: KeypadElementInputID
    ) -> KeypadBindingPresentation? {
        bindingPresentation(
            profileID: selectedGamepadProfileID,
            orientation: orientation,
            input: input
        )
    }

    var isSelectedGamepadProfileDefault: Bool {
        selectedGamepadProfileID == defaultGamepadProfileID
    }

    var hasPendingKeypadLayoutEdits: Bool {
        !pendingKeypadLayoutEdits.isEmpty
    }

    var selectedGamepadProfileOrientationPreference: GamepadProfileOrientationPreference {
        selectedGamepadProfile?.orientationPreference ?? .automatic
    }

    var supportsGamepadProfileOrientationPreferenceMutation: Bool {
        isConnected && serverCapabilities.contains(.gamepadProfileOrientationPreferenceMutation)
    }

    var supportsProfileArtifactAdoptionV1: Bool {
        isConnected
            && serverCapabilities.contains(.profileArtifactAdoptionV1)
            && currentKeypadSyncServerID != nil
    }

    var pairedProfileArtifactAdoptionServerID: String? {
        supportsProfileArtifactAdoptionV1 ? currentKeypadSyncServerID : nil
    }

    init() {
        inputTransport = ControllerInputTransport(networkQueue: networkQueue)
        let loadedSkinStore = Self.makeSkinStore()
        try? loadedSkinStore.installBundledSkinsIfNeeded()
        let loadedSkins = (try? loadedSkinStore.installedSkins()) ?? []
        skinStore = loadedSkinStore
        installedSkins = loadedSkins
        skinPackagesByReference = Dictionary(uniqueKeysWithValues: loadedSkins.compactMap { installed in
            (try? loadedSkinStore.package(for: installed.reference)).map { (installed.reference, $0) }
        })
        pendingSkinSelectionMutations = Self.loadPendingSkinSelectionMutations()
        pendingSkinRemovals = Self.loadPendingSkinRemovals()
        isPracticeModeEnabled = IOSBuilderArtifactPracticePersistence.recoverPracticeModeValue(
            storedValue: UserDefaults.standard.bool(forKey: IOSKeypadPreferenceKeys.practiceMode)
        )
        builderArtifactPracticePreview = nil
        builderArtifactAdoptionState = nil
        let savedCustomization = GamepadCustomizationPersistence.load()
        let loadedProfileState = GamepadConfigurationProfilePersistence.load(activeCustomization: savedCustomization)
        let savedTrustedMacCredential = Self.loadTrustedMacCredential()
        let startupProfile = loadedProfileState.defaultProfile ?? loadedProfileState.activeProfile ?? loadedProfileState.profiles[0]
        let startupCustomization = startupProfile.customization.normalized

        gamepadCustomization = startupCustomization
        gamepadProfiles = loadedProfileState.profiles
        bindingPresentations = KeypadBindingPresentationPersistence.load()
        pendingKeypadLayoutEdits = PendingKeypadLayoutPersistence.load()
        selectedGamepadProfileID = startupProfile.id
        defaultGamepadProfileID = loadedProfileState.defaultProfileID
        GamepadCustomizationPersistence.save(startupCustomization)
        GamepadConfigurationProfilePersistence.save(
            loadedProfileState.profiles,
            activeProfileID: startupProfile.id,
            defaultProfileID: loadedProfileState.defaultProfileID
        )
        trustedMacCredential = savedTrustedMacCredential
        hasSavedKeypadSnapshot = Self.loadHasSavedKeypadSnapshot() || savedTrustedMacCredential != nil
        if hasSavedKeypadSnapshot {
            UserDefaults.standard.set(true, forKey: Self.hasSavedKeypadSnapshotDefaultsKey)
        }
    }

    func skinPackage(for reference: ThumbleSkinReference?) -> ThumbleSkinPackage? {
        guard let reference else { return nil }
        return skinPackagesByReference[reference]
    }

    @discardableResult
    func installSkinPackage(
        data: Data,
        policy: ThumbleSkinInstallPolicy = .newerOnly
    ) throws -> ThumbleSkinInstallResult {
        guard !isBuilderArtifactPracticePreviewActive else {
            throw NSError(domain: "ThumbleBuilderPreview", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Close the shared preview before changing skins."
            ])
        }
        let result = try skinStore.install(data: data, policy: policy)
        reloadInstalledSkins()
        if isConnected, serverCapabilities.contains(.skinPackages) {
            send(.init(type: .skinPackages, skinPackages: [data]))
        }
        return result
    }

    func skinPackageData(for reference: ThumbleSkinReference) throws -> Data {
        try skinStore.packageData(for: reference)
    }

    func applySkinToSelectedProfile(
        _ reference: ThumbleSkinReference,
        colorScheme: ThumbleSkinColorScheme
    ) throws {
        guard !isBuilderArtifactPracticePreviewActive else {
            throw NSError(domain: "ThumbleBuilderPreview", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Close the shared preview before changing skins."
            ])
        }
        guard let index = gamepadProfiles.firstIndex(where: { $0.id == selectedGamepadProfileID }),
              let package = skinPackage(for: reference)
        else { throw ThumbleSkinStoreError.skinNotInstalled(reference) }

        gamepadProfiles[index].applySkin(package, colorScheme: colorScheme)
        commitLocalSkinProfileChange(at: index)
        submitSkinSelectionMutation(
            profileID: gamepadProfiles[index].id,
            reference: reference,
            packageData: try? skinStore.packageData(for: reference)
        )
    }

    /// Forks the current visual result into the profile, then removes its package dependency.
    func detachSkinFromSelectedProfile(colorScheme: ThumbleSkinColorScheme) {
        guard !isBuilderArtifactPracticePreviewActive else { return }
        guard let index = gamepadProfiles.firstIndex(where: { $0.id == selectedGamepadProfileID }),
              let reference = gamepadProfiles[index].skinReference
        else { return }
        let package = skinPackage(for: reference)
        var profile = gamepadProfiles[index]
        if let package {
            profile.detachSkin(resolving: package, colorScheme: colorScheme)
        } else {
            profile.detachSkin()
        }
        gamepadProfiles[index] = profile.normalized
        commitLocalSkinProfileChange(at: index)
        submitSkinSelectionMutation(profileID: profile.id, reference: nil, packageData: nil)
    }

    func removeSkin(_ reference: ThumbleSkinReference) throws {
        guard !isBuilderArtifactPracticePreviewActive else {
            throw NSError(domain: "ThumbleBuilderPreview", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Close the shared preview before changing skins."
            ])
        }
        if let profile = gamepadProfiles.first(where: { $0.skinReference == reference }) {
            throw NSError(
                domain: "ThumbleSkinStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "This skin is still used by \(profile.name)."]
            )
        }
        try skinStore.remove(reference)
        reloadInstalledSkins()
        if !pendingSkinRemovals.contains(reference) {
            pendingSkinRemovals.append(reference)
            persistPendingSkinRemovals()
        }
        flushPendingSkinRemovals()
    }

    private func commitLocalSkinProfileChange(at index: Int) {
        let orientation = gamepadCustomization.deviceCanvas.editorDeviceFrame.orientation
        if gamepadProfiles[index].id == selectedGamepadProfileID {
            gamepadCustomization = gamepadProfiles[index].customization(for: orientation)
            GamepadCustomizationPersistence.save(gamepadCustomization)
        }
        persistGamepadProfiles()
        markSavedKeypadSnapshotAvailable()
    }

    private func submitSkinSelectionMutation(
        profileID: UUID,
        reference: ThumbleSkinReference?,
        packageData: Data?
    ) {
        let mutation = PendingSkinSelectionMutation(
            profileID: profileID,
            skinReference: reference,
            updatedAt: Date.currentMilliseconds
        )
        if let index = pendingSkinSelectionMutations.firstIndex(where: { $0.profileID == profileID }) {
            pendingSkinSelectionMutations[index] = mutation
        } else {
            pendingSkinSelectionMutations.append(mutation)
        }
        persistPendingSkinSelectionMutations()

        guard isConnected, serverCapabilities.contains(.gamepadProfileSkinSelection) else { return }
        if let packageData, serverCapabilities.contains(.skinPackages) {
            send(.init(type: .skinPackages, skinPackages: [packageData]))
        }
        send(.init(
            type: .gamepadProfileSkinSelection,
            skinReference: reference,
            gamepadProfileID: profileID
        ))
    }

    private func flushPendingSkinRemovals() {
        guard isConnected, serverCapabilities.contains(.skinPackages), !pendingSkinRemovals.isEmpty else { return }
        let removals = pendingSkinRemovals
        pendingSkinRemovals.removeAll()
        persistPendingSkinRemovals()
        for reference in removals {
            send(.init(type: .skinPackageRemoval, skinReference: reference))
            try? skinStore.remove(reference)
        }
        reloadInstalledSkins()
    }

    private func flushPendingSkinSelectionMutations() {
        guard isConnected, serverCapabilities.contains(.gamepadProfileSkinSelection) else { return }
        for mutation in pendingSkinSelectionMutations.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            let packageData = mutation.skinReference.flatMap { try? skinStore.packageData(for: $0) }
            if let packageData, serverCapabilities.contains(.skinPackages) {
                send(.init(type: .skinPackages, skinPackages: [packageData]))
            }
            send(.init(
                type: .gamepadProfileSkinSelection,
                skinReference: mutation.skinReference,
                gamepadProfileID: mutation.profileID
            ))
        }
    }

    private func reloadInstalledSkins() {
        let skins = (try? skinStore.installedSkins()) ?? []
        installedSkins = skins
        skinPackagesByReference = Dictionary(uniqueKeysWithValues: skins.compactMap { installed in
            (try? skinStore.package(for: installed.reference)).map { (installed.reference, $0) }
        })
    }

    func startSmartConnect() {
        guard state != .connected, state != .connecting, state != .pairingCodeRequired else { return }
        guard let credential = trustedMacCredential ?? Self.loadTrustedMacCredential() else {
            smartConnectStatus = "Pair once with the Mac QR code to enable Smart Connect."
            return
        }

        trustedMacCredential = credential
        autoReconnectEnabled = true
        lastError = nil
        smartConnectStatus = "Smart Connect: looking for your Mac…"

        if let url = credential.lastURL {
            connectTrusted(to: url, credential: credential)
        }
        startSmartDiscovery(for: credential)
    }

    func appDidBecomeActive() {
        startSmartConnect()
    }

    func connect(hostField: String, port: String, pairingCode: String) {
        stopSmartDiscovery()
        stopPairingDiscovery()
        reconnectTask?.cancel()
        reconnectTask = nil
        autoReconnectEnabled = false
        smartConnectStatus = nil
        openConnection(hostField: hostField, port: port, pairingCode: pairingCode)
    }

    func connect(pairingPayload payload: PairingPayload) {
        stopSmartDiscovery()
        stopPairingDiscovery()
        reconnectTask?.cancel()
        reconnectTask = nil
        autoReconnectEnabled = false
        lastError = nil
        smartConnectStatus = nil

        let pairingCode = payload.pairingCode?.nilIfBlank ?? ""
        let hasNearbyFallback = payload.hasServiceDiscoveryInfo
        if hasNearbyFallback {
            startPairingDiscovery(for: payload, pairingCode: pairingCode)
        }

        if let url = payload.urls.compactMap(URL.init(string:)).first(where: Self.isUsableRemoteURL) {
            openConnection(target: .url(url), pairingCode: pairingCode)
            return
        }

        if hasNearbyFallback {
            closeConnection(sendReleaseAll: false)
            state = .connecting
            smartConnectStatus = "Nearby Pairing: looking for this Mac…"
            return
        }

        state = .failed("Pairing code did not include a reachable Mac address")
    }

    func disconnect(sendReleaseAll: Bool = true) {
        autoReconnectEnabled = false
        stopSmartDiscovery()
        stopPairingDiscovery()
        reconnectTask?.cancel()
        reconnectTask = nil
        closeConnection(sendReleaseAll: sendReleaseAll)
        if case .failed = state {
            return
        }
        state = .disconnected
    }

    private func connectTrusted(to url: URL, credential: TrustedMacCredential) {
        openConnection(
            hostField: url.absoluteString,
            port: "",
            pairingCode: "",
            authToken: credential.authToken,
            expectedServerID: credential.serverID
        )
    }

    private func connectTrusted(to resolution: MacServiceResolution, credential: TrustedMacCredential) {
        openConnection(
            target: .service(resolution),
            pairingCode: "",
            authToken: credential.authToken,
            expectedServerID: credential.serverID
        )
    }

    private func openConnection(
        hostField: String,
        port: String,
        pairingCode: String,
        authToken: String? = nil,
        expectedServerID: String? = nil
    ) {
        guard let url = makeURL(hostField: hostField, port: port),
              url.host?.isEmpty == false
        else {
            state = .failed("Enter a valid ws:// host and port")
            return
        }

        openConnection(
            target: .url(url),
            pairingCode: pairingCode,
            authToken: authToken,
            expectedServerID: expectedServerID
        )
    }

    private func openConnection(
        target: ControllerConnectionTarget,
        pairingCode: String,
        authToken: String? = nil,
        expectedServerID: String? = nil
    ) {
        closeConnection(sendReleaseAll: false)

        state = .connecting
        lastError = nil

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true

        let scheme = target.displayURL?.scheme?.lowercased()
        let tlsOptions = scheme == "wss" ? NWProtocolTLS.Options() : nil
        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        parameters.includePeerToPeer = true
        let websocketOptions = NWProtocolWebSocket.Options()
        websocketOptions.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocketOptions, at: 0)

        let connection = NWConnection(to: target.endpoint, using: parameters)
        self.connection = connection
        controlURL = target.displayURL
        currentServiceResolution = target.serviceResolution
        currentAuthToken = authToken?.nilIfBlank
        currentExpectedServerID = expectedServerID?.nilIfBlank
        inputTransport.setReliableConnection(nil, resetSequence: true, inputProtocolVersion: 1)

        let deviceName = UIDevice.current.name
        let pairingCode = pairingCode.nilIfBlank
        let connectionAuthToken = currentAuthToken
        let connectionExpectedServerID = currentExpectedServerID

        connection.stateUpdateHandler = { [weak self, weak connection] connectionState in
            guard let connection else { return }
            Task { @MainActor in
                self?.handleConnectionState(
                    connectionState,
                    connection: connection,
                    pairingCode: pairingCode,
                    authToken: connectionAuthToken,
                    expectedServerID: connectionExpectedServerID,
                    clientName: deviceName
                )
            }
        }

        connection.start(queue: networkQueue)
    }

    private func closeConnection(sendReleaseAll: Bool) {
        if sendReleaseAll {
            releaseAll()
        }
        inputTransport.disconnect()
        stopRealtimeDatagram()
        lastSentEventUpdateTask?.cancel()
        lastSentEventUpdateTask = nil
        connection?.cancel()
        connection = nil
        controlURL = nil
        currentServiceResolution = nil
        currentAuthToken = nil
        currentExpectedServerID = nil
        serverCapabilities = []
        if let phase = builderArtifactAdoptionState?.phase {
            switch phase {
            case .uploading, .awaitingAuthoritativeSnapshot:
                builderArtifactAdoptionState?.phase = .failed(.disconnected)
            case .succeeded, .failed:
                break
            }
        }
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func submitPairingCode(_ code: String) {
        let normalizedCode = String(code.filter(\.isNumber).prefix(6))
        guard !normalizedCode.isEmpty, connection != nil else { return }

        lastError = nil
        updateLastSentEvent("pairing code sent", immediately: true)
        send(.init(type: .hello, timestamp: 0, pairingCode: normalizedCode, clientName: UIDevice.current.name, clientDeviceInfo: Self.currentDeviceInfo()))
    }

    func setButton(_ button: GameButton, pressed: Bool, pressIdentifier: UInt64? = nil) {
        // Send raw per-touch edges immediately. The Mac helper keeps physical
        // touch identity so the injected key state can change without timer delays.
        let state: ButtonPressState = pressed ? .down : .up
        guard permitsOutgoingInput(.builtInButton),
              inputTransport.sendButton(button, state: state, pressIdentifier: pressIdentifier)
        else { return }
        if Self.liveInputStatusUpdatesEnabled {
            updateLastSentEvent("\(button.rawValue) \(state.rawValue)")
        }
    }

    func setElementInput(_ input: KeypadElementInputID, pressed: Bool, pressIdentifier: UInt64? = nil) {
        let state: ButtonPressState = pressed ? .down : .up
        guard permitsOutgoingInput(.elementButton),
              inputTransport.sendElementInput(input, state: state, pressIdentifier: pressIdentifier)
        else { return }
        if Self.liveInputStatusUpdatesEnabled {
            updateLastSentEvent("\(input.storageKey) \(state.rawValue)")
        }
    }

    func setGamepadStick(_ stick: VirtualGamepadStick, x: Double, y: Double, isFinal: Bool = false) {
        guard permitsOutgoingInput(.analogStick) else { return }
        let clampedX = Self.clamp(x, lower: -1, upper: 1)
        let clampedY = Self.clamp(y, lower: -1, upper: 1)
        let isNeutral = abs(clampedX) < 0.001 && abs(clampedY) < 0.001
        _ = inputTransport.sendGamepadStick(
            stick,
            x: clampedX,
            y: clampedY,
            isFinal: isFinal || isNeutral
        )
    }

    func setGamepadTrigger(_ trigger: VirtualGamepadTrigger, value: Double, isFinal: Bool = false) {
        guard permitsOutgoingInput(.analogTrigger) else { return }
        let clampedValue = Self.clamp(value, lower: 0, upper: 1)
        _ = inputTransport.sendGamepadTrigger(
            trigger,
            value: clampedValue,
            isFinal: isFinal || clampedValue < 0.001
        )
    }

    func sendPointerMove(deltaX: Double, deltaY: Double) {
        guard permitsOutgoingInput(.pointerMove),
              abs(deltaX) >= 0.01 || abs(deltaY) >= 0.01
        else { return }
        sendPointer(kind: .move, deltaX: deltaX, deltaY: deltaY, mirrorsReliably: false)
    }

    func sendPointerScroll(deltaX: Double, deltaY: Double) {
        guard permitsOutgoingInput(.pointerScroll),
              abs(deltaX) >= 0.01 || abs(deltaY) >= 0.01
        else { return }
        sendPointer(kind: .scroll, deltaX: deltaX, deltaY: deltaY, mirrorsReliably: false)
    }

    func sendPointerClick(_ button: ControllerPointerButton) {
        setPointerButton(button, pressed: true)
        setPointerButton(button, pressed: false)
    }

    func setPointerButton(_ button: ControllerPointerButton, pressed: Bool) {
        guard permitsOutgoingInput(.pointerButton) else { return }
        let state: ButtonPressState = pressed ? .down : .up
        sendPointer(kind: .button, pointerButton: button, state: state, mirrorsReliably: true)
    }

    private func sendPointer(
        kind: ControllerPointerEventKind,
        pointerButton: ControllerPointerButton? = nil,
        state: ButtonPressState? = nil,
        deltaX: Double? = nil,
        deltaY: Double? = nil,
        mirrorsReliably: Bool
    ) {
        let inputPath: ControllerInputPath = switch kind {
        case .move: .pointerMove
        case .scroll: .pointerScroll
        case .button: .pointerButton
        }
        guard permitsOutgoingInput(inputPath) else { return }
        send(
            inputTransport.decoratingRealtimeMessage(
                .init(
                    type: .pointer,
                    state: state,
                    timestamp: 0,
                    pointerEvent: kind,
                    pointerButton: pointerButton,
                    deltaX: deltaX,
                    deltaY: deltaY
                )
            ),
            prefersRealtimeDatagram: true,
            mirrorsReliably: mirrorsReliably
        )
    }

    func releaseAll() {
        guard inputTransport.releaseAll() else { return }
        updateLastSentEvent("release_all", immediately: true)
    }

    @discardableResult
    func beginProfileArtifactAdoption(
        record: IOSPendingBuilderArtifactRecord,
        artifact: PortableProfileArtifact,
        operationID: UUID
    ) -> Bool {
        guard supportsProfileArtifactAdoptionV1,
              let serverID = currentKeypadSyncServerID,
              artifact.rawData.count == record.bytes,
              artifact.contentHash.value == record.contentHash
        else { return false }
        let rawHash = ProfileArtifactAdoptionMetadata.sha256(artifact.rawData)
        guard rawHash == record.rawSHA256 else { return false }
        if let current = builderArtifactAdoptionState {
            switch current.phase {
            case .uploading, .awaitingAuthoritativeSnapshot:
                return false
            case .succeeded, .failed:
                break
            }
        }
        let metadata = ProfileArtifactAdoptionMetadata(
            operationID: operationID,
            recordID: record.id,
            intendedServerID: serverID,
            contentHash: artifact.contentHash.value,
            rawSHA256: rawHash,
            byteCount: artifact.rawData.count,
            chunkCount: ProfileArtifactAdoptionMetadata.chunkCount(forByteCount: artifact.rawData.count)
        )
        guard metadata.validate(expectedServerID: serverID) == nil else { return false }
        builderArtifactAdoptionState = IOSBuilderArtifactAdoptionState(
            metadata: metadata,
            phase: .uploading(sentChunks: 0, totalChunks: metadata.chunkCount)
        )
        send(.init(
            type: .profileArtifactAdoptionBegin,
            profileArtifactAdoptionMetadata: metadata
        ))
        for index in 0..<metadata.chunkCount {
            guard let expected = metadata.expectedChunkBytes(at: index) else { return false }
            let lower = index * ProfileArtifactAdoptionConstants.chunkBytes
            let chunk = artifact.rawData.subdata(in: lower..<(lower + expected))
            send(.init(
                type: .profileArtifactAdoptionChunk,
                profileArtifactAdoptionOperationID: operationID,
                profileArtifactAdoptionChunkIndex: index,
                profileArtifactAdoptionChunkData: chunk
            ))
            builderArtifactAdoptionState?.phase = .uploading(
                sentChunks: index + 1,
                totalChunks: metadata.chunkCount
            )
        }
        send(.init(
            type: .profileArtifactAdoptionCommit,
            profileArtifactAdoptionOperationID: operationID
        ))
        return true
    }

    func cancelProfileArtifactAdoption() {
        guard let state = builderArtifactAdoptionState else { return }
        if isConnected {
            send(.init(
                type: .profileArtifactAdoptionCancel,
                profileArtifactAdoptionOperationID: state.metadata.operationID
            ))
        }
        builderArtifactAdoptionState?.phase = .failed(.disconnected)
    }

    func clearTerminalProfileArtifactAdoption(recordID: UUID? = nil) {
        guard let state = builderArtifactAdoptionState else { return }
        if let recordID, state.metadata.recordID != recordID { return }
        switch state.phase {
        case .succeeded, .failed:
            builderArtifactAdoptionState = nil
        case .uploading, .awaitingAuthoritativeSnapshot:
            break
        }
    }

    func beginBuilderArtifactPracticePreview(
        recordID: UUID,
        artifact: PortableProfileArtifact
    ) {
        guard let nextPreview = IOSBuilderArtifactPracticeTransition.begin(
            recordID: recordID,
            artifact: artifact,
            currentPreview: builderArtifactPracticePreview,
            currentPracticeModeValue: isPracticeModeEnabled
        ) else { return }
        TouchCaptureUIView.deactivateAllRegisteredTouches()
        releaseAll()
        if builderArtifactPracticePreview == nil {
            IOSBuilderArtifactPracticePersistence.markForced(priorValue: isPracticeModeEnabled)
        }
        if !isPracticeModeEnabled { setPracticeModeEnabled(true) }
        builderArtifactPracticePreview = nextPreview
        updateLastSentEvent("shared preview; input off", immediately: true)
    }

    func selectBuilderArtifactPracticeProfile(_ profileID: UUID) {
        guard let preview = builderArtifactPracticePreview,
              let selected = preview.selecting(profileID)
        else { return }
        TouchCaptureUIView.deactivateAllRegisteredTouches()
        releaseAll()
        builderArtifactPracticePreview = selected
        updateLastSentEvent("shared preview: \(selected.selectedProfile?.name ?? "profile")", immediately: true)
    }

    func endBuilderArtifactPracticePreview() {
        guard let preview = builderArtifactPracticePreview else { return }
        TouchCaptureUIView.deactivateAllRegisteredTouches()
        releaseAll()
        builderArtifactPracticePreview = nil
        let restoredPracticeMode = IOSBuilderArtifactPracticeTransition.restoredPracticeModeValue(after: preview)
        if isPracticeModeEnabled != restoredPracticeMode {
            setPracticeModeEnabled(restoredPracticeMode)
        }
        IOSBuilderArtifactPracticePersistence.clear()
        updateLastSentEvent("shared preview closed", immediately: true)
    }

    /// Practice Mode is local-only. Active touches and remote state are cleared
    /// before suppression becomes active so no held input can leak through.
    func setPracticeModeEnabled(_ isEnabled: Bool) {
        guard !(isBuilderArtifactPracticePreviewActive && !isEnabled) else { return }
        guard isEnabled != isPracticeModeEnabled else { return }
        TouchCaptureUIView.deactivateAllRegisteredTouches()
        releaseAll()
        isPracticeModeEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: IOSKeypadPreferenceKeys.practiceMode)
        updateLastSentEvent(isEnabled ? "practice mode enabled" : "practice mode disabled", immediately: true)
    }

    private func permitsOutgoingInput(_ path: ControllerInputPath) -> Bool {
        ControllerInputSuppressionPolicy.permitsOutgoingInput(
            path,
            isConnected: isConnected,
            isPracticeModeEnabled: isPracticeModeEnabled
        )
    }

    func selectGamepadProfile(_ profileID: UUID) {
        guard !isBuilderArtifactPracticePreviewActive else { return }
        guard let profile = gamepadProfiles.first(where: { $0.id == profileID }) else { return }
        releaseAll()
        selectedGamepadProfileID = profile.id
        applyLocalGamepadCustomization(profile.customization.stampedForLocalUpdate)
        persistGamepadProfiles()
        send(.init(type: .gamepadProfileSelection, timestamp: 0, gamepadProfileID: profile.id))
        updateLastSentEvent("keypad setup: \(profile.name)", immediately: true)
    }

    func setDefaultGamepadProfile(_ profileID: UUID) {
        guard !isBuilderArtifactPracticePreviewActive else { return }
        guard gamepadProfiles.contains(where: { $0.id == profileID }) else { return }
        defaultGamepadProfileID = profileID
        persistGamepadProfiles()
        send(
            .init(
                type: .gamepadDefaultProfile,
                timestamp: 0,
                gamepadProfileID: profileID,
                defaultGamepadProfileID: profileID
            )
        )
        updateLastSentEvent("default keypad saved", immediately: true)
    }

    @discardableResult
    func setSelectedGamepadProfileOrientationPreference(
        _ preference: GamepadProfileOrientationPreference
    ) -> Bool {
        guard !isBuilderArtifactPracticePreviewActive,
              supportsGamepadProfileOrientationPreferenceMutation,
              let index = gamepadProfiles.firstIndex(where: { $0.id == selectedGamepadProfileID })
        else { return false }
        guard gamepadProfiles[index].orientationPreference != preference else { return true }

        // Optimism is intentionally capability-gated. Old Macs never advertise the
        // mutation capability, so their saved profile remains authoritative and unchanged.
        gamepadProfiles[index].orientationPreference = preference
        gamepadProfiles[index].updatedAt = Date.currentMilliseconds
        persistGamepadProfiles()
        send(
            .init(
                type: .gamepadProfileOrientationPreferenceMutation,
                timestamp: 0,
                gamepadProfileID: selectedGamepadProfileID,
                gamepadProfileOrientationPreferenceMutation: preference
            )
        )
        updateLastSentEvent("iPhone rotation: \(preference.displayName)", immediately: true)
        return true
    }

    func launchSelectedProfileTarget() {
        guard !isBuilderArtifactPracticePreviewActive,
              isConnected,
              let profile = selectedGamepadProfile,
              let launchTarget = profile.launchTarget
        else { return }
        send(
            .init(
                type: .launchProfileTarget,
                timestamp: 0,
                gamepadProfileID: profile.id
            )
        )
        updateLastSentEvent("launch: \(launchTarget.displayName)", immediately: true)
    }

    func updateSelectedKeypadLayout(
        _ customization: GamepadCustomization,
        orientation: GamepadEditorDeviceOrientation,
        sendsToMac: Bool
    ) {
        guard !isBuilderArtifactPracticePreviewActive else { return }
        var stampedCustomization = Self.customization(customization, matching: orientation).stampedForLocalUpdate
        if let profile = selectedGamepadProfile,
           let package = skinPackage(for: profile.skinReference) {
            stampedCustomization = stampedCustomization.dehydratingAssets(from: package)
        }
        var updatedProfiles = gamepadProfiles
        if let index = updatedProfiles.firstIndex(where: { $0.id == selectedGamepadProfileID }) {
            updatedProfiles[index].setCustomization(stampedCustomization, for: orientation)
            updatedProfiles[index].updatedAt = Date.currentMilliseconds
            gamepadProfiles = updatedProfiles
        }

        applyLocalGamepadCustomization(stampedCustomization)
        persistGamepadProfiles()
        markSavedKeypadSnapshotAvailable()

        guard sendsToMac else { return }
        recordPendingKeypadLayoutEdit(
            profileID: selectedGamepadProfileID,
            orientation: orientation,
            customization: stampedCustomization
        )
        if isConnected {
            sendPendingKeypadLayoutEdit(
                PendingKeypadLayoutEdit(
                    profileID: selectedGamepadProfileID,
                    orientation: orientation,
                    customization: stampedCustomization,
                    serverID: currentKeypadSyncServerID
                )
            )
        }
        updateLastSentEvent(
            isConnected ? "keypad layout saved; awaiting Mac confirmation" : "keypad layout saved locally; sync pending",
            immediately: true
        )
    }

    private var currentKeypadSyncServerID: String? {
        trustedMacCredential?.serverID.nilIfBlank ?? currentExpectedServerID?.nilIfBlank
    }

    private func recordPendingKeypadLayoutEdit(
        profileID: UUID,
        orientation: GamepadEditorDeviceOrientation,
        customization: GamepadCustomization
    ) {
        let edit = PendingKeypadLayoutEdit(
            profileID: profileID,
            orientation: orientation,
            customization: customization,
            serverID: currentKeypadSyncServerID
        )
        pendingKeypadLayoutEdits = PendingKeypadLayoutReconciler.recording(
            edit,
            in: pendingKeypadLayoutEdits
        )
        PendingKeypadLayoutPersistence.save(pendingKeypadLayoutEdits)
    }

    private func sendPendingKeypadLayoutEdit(_ edit: PendingKeypadLayoutEdit) {
        // Offline layout sync and orientation mutation shipped in the same
        // protocol revision, so this capability also gates safe inactive-profile updates.
        guard isConnected,
              serverCapabilities.contains(.gamepadProfileOrientationPreferenceMutation),
              let serverID = currentKeypadSyncServerID,
              edit.serverID == serverID,
              gamepadProfiles.contains(where: { $0.id == edit.profileID })
        else { return }
        send(
            .init(
                type: .gamepadCustomization,
                timestamp: 0,
                gamepadCustomization: edit.customization,
                gamepadProfileID: edit.profileID
            )
        )
    }

    private func flushPendingKeypadLayoutEdits() {
        guard isConnected else { return }
        guard serverCapabilities.contains(.gamepadProfileOrientationPreferenceMutation) else {
            if !pendingKeypadLayoutEdits.isEmpty {
                updateLastSentEvent("Update the Mac app to sync saved iPhone layout edits", immediately: true)
            }
            return
        }
        for edit in pendingKeypadLayoutEdits {
            sendPendingKeypadLayoutEdit(edit)
        }
        if !pendingKeypadLayoutEdits.isEmpty {
            updateLastSentEvent("syncing saved iPhone layout edits", immediately: true)
        }
    }

    func setKeypadColorSchemePreference(_ preference: GamepadColorSchemePreference) {
        guard !isBuilderArtifactPracticePreviewActive else { return }
        var nextCustomization = gamepadCustomization
        guard nextCustomization.colorSchemePreference != preference else { return }
        nextCustomization.colorSchemePreference = preference
        let stampedCustomization = nextCustomization.stampedForLocalUpdate

        if let index = gamepadProfiles.firstIndex(where: { $0.id == selectedGamepadProfileID }) {
            gamepadProfiles[index].customization = stampedCustomization
            gamepadProfiles[index].updatedAt = Date.currentMilliseconds
        }

        applyLocalGamepadCustomization(stampedCustomization)
        persistGamepadProfiles()
        let orientation = stampedCustomization.deviceCanvas.editorDeviceFrame.orientation
        recordPendingKeypadLayoutEdit(
            profileID: selectedGamepadProfileID,
            orientation: orientation,
            customization: stampedCustomization
        )
        if let edit = pendingKeypadLayoutEdits.last(where: {
            $0.profileID == selectedGamepadProfileID && $0.orientation == orientation
        }) {
            sendPendingKeypadLayoutEdit(edit)
        }
        updateLastSentEvent(
            isConnected
                ? "keypad appearance: \(preference.displayName); awaiting Mac confirmation"
                : "keypad appearance saved locally; sync pending",
            immediately: true
        )
    }

    private static func customization(_ customization: GamepadCustomization, matching orientation: GamepadEditorDeviceOrientation) -> GamepadCustomization {
        var nextCustomization = customization.normalized
        let frame = nextCustomization.deviceCanvas.editorDeviceFrame
        if frame.orientation != orientation {
            nextCustomization.deviceCanvas = GamepadDeviceCanvas(
                frameID: GamepadEditorDeviceFrame(spec: frame.spec, orientation: orientation).id
            )
        }
        return nextCustomization.normalized
    }

    private func applyLocalGamepadCustomization(_ customization: GamepadCustomization) {
        let normalizedCustomization = customization.normalized
        guard normalizedCustomization != gamepadCustomization else { return }
        gamepadCustomization = normalizedCustomization
        GamepadCustomizationPersistence.save(normalizedCustomization)
    }

    private func applyGamepadCustomizationFromMac(_ customization: GamepadCustomization) {
        applyLocalGamepadCustomization(customization)
    }

    private func applyGamepadProfileStateFromMac(_ message: ControllerMessage) {
        installSyncedSkinPackages(message.skinPackages)
        applyServerProfileMetadata(message)

        let workspace = IncomingProfileReconciliationWorkspace(
            message: message,
            currentCustomization: gamepadCustomization,
            pendingEdits: pendingKeypadLayoutEdits,
            currentServerID: currentKeypadSyncServerID
        )
        guard workspace.hasProfiles else {
            if let customization = workspace.incomingCustomization {
                applyGamepadCustomizationFromMac(customization)
            }
            return
        }
        workspace.reconcile()
        commitIncomingProfileState(workspace)
    }

    private func installSyncedSkinPackages(_ packageData: [Data]?) {
        guard let packageData else { return }
        var installFailure: Error?
        for data in packageData {
            do { _ = try skinStore.install(data: data, policy: .allowDowngrade) }
            catch { installFailure = error }
        }
        reloadInstalledSkins()
        if let installFailure {
            lastError = "A synced skin could not be installed: \(installFailure.localizedDescription)"
        }
    }

    private func applyServerProfileMetadata(_ message: ControllerMessage) {
        if let capabilities = message.capabilities {
            serverCapabilities = Set(capabilities)
        }
        if let incomingPresentations = message.bindingPresentations {
            // A sync payload is authoritative, including an explicitly empty list.
            bindingPresentations = incomingPresentations
            KeypadBindingPresentationPersistence.save(incomingPresentations)
        }
    }

    private final class IncomingProfileReconciliationWorkspace {
        private let incomingProfiles: [GamepadConfigurationProfile]
        private let activeProfileID: UUID?
        private let defaultProfileID: UUID?
        private let fallbackCustomization: GamepadCustomization
        private let pendingEdits: [PendingKeypadLayoutEdit]
        private let authoritativeServerID: String?
        let incomingCustomization: GamepadCustomization?
        private(set) var normalizedState: GamepadConfigurationProfilePersistence.LoadedState?
        private(set) var reconciliation: PendingKeypadLayoutReconciliation?
        private(set) var reconciledState: GamepadConfigurationProfilePersistence.LoadedState?

        var hasProfiles: Bool { !incomingProfiles.isEmpty }

        init(
            message: ControllerMessage,
            currentCustomization: GamepadCustomization,
            pendingEdits: [PendingKeypadLayoutEdit],
            currentServerID: String?
        ) {
            incomingProfiles = message.gamepadProfiles ?? []
            activeProfileID = message.gamepadProfileID
            defaultProfileID = message.defaultGamepadProfileID
            incomingCustomization = message.gamepadCustomization
            fallbackCustomization = message.gamepadCustomization ?? currentCustomization
            self.pendingEdits = pendingEdits
            authoritativeServerID = message.serverID?.nilIfBlank ?? currentServerID
        }

        func reconcile() {
            normalizeIncomingProfiles()
            reconcilePendingEdits()
            normalizeReconciledProfiles()
        }

        private func normalizeIncomingProfiles() {
            normalizedState = GamepadConfigurationProfilePersistence.normalizedState(
                profiles: incomingProfiles,
                activeProfileID: activeProfileID,
                defaultProfileID: defaultProfileID,
                fallbackCustomization: fallbackCustomization
            )
        }

        private func reconcilePendingEdits() {
            guard let normalizedState else { return }
            reconciliation = PendingKeypadLayoutReconciler.reconcile(
                incomingProfiles: normalizedState.profiles,
                pendingEdits: pendingEdits,
                authoritativeServerID: authoritativeServerID
            )
        }

        private func normalizeReconciledProfiles() {
            guard let normalizedState, let reconciliation else { return }
            reconciledState = GamepadConfigurationProfilePersistence.normalizedState(
                profiles: reconciliation.profiles,
                activeProfileID: normalizedState.activeProfileID,
                defaultProfileID: normalizedState.defaultProfileID,
                fallbackCustomization: fallbackCustomization
            )
        }
    }

    private func commitIncomingProfileState(
        _ workspace: IncomingProfileReconciliationWorkspace
    ) {
        guard let reconciliation = workspace.reconciliation,
              let reconciledState = workspace.reconciledState
        else { return }
        commitPendingKeypadEdits(reconciliation)
        gamepadProfiles = reconciledState.profiles
        acknowledgeSyncedSkinSelections(in: reconciledState.profiles)
        selectedGamepadProfileID = reconciledState.activeProfileID
        defaultGamepadProfileID = reconciledState.defaultProfileID
        markSavedKeypadSnapshotAvailable()
        applyActiveCustomization(from: reconciledState, fallback: workspace.incomingCustomization)
        persistGamepadProfiles()
        observeProfileArtifactAdoptionSnapshot()
        if isConnected, !reconciliation.editsToUpload.isEmpty {
            flushPendingKeypadLayoutEdits()
        }
    }

    private func commitPendingKeypadEdits(_ reconciliation: PendingKeypadLayoutReconciliation) {
        pendingKeypadLayoutEdits = reconciliation.remainingEdits
        PendingKeypadLayoutPersistence.save(pendingKeypadLayoutEdits)
    }

    private func acknowledgeSyncedSkinSelections(in profiles: [GamepadConfigurationProfile]) {
        pendingSkinSelectionMutations.removeAll { mutation in
            guard let profile = profiles.first(where: { $0.id == mutation.profileID }) else { return false }
            return profile.skinReference == mutation.skinReference
        }
        persistPendingSkinSelectionMutations()
    }

    private func applyActiveCustomization(
        from state: GamepadConfigurationProfilePersistence.LoadedState,
        fallback: GamepadCustomization?
    ) {
        if let activeProfile = state.activeProfile {
            applyGamepadCustomizationFromMac(activeProfile.customization)
        } else if let fallback {
            applyGamepadCustomizationFromMac(fallback)
        }
    }

    private func persistGamepadProfiles() {
        GamepadConfigurationProfilePersistence.save(
            gamepadProfiles,
            activeProfileID: selectedGamepadProfileID,
            defaultProfileID: defaultGamepadProfileID
        )
    }

    func appWillBecomeInactive() {
        // Losing focus briefly (Control Center, alerts, app switcher, etc.) should not
        // tear down the keypad socket. Release held buttons for safety, then keep
        // heartbeats running so the Mac helper can recover when the app is active again.
        releaseAll()
    }

    func appDidEnterBackground() {
        releaseAll()
        disconnect(sendReleaseAll: false)
    }

    private func handleConnectionState(
        _ connectionState: NWConnection.State,
        connection stateConnection: NWConnection,
        pairingCode: String?,
        authToken: String?,
        expectedServerID: String?,
        clientName: String
    ) {
        guard connection === stateConnection else { return }

        switch connectionState {
        case .ready:
            guard state != .connected else { return }
            lastSentEvent = "Socket ready"
            receiveNext(on: stateConnection)

            if let authToken {
                send(.init(type: .hello, timestamp: 0, clientName: clientName, authToken: authToken, serverID: expectedServerID, clientDeviceInfo: Self.currentDeviceInfo()))
            } else if let pairingCode {
                send(.init(type: .hello, timestamp: 0, pairingCode: pairingCode, clientName: clientName, clientDeviceInfo: Self.currentDeviceInfo()))
            } else {
                send(.init(type: .pairingRequest, timestamp: 0, clientName: clientName, clientDeviceInfo: Self.currentDeviceInfo()))
            }

        case .waiting(let error):
            lastError = error.localizedDescription

        case .failed(let error):
            handleSocketError(error, for: stateConnection)

        case .cancelled:
            guard connection === stateConnection else { return }
            inputTransport.disconnect()
            stopRealtimeDatagram()
            lastSentEventUpdateTask?.cancel()
            lastSentEventUpdateTask = nil
            connection = nil
            controlURL = nil
            currentServiceResolution = nil
            currentAuthToken = nil
            currentExpectedServerID = nil
            serverCapabilities = []
            UIApplication.shared.isIdleTimerDisabled = false
            if case .failed = state {
                return
            }
            state = .disconnected
            scheduleSmartReconnectIfNeeded()

        default:
            break
        }
    }

    private func updateLastSentEvent(_ value: String, immediately: Bool = false) {
        pendingLastSentEvent = value

        if immediately {
            lastSentEventUpdateTask?.cancel()
            lastSentEventUpdateTask = nil
            lastSentEvent = value
            return
        }

        guard lastSentEventUpdateTask == nil else { return }
        lastSentEventUpdateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard let self, !Task.isCancelled else { return }
            self.lastSentEvent = self.pendingLastSentEvent
            self.lastSentEventUpdateTask = nil
        }
    }

    private static func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        guard value.isFinite else { return lower }
        return min(max(value, lower), upper)
    }

    private static func currentDeviceInfo() -> ControllerClientDeviceInfo {
        let screen = UIScreen.main
        let bounds = screen.bounds
        let nativeBounds = screen.nativeBounds
        let window = activeWindow
        let insets = window?.safeAreaInsets

        return ControllerClientDeviceInfo(
            deviceName: UIDevice.current.name,
            modelIdentifier: hardwareModelIdentifier(),
            systemName: UIDevice.current.systemName,
            systemVersion: UIDevice.current.systemVersion,
            screenBoundsWidth: Double(bounds.width),
            screenBoundsHeight: Double(bounds.height),
            nativeBoundsWidth: Double(nativeBounds.width),
            nativeBoundsHeight: Double(nativeBounds.height),
            scale: Double(screen.scale),
            nativeScale: Double(screen.nativeScale),
            safeAreaInsets: insets.map {
                ControllerClientDeviceInsets(
                    top: Double($0.top),
                    leading: Double($0.left),
                    bottom: Double($0.bottom),
                    trailing: Double($0.right)
                )
            },
            interfaceOrientation: window?.windowScene?.interfaceOrientation.deviceInfoName,
            interfaceStyle: window?.traitCollection.userInterfaceStyle.deviceInfoName
        )
    }

    private static var activeWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .sorted { lhs, rhs in
                if lhs.activationState == rhs.activationState { return false }
                return lhs.activationState == .foregroundActive
            }
            .compactMap { scene in scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first }
            .first
    }

    private static func hardwareModelIdentifier() -> String? {
        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else { return nil }
        let machineCapacity = MemoryLayout.size(ofValue: systemInfo.machine)
        return withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: machineCapacity) {
                String(cString: $0)
            }
        }
        .nilIfBlank
    }

    private func send(_ message: ControllerMessage, prefersRealtimeDatagram: Bool = false, mirrorsReliably: Bool = true) {
        do {
            let data = try ControllerWireCodec.encode(message, using: encoder)
            if prefersRealtimeDatagram {
                sendRealtimeData(data, mirrorsReliably: mirrorsReliably)
            } else {
                sendData(data)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func sendRealtimeData(_ data: Data, mirrorsReliably: Bool) {
        let sentDatagram = sendRealtimeDatagramData(data)
        if mirrorsReliably || !sentDatagram {
            sendData(data, reportsSendErrors: !sentDatagram)
        }
    }

    @discardableResult
    private func sendRealtimeDatagramData(_ data: Data) -> Bool {
        guard isRealtimeDatagramReady,
              let realtimeDatagramConnection
        else {
            return false
        }

        realtimeDatagramConnection.send(
            content: data,
            contentContext: .defaultMessage,
            isComplete: true,
            completion: .idempotent
        )
        return true
    }

    private func sendData(_ data: Data) {
        sendData(data, reportsSendErrors: true)
    }

    private func sendData(_ data: Data, reportsSendErrors: Bool) {
        guard let connection else { return }

        if reportsSendErrors {
            connection.send(content: data, contentContext: binaryMessageContext, isComplete: true, completion: .contentProcessed { [weak self, connection] error in
                guard let error else { return }
                Task { @MainActor in
                    self?.handleSocketError(error, for: connection)
                }
            })
        } else {
            connection.send(content: data, contentContext: binaryMessageContext, isComplete: true, completion: .idempotent)
        }
    }

    nonisolated private func receiveNext(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }

            if let error {
                Task { @MainActor in
                    self.handleSocketError(error, for: connection)
                }
                return
            }

            if let data, !data.isEmpty {
                Task { @MainActor in
                    self.handleIncoming(data, from: connection)
                }
            }

            self.receiveNext(on: connection)
        }
    }

    private func handleIncoming(_ data: Data, from messageConnection: NWConnection) {
        guard connection === messageConnection else { return }
        guard let decoded = try? ControllerWireCodec.decode(data, using: decoder) else { return }
        if handlePairingMessage(decoded, from: messageConnection) { return }
        if handleProfileStateMessage(decoded) { return }
        _ = handleRuntimeMessage(decoded)
    }

    @discardableResult
    private func handlePairingMessage(
        _ message: ControllerMessage,
        from messageConnection: NWConnection
    ) -> Bool {
        switch message.type {
        case .pairingChallenge:
            lastError = nil
            state = .pairingCodeRequired
            updateLastSentEvent(message.message ?? "pairing request accepted", immediately: true)
        case .pairingAccepted, .hello:
            applyGamepadProfileStateFromMac(message)
            finishPairing(
                on: messageConnection,
                message: message.message,
                realtimeToken: message.realtimeToken,
                authToken: message.authToken,
                serverID: message.serverID,
                inputProtocolVersion: message.inputProtocolVersion ?? 1
            )
        case .error:
            lastError = message.message ?? "Mac helper returned an error"
            if message.message?.localizedCaseInsensitiveContains("Trusted pairing expired") == true {
                clearTrustedMacCredential()
            }
            state = .failed(lastError ?? "Unknown error")
            closeConnection(sendReleaseAll: false)
        default:
            return false
        }
        return true
    }

    @discardableResult
    private func handleProfileStateMessage(_ message: ControllerMessage) -> Bool {
        switch message.type {
        case .gamepadCustomization:
            applyGamepadProfileStateFromMac(message)
            if message.gamepadCustomization != nil {
                updateLastSentEvent("keypad customization updated", immediately: true)
            }
        case .gamepadProfiles:
            applyGamepadProfileStateFromMac(message)
            updateLastSentEvent("keypad setups updated", immediately: true)
        case .skinPackages:
            applyGamepadProfileStateFromMac(message)
        case .profileArtifactAdoptionResult:
            handleProfileArtifactAdoptionResult(message)
        case .skinPackageRemoval, .gamepadProfileSelection, .gamepadProfileSkinSelection,
             .gamepadDefaultProfile, .gamepadProfileOrientationPreferenceMutation:
            break
        default:
            return false
        }
        return true
    }

    private func handleProfileArtifactAdoptionResult(_ message: ControllerMessage) {
        guard ProfileArtifactAdoptionEnvelopeValidator.validate(message) == nil,
              let result = message.profileArtifactAdoptionResult,
              var adoption = builderArtifactAdoptionState,
              adoption.acceptResult(result)
        else { return }
        if case .awaitingAuthoritativeSnapshot = adoption.phase {
            _ = adoption.observeAuthoritativeProfiles(Set(gamepadProfiles.map(\.id)))
        }
        builderArtifactAdoptionState = adoption
    }

    private func observeProfileArtifactAdoptionSnapshot() {
        guard var adoption = builderArtifactAdoptionState else { return }
        guard adoption.observeAuthoritativeProfiles(Set(gamepadProfiles.map(\.id))) else { return }
        builderArtifactAdoptionState = adoption
    }

    @discardableResult
    private func handleRuntimeMessage(_ message: ControllerMessage) -> Bool {
        switch message.type {
        case .releaseAll:
            _ = inputTransport.releaseAll(adoptingGeneration: message.inputGeneration)
            updateLastSentEvent("release_all from Mac", immediately: true)
        case .ping:
            send(.init(type: .pong, timestamp: message.timestamp))
        case .pong:
            break
        default:
            return false
        }
        return true
    }

    private func finishPairing(
        on pairedConnection: NWConnection,
        message: String?,
        realtimeToken: String?,
        authToken: String?,
        serverID: String?,
        inputProtocolVersion: Int
    ) {
        guard connection === pairedConnection else { return }
        guard state != .connected else { return }

        rememberTrustedMacIfAvailable(authToken: authToken, serverID: serverID)
        stopSmartDiscovery()
        stopPairingDiscovery()
        reconnectTask?.cancel()
        reconnectTask = nil
        autoReconnectEnabled = trustedMacCredential != nil
        state = .connected
        flushPendingKeypadLayoutEdits()
        flushPendingSkinRemovals()
        flushPendingSkinSelectionMutations()
        lastError = nil
        smartConnectStatus = nil
        lastSentEvent = message ?? "Pairing complete"
        UIApplication.shared.isIdleTimerDisabled = true
        inputTransport.setReliableConnection(
            pairedConnection,
            resetSequence: true,
            inputProtocolVersion: inputProtocolVersion
        )
        startRealtimeDatagram(realtimeToken: realtimeToken)
    }

    private func rememberTrustedMacIfAvailable(authToken: String?, serverID: String?) {
        let tokenToStore = authToken?.nilIfBlank ?? currentAuthToken?.nilIfBlank
        let serverIDToStore = serverID?.nilIfBlank ?? currentExpectedServerID?.nilIfBlank
        let rememberedURLString = currentServiceResolution?.url?.absoluteString ?? controlURL?.absoluteString
        guard let tokenToStore, let serverIDToStore, let rememberedURLString else { return }

        let macName = currentServiceResolution?.displayName
            ?? trustedMacCredential?.macName
            ?? controlURL?.host
            ?? "Thumble Mac"
        let credential = TrustedMacCredential(
            serverID: serverIDToStore,
            authToken: tokenToStore,
            macName: macName,
            lastURLString: rememberedURLString,
            updatedAt: Date.currentMilliseconds
        )
        trustedMacCredential = credential
        Self.saveTrustedMacCredential(credential)
    }

    private func clearTrustedMacCredential() {
        trustedMacCredential = nil
        UserDefaults.standard.removeObject(forKey: Self.trustedMacCredentialDefaultsKey)
        autoReconnectEnabled = false
        smartConnectStatus = nil
    }

    private func startSmartDiscovery(for credential: TrustedMacCredential) {
        smartDiscovery?.stop()
        let discovery = MacServiceDiscovery(
            expectedServerID: credential.serverID,
            expectedServiceName: nil,
            onStatus: { [weak self] status in
                self?.smartConnectStatus = status
            },
            onResolved: { [weak self] resolution in
                guard let self else { return }
                var updatedCredential = credential
                updatedCredential.macName = resolution.displayName.nilIfBlank ?? credential.macName
                if let url = resolution.url {
                    updatedCredential.lastURLString = url.absoluteString
                }
                updatedCredential.updatedAt = Date.currentMilliseconds
                self.trustedMacCredential = updatedCredential
                Self.saveTrustedMacCredential(updatedCredential)
                self.stopSmartDiscovery()
                self.smartConnectStatus = "Smart Connect: found \(updatedCredential.macName)"
                self.connectTrusted(to: resolution, credential: updatedCredential)
            }
        )
        smartDiscovery = discovery
        discovery.start(statusMessage: "Smart Connect: scanning nearby Macs…")
    }

    private func startPairingDiscovery(for payload: PairingPayload, pairingCode: String) {
        pairingDiscovery?.stop()
        let discovery = MacServiceDiscovery(
            expectedServerID: payload.serverID?.nilIfBlank,
            expectedServiceName: payload.serviceName?.nilIfBlank,
            onStatus: { [weak self] status in
                self?.smartConnectStatus = status
            },
            onResolved: { [weak self] resolution in
                guard let self else { return }
                self.stopPairingDiscovery()
                self.smartConnectStatus = "Nearby Pairing: found \(resolution.displayName)"
                self.openConnection(target: .service(resolution), pairingCode: pairingCode)
            }
        )
        pairingDiscovery = discovery
        discovery.start(statusMessage: "Nearby Pairing: looking for this Mac…")
    }

    private func stopSmartDiscovery() {
        smartDiscovery?.stop()
        smartDiscovery = nil
    }

    private func stopPairingDiscovery() {
        pairingDiscovery?.stop()
        pairingDiscovery = nil
    }

    private func scheduleSmartReconnectIfNeeded() {
        guard autoReconnectEnabled, let credential = trustedMacCredential else { return }
        guard state != .connected, state != .pairingCodeRequired else { return }
        guard reconnectTask == nil else { return }

        smartConnectStatus = "Smart Connect: reconnecting…"
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            self.startSmartConnect(using: credential)
        }
    }

    private func startSmartConnect(using credential: TrustedMacCredential) {
        trustedMacCredential = credential
        autoReconnectEnabled = true
        if let url = credential.lastURL {
            connectTrusted(to: url, credential: credential)
        }
        startSmartDiscovery(for: credential)
    }

    private func handleSocketError(_ error: Error, for failedConnection: NWConnection) {
        guard connection === failedConnection else { return }
        inputTransport.disconnect()
        lastError = error.localizedDescription
        stopRealtimeDatagram()
        lastSentEventUpdateTask?.cancel()
        lastSentEventUpdateTask = nil
        connection = nil
        controlURL = nil
        currentServiceResolution = nil
        currentAuthToken = nil
        currentExpectedServerID = nil
        serverCapabilities = []
        UIApplication.shared.isIdleTimerDisabled = false
        state = .failed(error.localizedDescription)
        scheduleSmartReconnectIfNeeded()
    }

    private func startRealtimeDatagram(realtimeToken: String?) {
        stopRealtimeDatagram()

        guard let realtimeToken,
              let controlURL,
              let host = controlURL.host,
              let port = realtimeDatagramPort(for: controlURL)
        else {
            return
        }

        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true
        parameters.allowLocalEndpointReuse = true

        let datagramConnection = NWConnection(
            host: NWEndpoint.Host(host),
            port: port,
            using: parameters
        )
        realtimeDatagramConnection = datagramConnection
        isRealtimeDatagramReady = false
        inputTransport.setRealtimeDatagramConnection(datagramConnection, ready: false)

        datagramConnection.stateUpdateHandler = { [weak self, weak datagramConnection] state in
            guard let datagramConnection else { return }
            Task { @MainActor in
                self?.handleRealtimeDatagramState(
                    state,
                    connection: datagramConnection,
                    realtimeToken: realtimeToken
                )
            }
        }

        datagramConnection.start(queue: networkQueue)
    }

    private func handleRealtimeDatagramState(
        _ state: NWConnection.State,
        connection stateConnection: NWConnection,
        realtimeToken: String
    ) {
        guard realtimeDatagramConnection === stateConnection else { return }

        switch state {
        case .ready:
            isRealtimeDatagramReady = true
            inputTransport.setRealtimeDatagramReady(true, for: stateConnection)
            startRealtimeDatagramHandshake(realtimeToken: realtimeToken)

        case .failed, .cancelled:
            if realtimeDatagramConnection === stateConnection {
                realtimeDatagramConnection = nil
                isRealtimeDatagramReady = false
                inputTransport.clearRealtimeDatagramConnection(stateConnection)
            }
            realtimeDatagramHandshakeTask?.cancel()
            realtimeDatagramHandshakeTask = nil

        default:
            break
        }
    }

    private func startRealtimeDatagramHandshake(realtimeToken: String) {
        realtimeDatagramHandshakeTask?.cancel()
        realtimeDatagramHandshakeTask = Task { @MainActor [weak self] in
            for _ in 0..<5 {
                guard let self, !Task.isCancelled else { return }
                self.sendRealtimeDatagramHello(realtimeToken: realtimeToken)
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            self?.realtimeDatagramHandshakeTask = nil
        }
    }

    private func sendRealtimeDatagramHello(realtimeToken: String) {
        guard let data = try? ControllerWireCodec.encode(
            .init(
                type: .hello,
                timestamp: 0,
                clientName: UIDevice.current.name,
                realtimeToken: realtimeToken,
                clientDeviceInfo: Self.currentDeviceInfo()
            ),
            using: encoder
        ) else {
            return
        }

        _ = sendRealtimeDatagramData(data)
    }

    private func stopRealtimeDatagram() {
        realtimeDatagramHandshakeTask?.cancel()
        realtimeDatagramHandshakeTask = nil
        inputTransport.clearRealtimeDatagramConnection(realtimeDatagramConnection)
        realtimeDatagramConnection?.cancel()
        realtimeDatagramConnection = nil
        isRealtimeDatagramReady = false
    }

    private func realtimeDatagramPort(for url: URL) -> NWEndpoint.Port? {
        let portValue = url.port ?? Int(Self.defaultPort)
        guard let port = UInt16(exactly: portValue) else { return nil }
        return NWEndpoint.Port(rawValue: port)
    }

    private static func loadTrustedMacCredential() -> TrustedMacCredential? {
        guard let data = UserDefaults.standard.data(forKey: trustedMacCredentialDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(TrustedMacCredential.self, from: data)
    }

    private static func saveTrustedMacCredential(_ credential: TrustedMacCredential) {
        guard let data = try? JSONEncoder().encode(credential) else { return }
        UserDefaults.standard.set(data, forKey: trustedMacCredentialDefaultsKey)
    }

    private static func loadHasSavedKeypadSnapshot() -> Bool {
        UserDefaults.standard.bool(forKey: hasSavedKeypadSnapshotDefaultsKey)
    }

    private static func loadPendingSkinSelectionMutations() -> [PendingSkinSelectionMutation] {
        guard let data = UserDefaults.standard.data(forKey: pendingSkinSelectionDefaultsKey) else { return [] }
        return (try? JSONDecoder().decode([PendingSkinSelectionMutation].self, from: data)) ?? []
    }

    private func persistPendingSkinSelectionMutations() {
        guard let data = try? JSONEncoder().encode(pendingSkinSelectionMutations) else { return }
        UserDefaults.standard.set(data, forKey: Self.pendingSkinSelectionDefaultsKey)
    }

    private static func loadPendingSkinRemovals() -> [ThumbleSkinReference] {
        guard let data = UserDefaults.standard.data(forKey: pendingSkinRemovalDefaultsKey) else { return [] }
        return (try? JSONDecoder().decode([ThumbleSkinReference].self, from: data)) ?? []
    }

    private func persistPendingSkinRemovals() {
        guard let data = try? JSONEncoder().encode(pendingSkinRemovals) else { return }
        UserDefaults.standard.set(data, forKey: Self.pendingSkinRemovalDefaultsKey)
    }

    private func markSavedKeypadSnapshotAvailable() {
        guard !hasSavedKeypadSnapshot else { return }
        hasSavedKeypadSnapshot = true
        UserDefaults.standard.set(true, forKey: Self.hasSavedKeypadSnapshotDefaultsKey)
    }

    private static func isUsableRemoteURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased().nilIfBlank else { return false }
        return host != "localhost" && host != "127.0.0.1" && host != "::1"
    }

    private func makeURL(hostField: String, port: String) -> URL? {
        let trimmedHost = hostField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { return nil }

        if trimmedHost.lowercased().hasPrefix("ws://") || trimmedHost.lowercased().hasPrefix("wss://") {
            return URL(string: trimmedHost)
        }

        let cleanPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalPort = cleanPort.isEmpty ? "8765" : cleanPort
        return URL(string: "ws://\(trimmedHost):\(finalPort)")
    }

}

private struct TrustedMacCredential: Codable, Equatable {
    var serverID: String
    var authToken: String
    var macName: String
    var lastURLString: String
    var updatedAt: Int64

    var lastURL: URL? {
        URL(string: lastURLString)
    }
}

private final class MacServiceDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private static let netServiceType = "_pocketpad._tcp."
    private static let endpointServiceType = "_pocketpad._tcp"
    private static let defaultDomain = "local"

    private let expectedServerID: String?
    private let expectedServiceName: String?
    private let onStatus: (String?) -> Void
    private let onResolved: (MacServiceResolution) -> Void
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []

    init(
        expectedServerID: String?,
        expectedServiceName: String?,
        onStatus: @escaping (String?) -> Void,
        onResolved: @escaping (MacServiceResolution) -> Void
    ) {
        self.expectedServerID = expectedServerID?.nilIfBlank
        self.expectedServiceName = expectedServiceName?.nilIfBlank
        self.onStatus = onStatus
        self.onResolved = onResolved
        super.init()
        browser.delegate = self
        browser.includesPeerToPeer = true
    }

    func start(statusMessage: String) {
        onStatus(statusMessage)
        browser.searchForServices(ofType: Self.netServiceType, inDomain: "local.")
    }

    func stop() {
        browser.stop()
        services.forEach { $0.stop() }
        services.removeAll()
        onStatus(nil)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        service.includesPeerToPeer = true
        services.append(service)
        service.resolve(withTimeout: 4)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let serverID = serviceServerID(sender)
        if let expectedServerID {
            guard serverID == expectedServerID else { return }
        } else if let expectedServiceName {
            guard sender.name == expectedServiceName else { return }
        }
        guard sender.port > 0 else { return }

        let hostName = sender.hostName?
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .nilIfBlank
        let displayName = serviceDisplayName(sender) ?? sender.name
        let resolution = MacServiceResolution(
            serviceName: sender.name,
            serviceType: Self.endpointServiceType,
            serviceDomain: Self.normalizedDomain(sender.domain),
            hostName: hostName,
            port: sender.port,
            serverID: serverID,
            displayName: displayName
        )
        onResolved(resolution)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        services.removeAll { $0 === sender }
    }

    private func serviceServerID(_ service: NetService) -> String? {
        guard let txtRecordData = service.txtRecordData() else { return nil }
        let record = NetService.dictionary(fromTXTRecord: txtRecordData)
        guard let data = record["id"] else { return nil }
        return String(data: data, encoding: .utf8)?.nilIfBlank
    }

    private func serviceDisplayName(_ service: NetService) -> String? {
        guard let txtRecordData = service.txtRecordData() else { return nil }
        let record = NetService.dictionary(fromTXTRecord: txtRecordData)
        guard let data = record["name"] else { return nil }
        return String(data: data, encoding: .utf8)?.nilIfBlank
    }

    private static func normalizedDomain(_ domain: String) -> String {
        let normalized = domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalized.nilIfBlank ?? Self.defaultDomain
    }
}

private extension UIInterfaceOrientation {
    var deviceInfoName: String {
        switch self {
        case .portrait: "portrait"
        case .portraitUpsideDown: "portraitUpsideDown"
        case .landscapeLeft: "landscapeLeft"
        case .landscapeRight: "landscapeRight"
        case .unknown: "unknown"
        @unknown default: "unknown"
        }
    }
}

private extension UIUserInterfaceStyle {
    var deviceInfoName: String {
        switch self {
        case .light: "light"
        case .dark: "dark"
        case .unspecified: "unspecified"
        @unknown default: "unknown"
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
