import Foundation
func state(_ buttons: Int = 0, lx: Double = 0, ly: Double = 0, rx: Double = 0, ry: Double = 0, lt: Double = 0, rt: Double = 0) -> PadState { PadState(buttons: buttons, lx: lx, ly: ly, rx: rx, ry: ry, lt: lt, rt: rt) }
precondition(PadState.neutral.report == [0,20] + Array(repeating: 0, count: 18))
let bits = [12,13,14,15,8,9,5,4,6,7,0,1,2,3,10]
for (index, bit) in bits.enumerated() {
    let report = state(1 << index).report
    precondition(Int(report[2]) | Int(report[3]) << 8 == 1 << bit)
}
let full = state(lx:-1,ly:1,rx:1,ry:-1,lt:1,rt:0.5).report
precondition(Array(full[4..<14]) == [255,128,0,128,255,127,255,127,0,128])
precondition(state((1<<10)|(1<<11)|(1<<12)|(1<<13)).report[2] == 0)
precondition(!state(lx:Double.nan).valid && !state(32768).valid && !state(rt:1.1).valid)
print("PASS Xbox report: all 15 buttons, signed axis endpoints, positive-up Y, triggers, opposing d-pad, invalid state")

let validObject: [String: Any] = ["buttons": 32767, "lx": -1.0, "ly": 1.0, "rx": 0.25, "ry": -0.75, "lt": 0.5, "rt": 1.0]
let expected = try JSONDecoder().decode(PadState.self, from: JSONSerialization.data(withJSONObject: validObject))
precondition(PadState.parse(validObject) == expected)
for key in validObject.keys {
    for invalid: Any in [true, false, "1", NSNull(), Double.nan, Double.infinity] {
        var candidate = validObject; candidate[key] = invalid
        precondition(PadState.parse(candidate) == nil, "Accepted invalid \(key)")
    }
    var missing = validObject; missing.removeValue(forKey: key); precondition(PadState.parse(missing) == nil)
}
for invalid in [-1.0, 32768.0, 1.5, 1e30] {
    var candidate = validObject; candidate["buttons"] = invalid; precondition(PadState.parse(candidate) == nil)
}
var extra = validObject; extra["extra"] = 0; precondition(PadState.parse(extra) == nil)
for index in 0..<1000 {
    let state = PadState(buttons: index % 32768, lx: Double(index % 201)/100-1, ly: -0.5, rx: 0.25, ry: 0, lt: Double(index % 101)/100, rt: 1)
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
    let reference = try JSONDecoder().decode(PadState.self, from: JSONSerialization.data(withJSONObject: object))
    guard let parsed = PadState.parse(object) else { fatalError("Valid state rejected") }
    precondition(parsed.buttons == reference.buttons)
    // Foundation's direct NSNumber conversion and the old second JSON text pass
    // can differ below 1e-15. Require numeric agreement and identical HID bytes.
    for (actual, expected) in zip([parsed.lx, parsed.ly, parsed.rx, parsed.ry, parsed.lt, parsed.rt], [reference.lx, reference.ly, reference.rx, reference.ry, reference.lt, reference.rt]) {
        precondition(abs(actual - expected) < 1e-12)
    }
    precondition(parsed.report == reference.report)
    precondition(PadState.parse(object)?.report == state.report)
}
print("PASS direct JSON state parser: strict numeric types, exact fields, ranges, 1000 codec-equivalent states")

// Physical iPhone trace: 30 ms typical arrivals with occasional 150–190 ms
// scheduling/radio gaps. A continuous held touch must survive those short gaps.
var lastInput = 10.0
var lease = InputTiming.leaseDeadline(issuedAt: 10.0)
for gap in [0.033, 0.19, 0.033, 0.17, 0.033, 0.033, 0.188] {
    let arrival = lastInput + gap
    precondition(!InputTiming.shouldPause(now: arrival, lastInput: lastInput), "short Wi-Fi gap cancelled a held control")
    precondition(InputTiming.leaseIsFresh(now: arrival, deadline: lease), "return/forward transit consumed the lease")
    lastInput = arrival
    lease = InputTiming.leaseDeadline(issuedAt: arrival)
}
precondition(InputTiming.shouldPause(now: lastInput + 0.301, lastInput: lastInput), "lost traffic must still release input")
precondition(!InputTiming.leaseIsFresh(now: lastInput + 0.501, deadline: lease), "expired packets must remain invalid")
print("PASS held-input jitter: 190 ms gaps survive; 301 ms silence releases; 501 ms lease is stale")
