import Foundation
import CoreFoundation

struct PadState: Codable, Equatable {
    var desktop: DesktopState? = nil
    let buttons: Int
    let lx, ly, rx, ry, lt, rt: Double
    static let neutral = PadState(buttons: 0, lx: 0, ly: 0, rx: 0, ry: 0, lt: 0, rt: 0)
    var valid: Bool {
        (0..<32768).contains(buttons) && [lx, ly, rx, ry].allSatisfy { $0.isFinite && (-1...1).contains($0) } && [lt, rt].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
    var report: [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 20); bytes[1] = 20
        let bits = [12,13,14,15,8,9,5,4,6,7,0,1,2,3,10]
        var mask: UInt16 = 0
        for (i, bit) in bits.enumerated() where buttons & (1 << i) != 0 { mask |= 1 << bit }
        if mask & 3 == 3 { mask &= ~3 }
        if mask & 12 == 12 { mask &= ~12 }
        bytes[2] = UInt8(truncatingIfNeeded: mask); bytes[3] = UInt8(mask >> 8)
        bytes[4] = UInt8((lt * 255).rounded()); bytes[5] = UInt8((rt * 255).rounded())
        for (index, value) in [lx, ly, rx, ry].enumerated() {
            let raw = UInt16(bitPattern: Int16((value * (value < 0 ? 32768 : 32767)).rounded()))
            bytes[6 + index * 2] = UInt8(truncatingIfNeeded: raw); bytes[7 + index * 2] = UInt8(raw >> 8)
        }
        return bytes
    }
}

// The WebSocket envelope is already decoded. Validate its state directly instead
// of encoding it back to JSON and decoding the same seven numbers a second time.
extension PadState {
    static func parse(_ object: [String: Any]) -> PadState? {
        guard Set(object.keys).subtracting(["desktop"]) == Set(["buttons", "lx", "ly", "rx", "ry", "lt", "rt"]) else { return nil }
        func number(_ key: String) -> Double? {
            guard let value = object[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            return value.doubleValue
        }
        guard let buttons = number("buttons"), buttons.isFinite, (0..<32768).contains(buttons), buttons.rounded(.towardZero) == buttons,
              let lx = number("lx"), let ly = number("ly"), let rx = number("rx"), let ry = number("ry"),
              let lt = number("lt"), let rt = number("rt") else { return nil }
        var state = PadState(buttons: Int(buttons), lx: lx, ly: ly, rx: rx, ry: ry, lt: lt, rt: rt)
        if let value = object["desktop"] {
            guard let object = value as? [String: Any], let desktop = DesktopState.parse(object) else { return nil }; state.desktop = desktop
        }
        return state.valid ? state : nil
    }
}

struct DesktopState: Codable, Equatable {
    let keys: [String]
    let buttons: Int
    let x, y, scrollX, scrollY: Double
    var neutral: Bool { keys.isEmpty && buttons == 0 && x == 0 && y == 0 && scrollX == 0 && scrollY == 0 }
    func matches(_ profile: [String: Any]?) -> Bool {
        let mappings = profile?["mappings"] as? [[String: Any]] ?? []
        let outputs = Set(mappings.flatMap { $0["outputs"] as? [String] ?? [] })
        let mask = ["mouse:left", "mouse:right", "mouse:middle"].enumerated().reduce(0) { value, item in value | (outputs.contains(item.element) ? 1 << item.offset : 0) }
        return Set(keys).isSubset(of: outputs) && buttons & ~mask == 0 && (outputs.contains("pointer") || (x == 0 && y == 0 && scrollX == 0 && scrollY == 0))
    }
    static func parse(_ object: [String: Any]) -> DesktopState? {
        guard Set(object.keys) == Set(["keys", "buttons", "x", "y", "scrollX", "scrollY"]),
              let keys = object["keys"] as? [String], keys.count <= 128, Set(keys).count == keys.count,
              keys.allSatisfy({ CloudProfile.desktopDefinitions[$0] != nil }),
              let buttons = CloudProfile.number(object["buttons"], 0, 7), buttons.rounded() == buttons,
              let x = CloudProfile.number(object["x"], -1e9, 1e9), let y = CloudProfile.number(object["y"], -1e9, 1e9),
              let sx = CloudProfile.number(object["scrollX"], -1e9, 1e9), let sy = CloudProfile.number(object["scrollY"], -1e9, 1e9) else { return nil }
        return DesktopState(keys: keys, buttons: Int(buttons), x: x, y: y, scrollX: sx, scrollY: sy)
    }
}
extension PadState {
    var isNeutral: Bool { buttons == 0 && lx == 0 && ly == 0 && rx == 0 && ry == 0 && lt == 0 && rt == 0 && (desktop?.neutral ?? true) }
}
