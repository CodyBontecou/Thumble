import ApplicationServices
import Foundation

// Confined to Receiver.queue, including release on the independent input timer.
final class DesktopInput {
    private let post: (CGEvent) -> Void
    private let trusted: () -> Bool
    init(post: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }, trusted: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.post = post; self.trusted = trusted
    }
    private var keys = Set<String>(), buttons = 0
    private var capsLock = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
    private var position = [Double](repeating: 0, count: 4)
    private let modifiers: [String: CGEventFlags] = ["ControlLeft": .maskControl, "ControlRight": .maskControl, "ShiftLeft": .maskShift, "ShiftRight": .maskShift, "AltLeft": .maskAlternate, "AltRight": .maskAlternate, "MetaLeft": .maskCommand, "MetaRight": .maskCommand]
    enum Failure: LocalizedError {
        case permission, event, motion
        var errorDescription: String? {
            switch self {
            case .permission: return "Allow Thumble Receiver in System Settings → Privacy & Security → Accessibility for keyboard and mouse controls."
            case .event: return "macOS could not create keyboard or mouse input. Controls released."
            case .motion: return "Pointer jump exceeds the input bound. Controls released."
            }
        }
    }
    private func isModifier(_ key: String) -> Bool { modifiers[String(key.dropFirst(4))] != nil }
    private func flagsForKeys(_ keys: Set<String>) -> CGEventFlags {
        keys.reduce(into: capsLock ? CGEventFlags.maskAlphaShift : CGEventFlags()) { flags, key in
            if let flag = modifiers[String(key.dropFirst(4))] { flags.insert(flag) }
        }
    }
    func write(_ state: DesktopState?) throws {
        if state != nil && !trusted() { throw Failure.permission }
        let next = Set(state?.keys ?? [])
        for down in [false, true] {
            let changed = down ? next.subtracting(keys) : keys.subtracting(next)
            for key in changed.sorted(by: { isModifier($0) == isModifier($1) ? $0 < $1 : (down ? isModifier($0) : !isModifier($0)) }) {
                guard let code = CloudProfile.desktopDefinitions[key]?["mac"] as? Int,
                      let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down) else { throw Failure.event }
                if down { keys.insert(key) } else { keys.remove(key) }
                if down && key == "key:CapsLock" { capsLock.toggle() }
                event.flags = flagsForKeys(keys); post(event)
            }
        }
        let flags = flagsForKeys(keys)
        let location = CGEvent(source: nil)?.location ?? .zero
        let nextButtons = state?.buttons ?? 0
        let kinds: [(CGEventType, CGEventType, CGMouseButton)] = [(.leftMouseDown,.leftMouseUp,.left),(.rightMouseDown,.rightMouseUp,.right),(.otherMouseDown,.otherMouseUp,.center)]
        for index in 0..<3 where (buttons & (1 << index) != 0) != (nextButtons & (1 << index) != 0) {
            let (pressed,released,button) = kinds[index]
            guard let event = CGEvent(mouseEventSource: nil, mouseType: nextButtons & (1 << index) != 0 ? pressed : released, mouseCursorPosition: location, mouseButton: button) else { throw Failure.event }
            buttons = nextButtons & (1 << index) != 0 ? buttons | (1 << index) : buttons & ~(1 << index)
            event.flags = flags; post(event)
        }
        let coordinates = [state?.x ?? 0,state?.y ?? 0,state?.scrollX ?? 0,state?.scrollY ?? 0].map { $0.rounded() }
        if state != nil {
            let delta = zip(coordinates,position).map(-)
            guard delta.allSatisfy({ abs($0) <= 10000 }) else { throw Failure.motion }
            if delta[0] != 0 || delta[1] != 0 {
                let kind: CGEventType = buttons & 1 != 0 ? .leftMouseDragged : buttons & 2 != 0 ? .rightMouseDragged : buttons & 4 != 0 ? .otherMouseDragged : .mouseMoved
                guard let event = CGEvent(mouseEventSource: nil, mouseType: kind, mouseCursorPosition: CGPoint(x: location.x + delta[0], y: location.y + delta[1]), mouseButton: buttons & 2 != 0 ? .right : buttons & 4 != 0 ? .center : .left) else { throw Failure.event }
                event.flags = flags; post(event)
            }
            if delta[2] != 0 || delta[3] != 0 {
                guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: Int32(-delta[3]), wheel2: Int32(delta[2]), wheel3: 0) else { throw Failure.event }
                event.flags = flags; post(event)
            }
        }
        position = coordinates
    }
}
