import Foundation

enum InputPulseCommand<Input: Hashable>: Equatable {
    case send(Input, ButtonPressState)
    case scheduleRelease(Input, delayNanoseconds: UInt64)
    case schedulePress(Input, delayNanoseconds: UInt64)
}

typealias ButtonPulseCommand = InputPulseCommand<KeypadElementID>

struct InputPulseSequencer<Input: Hashable> {
    // Keep synthesized tap edges visible across a 60 FPS game frame without
    // letting rapid same-button bursts back up behind overly conservative holds.
    static var actionGameMinimumTapDurationNanoseconds: UInt64 { 22_000_000 }
    static var actionGameMinimumInterTapGapNanoseconds: UInt64 { 18_000_000 }

    private struct QueuedPress {
        let pressIdentifier: UInt64?
        var isPhysicallyHeld: Bool
        let emitsWhenReleased: Bool
    }

    private enum PhysicalHoldRelease {
        case active
        case pending
        case queued
        case none
    }

    let minimumTapDurationNanoseconds: UInt64
    let minimumInterTapGapNanoseconds: UInt64
    private let shouldEnforceMinimumInterTapGap: (Input) -> Bool

    private var pressedButtons: Set<Input> = []
    private var pressStartUptime: [Input: UInt64] = [:]
    private var lastReleaseUptime: [Input: UInt64] = [:]
    private var activePhysicalPressIdentifiers: [Input: Set<UInt64>] = [:]
    private var activeAnonymousPhysicalHoldButtons: Set<Input> = []
    private var pendingReleaseButtons: Set<Input> = []
    private var pendingPressButtons: Set<Input> = []
    private var pendingPressPhysicalIdentifiers: [Input: UInt64] = [:]
    private var pendingAnonymousPressPhysicalHoldButtons: Set<Input> = []
    private var pendingPressEmitsWhenReleased: [Input: Bool] = [:]
    private var queuedPresses: [Input: [QueuedPress]] = [:]

    init(
        minimumTapDurationNanoseconds: UInt64,
        minimumInterTapGapNanoseconds: UInt64,
        shouldEnforceMinimumInterTapGap: @escaping (Input) -> Bool = { _ in true }
    ) {
        self.minimumTapDurationNanoseconds = minimumTapDurationNanoseconds
        self.minimumInterTapGapNanoseconds = minimumInterTapGapNanoseconds
        self.shouldEnforceMinimumInterTapGap = shouldEnforceMinimumInterTapGap
    }

    mutating func setButton(
        _ button: Input,
        pressed: Bool,
        pressIdentifier: UInt64? = nil,
        now: UInt64
    ) -> [InputPulseCommand<Input>] {
        if pressed {
            if pendingReleaseButtons.contains(button) || pendingPressButtons.contains(button) {
                enqueuePress(button, pressIdentifier: pressIdentifier, isPhysicallyHeld: true)
                return []
            }

            if pressedButtons.contains(button) {
                enqueuePress(button, pressIdentifier: pressIdentifier, isPhysicallyHeld: true)
                return releaseButton(button, respectingMinimumDuration: true, now: now)
            }

            return startPress(
                button,
                pressIdentifier: pressIdentifier,
                isPhysicallyHeld: true,
                now: now
            )
        }

        let releasedPhysicalHold = releasePhysicalHold(for: button, pressIdentifier: pressIdentifier)
        guard !pendingReleaseButtons.contains(button),
              !pendingPressButtons.contains(button)
        else { return [] }
        if pressIdentifier == nil {
            guard !hasPhysicalPress(button) else { return [] }
        } else {
            guard releasedPhysicalHold == .active else { return [] }
        }

        return releaseButton(button, respectingMinimumDuration: true, now: now)
    }

    mutating func recoverMissingReleaseBeforePress(
        _ button: Input,
        pressIdentifier: UInt64? = nil,
        now: UInt64
    ) -> [InputPulseCommand<Input>] {
        if let pressIdentifier {
            _ = removeActivePhysicalHold(for: button, pressIdentifier: pressIdentifier)
        } else {
            clearActivePhysicalHold(for: button)
        }

        if pendingReleaseButtons.contains(button) || pendingPressButtons.contains(button) {
            enqueuePress(button, pressIdentifier: pressIdentifier, isPhysicallyHeld: true)
            return []
        }

        if pressedButtons.contains(button) {
            enqueuePress(button, pressIdentifier: pressIdentifier, isPhysicallyHeld: true)
            return releaseButton(button, respectingMinimumDuration: true, now: now)
        }

        return startPress(
            button,
            pressIdentifier: pressIdentifier,
            isPhysicallyHeld: true,
            now: now
        )
    }

    mutating func recoverMissingPressBeforeRelease(
        _ button: Input,
        pressIdentifier: UInt64? = nil,
        now: UInt64
    ) -> [InputPulseCommand<Input>] {
        if pendingReleaseButtons.contains(button) || pendingPressButtons.contains(button) {
            enqueuePress(button, pressIdentifier: pressIdentifier, isPhysicallyHeld: false)
            return []
        }

        if pressedButtons.contains(button) {
            enqueuePress(button, pressIdentifier: pressIdentifier, isPhysicallyHeld: false)
            return releaseButton(button, respectingMinimumDuration: true, now: now)
        }

        var commands = startPress(
            button,
            pressIdentifier: pressIdentifier,
            isPhysicallyHeld: false,
            now: now
        )
        commands += releaseButton(button, respectingMinimumDuration: true, now: now)
        return commands
    }

    mutating func releaseTimerFired(for button: Input, now: UInt64) -> [InputPulseCommand<Input>] {
        guard pendingReleaseButtons.remove(button) != nil else { return [] }
        return finishRelease(button, now: now)
    }

    mutating func pressTimerFired(for button: Input, now: UInt64) -> [InputPulseCommand<Input>] {
        guard pendingPressButtons.remove(button) != nil else { return [] }
        let pressIdentifier = pendingPressPhysicalIdentifiers.removeValue(forKey: button)
        let hasAnonymousPhysicalHold = pendingAnonymousPressPhysicalHoldButtons.remove(button) != nil
        let emitsWhenReleased = pendingPressEmitsWhenReleased.removeValue(forKey: button) ?? true
        let hasPhysicalHold = pressIdentifier != nil || hasAnonymousPhysicalHold
        guard !pressedButtons.contains(button) else { return [] }

        if !hasPhysicalHold, !emitsWhenReleased {
            return scheduleQueuedPressIfNeeded(for: button, now: now)
        }

        var commands = startPress(
            button,
            pressIdentifier: pressIdentifier,
            isPhysicallyHeld: hasPhysicalHold,
            emitsWhenReleased: emitsWhenReleased,
            now: now
        )
        if !hasPhysicalHold {
            commands += releaseButton(button, respectingMinimumDuration: true, now: now)
        }
        return commands
    }

    mutating func recordOutputReleaseCompleted(for button: Input, now: UInt64) {
        lastReleaseUptime[button] = max(lastReleaseUptime[button] ?? now, now)
    }

    mutating func reset() {
        pressedButtons.removeAll()
        pressStartUptime.removeAll()
        lastReleaseUptime.removeAll()
        activePhysicalPressIdentifiers.removeAll()
        activeAnonymousPhysicalHoldButtons.removeAll()
        pendingReleaseButtons.removeAll()
        pendingPressButtons.removeAll()
        pendingPressPhysicalIdentifiers.removeAll()
        pendingAnonymousPressPhysicalHoldButtons.removeAll()
        pendingPressEmitsWhenReleased.removeAll()
        queuedPresses.removeAll()
    }

    func isPressed(_ button: Input) -> Bool {
        pressedButtons.contains(button)
    }

    func hasPendingOutput(for button: Input) -> Bool {
        pendingReleaseButtons.contains(button) || pendingPressButtons.contains(button)
    }

    func hasPhysicalPress(_ button: Input) -> Bool {
        activeAnonymousPhysicalHoldButtons.contains(button)
            || activePhysicalPressIdentifiers[button]?.isEmpty == false
            || pendingAnonymousPressPhysicalHoldButtons.contains(button)
            || pendingPressPhysicalIdentifiers[button] != nil
            || queuedPresses[button]?.contains(where: \.isPhysicallyHeld) == true
    }

    func hasPhysicalPress(_ button: Input, pressIdentifier: UInt64?) -> Bool {
        guard let pressIdentifier else {
            return hasPhysicalPress(button)
        }

        return activePhysicalPressIdentifiers[button]?.contains(pressIdentifier) == true
            || pendingPressPhysicalIdentifiers[button] == pressIdentifier
            || queuedPresses[button]?.contains {
                $0.pressIdentifier == pressIdentifier && $0.isPhysicallyHeld
            } == true
    }

    private mutating func releaseButton(
        _ button: Input,
        respectingMinimumDuration: Bool,
        now: UInt64
    ) -> [InputPulseCommand<Input>] {
        guard pressedButtons.contains(button) else { return [] }
        guard !respectingMinimumDuration || !pendingReleaseButtons.contains(button) else { return [] }

        let startedAt = pressStartUptime[button] ?? now
        let elapsed = now >= startedAt ? now - startedAt : minimumTapDurationNanoseconds

        if respectingMinimumDuration, elapsed < minimumTapDurationNanoseconds {
            let remaining = minimumTapDurationNanoseconds - elapsed
            pendingReleaseButtons.insert(button)
            return [.scheduleRelease(button, delayNanoseconds: remaining)]
        }

        return finishRelease(button, now: now)
    }

    private mutating func startPress(
        _ button: Input,
        pressIdentifier: UInt64?,
        isPhysicallyHeld: Bool,
        emitsWhenReleased: Bool = true,
        now: UInt64
    ) -> [InputPulseCommand<Input>] {
        if let delayNanoseconds = remainingInterTapDelay(for: button, now: now) {
            setPendingPress(
                button,
                pressIdentifier: pressIdentifier,
                isPhysicallyHeld: isPhysicallyHeld,
                emitsWhenReleased: emitsWhenReleased
            )
            return [.schedulePress(button, delayNanoseconds: delayNanoseconds)]
        }

        pressStartUptime[button] = now
        pressedButtons.insert(button)
        if isPhysicallyHeld {
            markActivePhysicalHold(for: button, pressIdentifier: pressIdentifier)
        }
        return [.send(button, .down)]
    }

    private mutating func finishRelease(_ button: Input, now: UInt64) -> [InputPulseCommand<Input>] {
        guard pressedButtons.contains(button) else { return [] }

        let shouldResumeInterruptedHold = queuedPresses[button]?.isEmpty == false
        let interruptedPhysicalPressIdentifiers = shouldResumeInterruptedHold
            ? activePhysicalPressIdentifiers[button, default: []]
            : []

        pendingReleaseButtons.remove(button)
        pressStartUptime[button] = nil
        pressedButtons.remove(button)
        lastReleaseUptime[button] = max(lastReleaseUptime[button] ?? now, now)
        clearActivePhysicalHold(for: button)

        for pressIdentifier in interruptedPhysicalPressIdentifiers {
            enqueuePress(
                button,
                pressIdentifier: pressIdentifier,
                isPhysicallyHeld: true,
                emitsWhenReleased: false
            )
        }

        var commands: [InputPulseCommand<Input>] = [.send(button, .up)]
        commands += scheduleQueuedPressIfNeeded(for: button, now: now)
        return commands
    }

    private mutating func scheduleQueuedPressIfNeeded(
        for button: Input,
        now: UInt64
    ) -> [InputPulseCommand<Input>] {
        guard !pendingPressButtons.contains(button) else { return [] }

        var nextQueuedPress: QueuedPress?
        while let queuedPress = dequeuePress(for: button) {
            if queuedPress.isPhysicallyHeld || queuedPress.emitsWhenReleased {
                nextQueuedPress = queuedPress
                break
            }
        }

        guard let queuedPress = nextQueuedPress else { return [] }

        let delayNanoseconds = remainingInterTapDelay(for: button, now: now) ?? 0
        guard delayNanoseconds > 0 else {
            var commands = startPress(
                button,
                pressIdentifier: queuedPress.pressIdentifier,
                isPhysicallyHeld: queuedPress.isPhysicallyHeld,
                emitsWhenReleased: queuedPress.emitsWhenReleased,
                now: now
            )
            if !queuedPress.isPhysicallyHeld {
                commands += releaseButton(button, respectingMinimumDuration: true, now: now)
            }
            return commands
        }

        setPendingPress(
            button,
            pressIdentifier: queuedPress.pressIdentifier,
            isPhysicallyHeld: queuedPress.isPhysicallyHeld,
            emitsWhenReleased: queuedPress.emitsWhenReleased
        )
        return [.schedulePress(button, delayNanoseconds: delayNanoseconds)]
    }

    private func remainingInterTapDelay(for button: Input, now: UInt64) -> UInt64? {
        guard minimumInterTapGapNanoseconds > 0,
              shouldEnforceMinimumInterTapGap(button),
              let releasedAt = lastReleaseUptime[button]
        else { return nil }

        let elapsed = now >= releasedAt ? now - releasedAt : 0
        guard elapsed < minimumInterTapGapNanoseconds else { return nil }
        return minimumInterTapGapNanoseconds - elapsed
    }

    private mutating func setPendingPress(
        _ button: Input,
        pressIdentifier: UInt64?,
        isPhysicallyHeld: Bool,
        emitsWhenReleased: Bool
    ) {
        pendingPressButtons.insert(button)
        pendingPressEmitsWhenReleased[button] = emitsWhenReleased
        if isPhysicallyHeld {
            if let pressIdentifier {
                pendingPressPhysicalIdentifiers[button] = pressIdentifier
                pendingAnonymousPressPhysicalHoldButtons.remove(button)
            } else {
                pendingPressPhysicalIdentifiers[button] = nil
                pendingAnonymousPressPhysicalHoldButtons.insert(button)
            }
        } else {
            pendingPressPhysicalIdentifiers[button] = nil
            pendingAnonymousPressPhysicalHoldButtons.remove(button)
        }
    }

    private mutating func enqueuePress(
        _ button: Input,
        pressIdentifier: UInt64?,
        isPhysicallyHeld: Bool,
        emitsWhenReleased: Bool = true
    ) {
        queuedPresses[button, default: []].append(
            QueuedPress(
                pressIdentifier: pressIdentifier,
                isPhysicallyHeld: isPhysicallyHeld,
                emitsWhenReleased: emitsWhenReleased
            )
        )
    }

    private mutating func dequeuePress(for button: Input) -> QueuedPress? {
        guard var queue = queuedPresses[button], !queue.isEmpty else { return nil }
        let press = queue.removeFirst()
        queuedPresses[button] = queue.isEmpty ? nil : queue
        return press
    }

    private mutating func releasePhysicalHold(
        for button: Input,
        pressIdentifier: UInt64?
    ) -> PhysicalHoldRelease {
        if let pressIdentifier {
            if removeActivePhysicalHold(for: button, pressIdentifier: pressIdentifier) {
                return .active
            }

            if pendingPressPhysicalIdentifiers[button] == pressIdentifier {
                pendingPressPhysicalIdentifiers[button] = nil
                return .pending
            }

            return releaseQueuedPhysicalHold(for: button) { queuedPress in
                queuedPress.pressIdentifier == pressIdentifier
            }
        }

        if activeAnonymousPhysicalHoldButtons.remove(button) != nil {
            return .active
        }

        if pendingAnonymousPressPhysicalHoldButtons.remove(button) != nil {
            return .pending
        }

        return releaseQueuedPhysicalHold(for: button) { queuedPress in
            queuedPress.pressIdentifier == nil
        }
    }

    @discardableResult
    private mutating func releaseQueuedPhysicalHold(
        for button: Input,
        matching predicate: (QueuedPress) -> Bool
    ) -> PhysicalHoldRelease {
        guard var queue = queuedPresses[button],
              let heldIndex = queue.firstIndex(where: { $0.isPhysicallyHeld && predicate($0) })
        else {
            return .none
        }

        if queue[heldIndex].emitsWhenReleased {
            queue[heldIndex].isPhysicallyHeld = false
        } else {
            queue.remove(at: heldIndex)
        }
        queuedPresses[button] = queue
        return .queued
    }

    private mutating func markActivePhysicalHold(
        for button: Input,
        pressIdentifier: UInt64?
    ) {
        guard let pressIdentifier else {
            activeAnonymousPhysicalHoldButtons.insert(button)
            return
        }

        activePhysicalPressIdentifiers[button, default: []].insert(pressIdentifier)
        activeAnonymousPhysicalHoldButtons.remove(button)
    }

    @discardableResult
    private mutating func removeActivePhysicalHold(
        for button: Input,
        pressIdentifier: UInt64
    ) -> Bool {
        guard var identifiers = activePhysicalPressIdentifiers[button],
              identifiers.remove(pressIdentifier) != nil
        else {
            return false
        }

        activePhysicalPressIdentifiers[button] = identifiers.isEmpty ? nil : identifiers
        return true
    }

    private mutating func clearActivePhysicalHold(for button: Input) {
        activePhysicalPressIdentifiers[button] = nil
        activeAnonymousPhysicalHoldButtons.remove(button)
    }
}

typealias ButtonPulseSequencer = InputPulseSequencer<KeypadElementID>
