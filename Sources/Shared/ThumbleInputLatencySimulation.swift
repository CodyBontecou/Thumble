import Foundation

public enum ThumbleLatencySimulationPattern: String, Codable, CaseIterable, Sendable {
    case hollowKnight = "hollow-knight"
    case sameButtonBurst = "same-button-burst"
    case udpRecovery = "udp-recovery"
    case udpRecoveryBurst = "udp-recovery-burst"
    case heldDirectionHeartbeatRecovery = "held-direction-heartbeat-recovery"

    public var displayName: String {
        switch self {
        case .hollowKnight:
            "Hollow Knight"
        case .sameButtonBurst:
            "Same-button burst"
        case .udpRecovery:
            "UDP recovery"
        case .udpRecoveryBurst:
            "UDP recovery burst"
        case .heldDirectionHeartbeatRecovery:
            "Held direction heartbeat recovery"
        }
    }
}

public enum ThumbleLatencySimulationMode: String, Codable, CaseIterable, Sendable {
    case current
    case legacyMainActor = "legacy-main-actor"

    public var displayName: String {
        switch self {
        case .current:
            "Current modeled path"
        case .legacyMainActor:
            "Legacy main-actor model"
        }
    }
}

public struct ThumbleLatencySimulationReport: Codable, Sendable {
    public var pattern: ThumbleLatencySimulationPattern
    public var mode: ThumbleLatencySimulationMode
    public var assumptions: [String: Double]
    public var summary: ThumbleLatencySimulationSummary
    public var samples: [ThumbleLatencySimulationSample]
    public var duplicateMirrorFrames: Int
    public var staleFrames: Int
    public var bufferedFrames: Int
    public var recoveredByMirrorFrames: Int
    public var missedFrames: Int
    public var heartbeatResyncFrames: Int
}

public struct ThumbleLatencyVerificationReport: Codable, Sendable {
    public var passed: Bool
    public var maxAllowedMilliseconds: Double
    public var p95AllowedMilliseconds: Double
    public var reports: [ThumbleLatencySimulationReport]
    public var failures: [String]
}

public struct ThumbleLatencySimulationSummary: Codable, Sendable {
    public var sampleCount: Int
    public var p50Milliseconds: Double
    public var p95Milliseconds: Double
    public var maxMilliseconds: Double
    public var overEightMilliseconds: Int
    public var overSixteenMilliseconds: Int
}

public struct ThumbleLatencySimulationSample: Codable, Sendable {
    public var sequenceNumber: UInt64
    public var button: KeypadElementID
    public var state: ButtonPressState
    public var touchAtMilliseconds: Double
    public var observedAtMilliseconds: Double
    public var sentAtMilliseconds: Double
    public var injectedAtMilliseconds: Double?
    public var latencyMilliseconds: Double?
    public var source: String?
    public var buffered: Bool
    public var recoveredByMirror: Bool
    public var heartbeatResync: Bool
    public var note: String?
}

public enum ThumbleInputLatencySimulator {
    public static func run(
        pattern: ThumbleLatencySimulationPattern = .hollowKnight,
        mode: ThumbleLatencySimulationMode = .current
    ) -> ThumbleLatencySimulationReport {
        var simulator = Simulation(pattern: pattern, mode: mode)
        return simulator.run()
    }

    public static func verifyCurrentPath(
        patterns: [ThumbleLatencySimulationPattern] = [
            .hollowKnight,
            .sameButtonBurst,
            .udpRecovery,
            .udpRecoveryBurst,
            .heldDirectionHeartbeatRecovery
        ],
        maxAllowedMilliseconds: Double = 4,
        p95AllowedMilliseconds: Double = 4
    ) -> ThumbleLatencyVerificationReport {
        let reports = patterns.map {
            run(pattern: $0, mode: .current)
        }
        let failures = reports.flatMap { report -> [String] in
            var failures: [String] = []
            if report.summary.maxMilliseconds > maxAllowedMilliseconds {
                failures.append(
                    "\(report.pattern.rawValue) max \(millisecondsText(report.summary.maxMilliseconds)) ms exceeded \(millisecondsText(maxAllowedMilliseconds)) ms"
                )
            }
            if report.summary.p95Milliseconds > p95AllowedMilliseconds {
                failures.append(
                    "\(report.pattern.rawValue) p95 \(millisecondsText(report.summary.p95Milliseconds)) ms exceeded \(millisecondsText(p95AllowedMilliseconds)) ms"
                )
            }
            if report.summary.overSixteenMilliseconds > 0 {
                failures.append(
                    "\(report.pattern.rawValue) had \(report.summary.overSixteenMilliseconds) edge(s) over one 60 FPS frame"
                )
            }
            return failures
        }
        return ThumbleLatencyVerificationReport(
            passed: failures.isEmpty,
            maxAllowedMilliseconds: maxAllowedMilliseconds,
            p95AllowedMilliseconds: p95AllowedMilliseconds,
            reports: reports,
            failures: failures
        )
    }
}

private struct Simulation {
    private enum Lane: String {
        case udp = "udp"
        case tcpMirror = "tcp-mirror"
    }

    private struct InputEdge {
        var at: UInt64
        var button: KeypadElementID
        var state: ButtonPressState
        var pressIdentifier: UInt64?
    }

    private struct ClientInputEvent {
        var input: InputEdge
        var touchAt: UInt64
        var heartbeatResync: Bool
    }

    private struct ClientEdge {
        var input: InputEdge
        var sequenceNumber: UInt64
        var observedAt: UInt64
        var sentAt: UInt64
        var data: Data
    }

    private struct FrameEvent {
        var at: UInt64
        var sequenceNumber: UInt64
        var lane: Lane
        var data: Data
        var ordinal: Int
    }

    private enum ScheduledEvent {
        case frame(FrameEvent)
        case flush(at: UInt64, generation: Int, ordinal: Int)

        var at: UInt64 {
            switch self {
            case .frame(let frame):
                frame.at
            case .flush(let at, _, _):
                at
            }
        }

        var ordinal: Int {
            switch self {
            case .frame(let frame):
                frame.ordinal
            case .flush(_, _, let ordinal):
                ordinal
            }
        }
    }

    private struct MutableSample {
        var sequenceNumber: UInt64
        var button: KeypadElementID
        var state: ButtonPressState
        var touchAt: UInt64
        var observedAt: UInt64
        var sentAt: UInt64
        var injectedAt: UInt64?
        var source: String?
        var buffered = false
        var recoveredByMirror = false
        var heartbeatResync = false
        var note: String?

        var output: ThumbleLatencySimulationSample {
            let latency = injectedAt.map { $0 >= touchAt ? $0 - touchAt : 0 }
            return ThumbleLatencySimulationSample(
                sequenceNumber: sequenceNumber,
                button: button,
                state: state,
                touchAtMilliseconds: milliseconds(touchAt),
                observedAtMilliseconds: milliseconds(observedAt),
                sentAtMilliseconds: milliseconds(sentAt),
                injectedAtMilliseconds: injectedAt.map(milliseconds),
                latencyMilliseconds: latency.map(milliseconds),
                source: source,
                buffered: buffered,
                recoveredByMirror: recoveredByMirror,
                heartbeatResync: heartbeatResync,
                note: note
            )
        }
    }

    private static let inputHandlerNanoseconds: UInt64 = 120_000
    private static let optimizedAsyncHapticNanoseconds: UInt64 = 600_000
    private static let optimizedNetworkEnqueueNanoseconds: UInt64 = 90_000
    private static let legacySynchronousSendNanoseconds: UInt64 = 1_800_000
    private static let legacyHapticAndStatusNanoseconds: UInt64 = 5_200_000
    private static let udpLatencyNanoseconds: UInt64 = 1_200_000
    private static let tcpLatencyNanoseconds: UInt64 = 3_200_000
    private static let reliableMirrorDelayNanoseconds: UInt64 = 500_000
    private static let buttonReorderDelayNanoseconds: UInt64 = 4_000_000
    private static let heldDirectionHeartbeatResyncNanoseconds: UInt64 = 850_000_000

    private let pattern: ThumbleLatencySimulationPattern
    private let mode: ThumbleLatencySimulationMode
    private var samples: [UInt64: MutableSample] = [:]
    private var pendingFrames: [UInt64: FrameEvent] = [:]
    private var sequenceTracker = ButtonSequenceTracker()
    private var flushGeneration = 0
    private var nextOrdinal = 0
    private var duplicateMirrorFrames = 0
    private var staleFrames = 0
    private var bufferedFrames = 0
    private var recoveredByMirrorFrames = 0

    init(pattern: ThumbleLatencySimulationPattern, mode: ThumbleLatencySimulationMode) {
        self.pattern = pattern
        self.mode = mode
    }

    mutating func run() -> ThumbleLatencySimulationReport {
        var scheduledEvents = scheduledFrameEvents(for: clientEdges())
        process(&scheduledEvents)

        let orderedSamples = samples.values
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
            .map(\.output)
        let latencies = orderedSamples.compactMap(\.latencyMilliseconds).sorted()
        let summary = ThumbleLatencySimulationSummary(
            sampleCount: latencies.count,
            p50Milliseconds: percentile(0.50, in: latencies),
            p95Milliseconds: percentile(0.95, in: latencies),
            maxMilliseconds: latencies.last ?? 0,
            overEightMilliseconds: latencies.filter { $0 > 8 }.count,
            overSixteenMilliseconds: latencies.filter { $0 > 16 }.count
        )

        return ThumbleLatencySimulationReport(
            pattern: pattern,
            mode: mode,
            assumptions: assumptions,
            summary: summary,
            samples: orderedSamples,
            duplicateMirrorFrames: duplicateMirrorFrames,
            staleFrames: staleFrames,
            bufferedFrames: bufferedFrames,
            recoveredByMirrorFrames: recoveredByMirrorFrames,
            missedFrames: sequenceTracker.totalMissedFrameCount,
            heartbeatResyncFrames: orderedSamples.filter(\.heartbeatResync).count
        )
    }

    private var assumptions: [String: Double] {
        [
            "inputHandlerMS": milliseconds(Self.inputHandlerNanoseconds),
            "optimizedAsyncHapticMS": milliseconds(Self.optimizedAsyncHapticNanoseconds),
            "optimizedNetworkEnqueueMS": milliseconds(Self.optimizedNetworkEnqueueNanoseconds),
            "legacySynchronousSendMS": milliseconds(Self.legacySynchronousSendNanoseconds),
            "legacyHapticAndStatusMS": milliseconds(Self.legacyHapticAndStatusNanoseconds),
            "udpLatencyMS": milliseconds(Self.udpLatencyNanoseconds),
            "tcpLatencyMS": milliseconds(Self.tcpLatencyNanoseconds),
            "reliableMirrorDelayMS": milliseconds(Self.reliableMirrorDelayNanoseconds),
            "buttonReorderDelayMS": milliseconds(Self.buttonReorderDelayNanoseconds),
            "heldDirectionHeartbeatResyncMS": milliseconds(Self.heldDirectionHeartbeatResyncNanoseconds)
        ]
    }

    private func inputEdges() -> [InputEdge] {
        switch pattern {
        case .hollowKnight:
            return [
                .init(at: ns(0), button: .preset(4), state: .down, pressIdentifier: 1),
                .init(at: ns(18), button: .preset(5), state: .down, pressIdentifier: 2),
                .init(at: ns(32), button: .preset(6), state: .down, pressIdentifier: 3),
                .init(at: ns(38), button: .preset(5), state: .up, pressIdentifier: 2),
                .init(at: ns(52), button: .preset(6), state: .up, pressIdentifier: 3),
                .init(at: ns(68), button: .preset(7), state: .down, pressIdentifier: 4),
                .init(at: ns(82), button: .preset(7), state: .up, pressIdentifier: 4),
                .init(at: ns(96), button: .preset(5), state: .down, pressIdentifier: 5),
                .init(at: ns(112), button: .preset(5), state: .up, pressIdentifier: 5),
                .init(at: ns(128), button: .preset(4), state: .up, pressIdentifier: 1),
                .init(at: ns(130), button: .preset(3), state: .down, pressIdentifier: 6),
                .init(at: ns(146), button: .preset(6), state: .down, pressIdentifier: 7),
                .init(at: ns(164), button: .preset(6), state: .up, pressIdentifier: 7),
                .init(at: ns(178), button: .preset(3), state: .up, pressIdentifier: 6)
            ]

        case .sameButtonBurst:
            var edges: [InputEdge] = []
            for index in 0..<10 {
                let base = UInt64(index * 12)
                let identifier = UInt64(index + 1)
                edges.append(.init(at: ns(base), button: .preset(5), state: .down, pressIdentifier: identifier))
                edges.append(.init(at: ns(base + 5), button: .preset(5), state: .up, pressIdentifier: identifier))
            }
            return edges

        case .udpRecovery:
            return [
                .init(at: ns(0), button: .preset(4), state: .down, pressIdentifier: 1),
                .init(at: ns(12), button: .preset(5), state: .down, pressIdentifier: 2),
                .init(at: ns(24), button: .preset(5), state: .up, pressIdentifier: 2),
                .init(at: ns(36), button: .preset(6), state: .down, pressIdentifier: 3),
                .init(at: ns(48), button: .preset(6), state: .up, pressIdentifier: 3),
                .init(at: ns(60), button: .preset(4), state: .up, pressIdentifier: 1)
            ]

        case .udpRecoveryBurst:
            return [
                .init(at: ns(0), button: .preset(4), state: .down, pressIdentifier: 1),
                .init(at: ns(1), button: .preset(5), state: .down, pressIdentifier: 2),
                .init(at: ns(2), button: .preset(6), state: .down, pressIdentifier: 3),
                .init(at: ns(3), button: .preset(5), state: .up, pressIdentifier: 2),
                .init(at: ns(4), button: .preset(7), state: .down, pressIdentifier: 4),
                .init(at: ns(5), button: .preset(6), state: .up, pressIdentifier: 3),
                .init(at: ns(6), button: .preset(7), state: .up, pressIdentifier: 4),
                .init(at: ns(7), button: .preset(4), state: .up, pressIdentifier: 1)
            ]

        case .heldDirectionHeartbeatRecovery:
            return [
                .init(at: ns(0), button: .preset(3), state: .down, pressIdentifier: 1),
                .init(at: ns(1_800), button: .preset(3), state: .up, pressIdentifier: 1)
            ]
        }
    }

    private func clientInputEvents() -> [ClientInputEvent] {
        let userEdges = inputEdges()
        guard pattern == .heldDirectionHeartbeatRecovery else {
            return userEdges.map {
                ClientInputEvent(input: $0, touchAt: $0.at, heartbeatResync: false)
            }
        }

        let resyncAt = Self.heldDirectionHeartbeatResyncNanoseconds
        var events: [ClientInputEvent] = []
        var activeInputState = ControllerActiveInputState()
        var didInsertResync = false

        func appendHeartbeatResyncIfNeeded() {
            guard !didInsertResync else { return }
            didInsertResync = true
            for activePress in activeInputState.activePresses {
                events.append(
                    ClientInputEvent(
                        input: .init(
                            at: resyncAt,
                            button: activePress.button,
                            state: .down,
                            pressIdentifier: activePress.pressIdentifier
                        ),
                        touchAt: resyncAt,
                        heartbeatResync: true
                    )
                )
            }
        }

        for edge in userEdges {
            if edge.at >= resyncAt {
                appendHeartbeatResyncIfNeeded()
            }

            events.append(ClientInputEvent(input: edge, touchAt: edge.at, heartbeatResync: false))
            activeInputState.record(
                button: edge.button,
                state: edge.state,
                pressIdentifier: edge.pressIdentifier
            )
        }

        appendHeartbeatResyncIfNeeded()
        return events
    }

    private mutating func clientEdges() -> [ClientEdge] {
        var mainAvailableAt: UInt64 = 0
        var networkAvailableAt: UInt64 = 0
        var sequenceNumber: UInt64 = 0

        return clientInputEvents().map { event in
            let input = event.input
            let observedAt = max(input.at, mainAvailableAt)
            sequenceNumber += 1

            let sentAt: UInt64
            switch mode {
            case .current:
                let queuedAt = observedAt + Self.inputHandlerNanoseconds
                sentAt = max(networkAvailableAt, queuedAt) + Self.optimizedNetworkEnqueueNanoseconds
                networkAvailableAt = sentAt
                mainAvailableAt = observedAt
                    + Self.inputHandlerNanoseconds
                    + Self.optimizedAsyncHapticNanoseconds

            case .legacyMainActor:
                sentAt = observedAt
                    + Self.inputHandlerNanoseconds
                    + Self.legacySynchronousSendNanoseconds
                networkAvailableAt = sentAt
                mainAvailableAt = sentAt + Self.legacyHapticAndStatusNanoseconds
            }

            let data = ControllerWireCodec.encodeButton(
                input.button,
                state: input.state,
                sequenceNumber: sequenceNumber,
                pressIdentifier: input.pressIdentifier
            )
            samples[sequenceNumber] = MutableSample(
                sequenceNumber: sequenceNumber,
                button: input.button,
                state: input.state,
                touchAt: event.touchAt,
                observedAt: observedAt,
                sentAt: sentAt,
                heartbeatResync: event.heartbeatResync,
                note: event.heartbeatResync ? "Heartbeat re-sync reasserted active hold after remote timeout" : nil
            )

            return ClientEdge(
                input: input,
                sequenceNumber: sequenceNumber,
                observedAt: observedAt,
                sentAt: sentAt,
                data: data
            )
        }
    }

    private mutating func scheduledFrameEvents(for clientEdges: [ClientEdge]) -> [ScheduledEvent] {
        var events: [ScheduledEvent] = []
        let droppedUDPSequences = udpDroppedSequences()

        for edge in clientEdges {
            if !droppedUDPSequences.contains(edge.sequenceNumber) {
                events.append(
                    .frame(
                        FrameEvent(
                            at: edge.sentAt + Self.udpLatencyNanoseconds,
                            sequenceNumber: edge.sequenceNumber,
                            lane: .udp,
                            data: edge.data,
                            ordinal: makeOrdinal()
                        )
                    )
                )
            }

            events.append(
                .frame(
                    FrameEvent(
                        at: edge.sentAt + Self.reliableMirrorDelayNanoseconds + Self.tcpLatencyNanoseconds,
                        sequenceNumber: edge.sequenceNumber,
                        lane: .tcpMirror,
                        data: edge.data,
                        ordinal: makeOrdinal()
                    )
                )
            )
        }

        return sorted(events)
    }

    private func udpDroppedSequences() -> Set<UInt64> {
        switch pattern {
        case .udpRecovery:
            return [2, 4]
        case .udpRecoveryBurst:
            return [2, 5]
        case .hollowKnight, .sameButtonBurst, .heldDirectionHeartbeatRecovery:
            return []
        }
    }

    private mutating func process(_ events: inout [ScheduledEvent]) {
        while !events.isEmpty {
            events = sorted(events)
            let event = events.removeFirst()
            switch event {
            case .frame(let frame):
                receive(frame, at: frame.at, events: &events)

            case .flush(let at, let generation, _):
                guard generation == flushGeneration else { continue }
                flushGeneration += 1
                drainPendingFrames(at: at, flushAllGaps: true)
            }
        }
    }

    private mutating func receive(
        _ frame: FrameEvent,
        at now: UInt64,
        events: inout [ScheduledEvent]
    ) {
        guard let message = try? ControllerWireCodec.decode(frame.data, using: JSONDecoder()),
              let button = message.button,
              let state = message.state,
              let sequenceNumber = ControllerWireCodec.buttonSequenceNumber(from: message)
        else {
            return
        }

        if shouldBuffer(sequenceNumber: sequenceNumber) {
            if pendingFrames[sequenceNumber] == nil {
                pendingFrames[sequenceNumber] = frame
                bufferedFrames += 1
                let expectedDescription = expectedSequenceDescription
                updateSample(sequenceNumber) { sample in
                    sample.buffered = true
                    sample.note = "Buffered while waiting for sequence \(expectedDescription)"
                }
            }
            scheduleFlushIfNeeded(at: now, events: &events)
            return
        }

        process(
            message,
            sequenceNumber: sequenceNumber,
            button: button,
            state: state,
            source: frame.lane.rawValue,
            at: now
        )
        drainPendingFrames(at: now)

        if pendingFrames.isEmpty {
            flushGeneration += 1
        }
    }

    private var expectedSequenceDescription: String {
        sequenceTracker.nextExpectedSequenceNumber.map(String.init) ?? "baseline"
    }

    private func shouldBuffer(sequenceNumber: UInt64) -> Bool {
        guard let expectedSequence = sequenceTracker.nextExpectedSequenceNumber else {
            return sequenceNumber > 1 && !sequenceTracker.isAcceptingNextSequenceAsBaseline
        }

        return sequenceNumber > expectedSequence
    }

    private mutating func drainPendingFrames(at now: UInt64, flushAllGaps: Bool = false) {
        while true {
            if let expectedSequence = sequenceTracker.nextExpectedSequenceNumber,
               let pendingFrame = pendingFrames.removeValue(forKey: expectedSequence),
               let message = try? ControllerWireCodec.decode(pendingFrame.data, using: JSONDecoder()),
               let button = message.button,
               let state = message.state
            {
                process(
                    message,
                    sequenceNumber: expectedSequence,
                    button: button,
                    state: state,
                    source: pendingFrame.lane.rawValue,
                    at: now
                )
                continue
            }

            guard flushAllGaps,
                  let nextSequence = pendingFrames.keys.min(),
                  let pendingFrame = pendingFrames.removeValue(forKey: nextSequence),
                  let message = try? ControllerWireCodec.decode(pendingFrame.data, using: JSONDecoder()),
                  let button = message.button,
                  let state = message.state
            else {
                return
            }

            process(
                message,
                sequenceNumber: nextSequence,
                button: button,
                state: state,
                source: pendingFrame.lane.rawValue,
                at: now
            )
        }
    }

    private mutating func process(
        _ message: ControllerMessage,
        sequenceNumber: UInt64,
        button: KeypadElementID,
        state: ButtonPressState,
        source: String,
        at now: UInt64
    ) {
        let inspection = sequenceTracker.inspect(message)
        if inspection.isOutOfOrderOrReset {
            staleFrames += 1
            if samples[sequenceNumber]?.injectedAt != nil {
                duplicateMirrorFrames += 1
            }
            return
        }

        guard samples[sequenceNumber]?.injectedAt == nil else {
            duplicateMirrorFrames += 1
            return
        }

        updateSample(sequenceNumber) { sample in
            sample.injectedAt = now
            sample.source = source
        }
        if source == Lane.tcpMirror.rawValue {
            updateSample(sequenceNumber) { sample in
                sample.recoveredByMirror = true
            }
            recoveredByMirrorFrames += 1
        }
        if inspection.missedFrameBeforeButton {
            let missed = inspection.missedFrameCount
            updateSample(sequenceNumber) { sample in
                sample.note = "Processed after sequence gap; missed \(missed) frame(s)"
            }
        }
        _ = button
        _ = state
    }

    private mutating func updateSample(
        _ sequenceNumber: UInt64,
        _ update: (inout MutableSample) -> Void
    ) {
        guard var sample = samples[sequenceNumber] else { return }
        update(&sample)
        samples[sequenceNumber] = sample
    }

    private mutating func scheduleFlushIfNeeded(at now: UInt64, events: inout [ScheduledEvent]) {
        guard !events.contains(where: {
            if case .flush(_, let generation, _) = $0 {
                return generation == flushGeneration
            }
            return false
        }) else {
            return
        }

        scheduleFlush(at: now, events: &events)
    }

    private mutating func scheduleFlush(at now: UInt64, events: inout [ScheduledEvent]) {
        events.append(
            .flush(
                at: now + Self.buttonReorderDelayNanoseconds,
                generation: flushGeneration,
                ordinal: makeOrdinal()
            )
        )
    }

    private mutating func makeOrdinal() -> Int {
        defer { nextOrdinal += 1 }
        return nextOrdinal
    }

    private func sorted(_ events: [ScheduledEvent]) -> [ScheduledEvent] {
        events.sorted {
            if $0.at == $1.at {
                return $0.ordinal < $1.ordinal
            }
            return $0.at < $1.at
        }
    }

    private func percentile(_ value: Double, in sortedValues: [Double]) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        let boundedValue = min(max(value, 0), 1)
        let index = Int((Double(sortedValues.count - 1) * boundedValue).rounded())
        return sortedValues[index]
    }
}

private func ns(_ milliseconds: UInt64) -> UInt64 {
    milliseconds * 1_000_000
}

private func milliseconds(_ nanoseconds: UInt64) -> Double {
    Double(nanoseconds) / 1_000_000
}

private func millisecondsText(_ value: Double) -> String {
    String(format: "%.2f", value)
}
