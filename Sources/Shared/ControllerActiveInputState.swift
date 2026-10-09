import Foundation

public struct ControllerActiveInputPress: Equatable, Sendable {
    public var button: KeypadElementID
    public var pressIdentifier: UInt64?

    public init(button: KeypadElementID, pressIdentifier: UInt64?) {
        self.button = button
        self.pressIdentifier = pressIdentifier
    }
}

public struct ControllerActiveInputState: Equatable, Sendable {
    private var identifiedPressesByButton: [KeypadElementID: Set<UInt64>] = [:]
    private var anonymousPressCountsByButton: [KeypadElementID: Int] = [:]

    public init() {}

    public var activePresses: [ControllerActiveInputPress] {
        var presses: [ControllerActiveInputPress] = []

        let inputs = Set(identifiedPressesByButton.keys).union(anonymousPressCountsByButton.keys)
        for button in inputs.sorted(by: { $0.rawValue < $1.rawValue }) {
            for identifier in (identifiedPressesByButton[button] ?? []).sorted() {
                presses.append(.init(button: button, pressIdentifier: identifier))
            }

            let anonymousCount = anonymousPressCountsByButton[button] ?? 0
            for _ in 0..<anonymousCount {
                presses.append(.init(button: button, pressIdentifier: nil))
            }
        }

        return presses
    }

    public var isEmpty: Bool {
        identifiedPressesByButton.isEmpty && anonymousPressCountsByButton.isEmpty
    }

    public mutating func record(
        button: KeypadElementID,
        state: ButtonPressState,
        pressIdentifier: UInt64?
    ) {
        switch state {
        case .down:
            if let pressIdentifier {
                identifiedPressesByButton[button, default: []].insert(pressIdentifier)
            } else {
                anonymousPressCountsByButton[button, default: 0] += 1
            }

        case .up:
            if let pressIdentifier {
                guard var identifiers = identifiedPressesByButton[button] else { return }
                identifiers.remove(pressIdentifier)
                identifiedPressesByButton[button] = identifiers.isEmpty ? nil : identifiers
            } else {
                guard let count = anonymousPressCountsByButton[button],
                      count > 0
                else {
                    return
                }

                anonymousPressCountsByButton[button] = count == 1 ? nil : count - 1
            }
        }
    }

    public mutating func removeAll() {
        identifiedPressesByButton.removeAll()
        anonymousPressCountsByButton.removeAll()
    }
}
