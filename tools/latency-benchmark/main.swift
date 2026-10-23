import Foundation
let object: [String: Any] = ["buttons": 17, "lx": -0.7, "ly": 0.3, "rx": 0.2, "ry": -0.4, "lt": 0.5, "rt": 1]
let iterations = 20000
var checksum = 0
func measure(_ body: () throws -> PadState?) rethrows -> Double {
    let start = ProcessInfo.processInfo.systemUptime
    for _ in 0..<iterations { if let state = try body(), state.valid { checksum += state.buttons } }
    return (ProcessInfo.processInfo.systemUptime-start)*1_000_000/Double(iterations)
}
for round in 0..<5 {
    let old = try measure { try JSONDecoder().decode(PadState.self, from: JSONSerialization.data(withJSONObject: object)) }
    let direct = measure { PadState.parse(object) }
    print(String(format:"round=%d old_us=%.3f direct_us=%.3f speedup=%.2f", round, old, direct, old/direct))
}
print("checksum=\(checksum)")
