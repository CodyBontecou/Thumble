// Receiver-clock bounds, independent of the phone's wall clock.
// Physical iPhone holds encountered 150–190 ms input gaps and lease round trips.
// Separate the receive-silence limit from the two-leg authorization budget.
// Watchdog expiry releases HID and revokes every lease; a paused receiver still
// requires fresh neutral recovery, so an old held packet cannot re-arm it.
enum InputTiming {
    static let watchdogSeconds = 0.30
    static let leaseSeconds = 0.50
    static func shouldPause(now: Double, lastInput: Double) -> Bool {
        now - lastInput >= watchdogSeconds
    }
    static func leaseDeadline(issuedAt: Double) -> Double { issuedAt + leaseSeconds }
    static func leaseIsFresh(now: Double, deadline: Double) -> Bool { now <= deadline }
}
