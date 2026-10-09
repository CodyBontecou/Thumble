import Foundation

#if !XCODEBUILD_TEST
@main
#endif
struct ControllerActiveInputStateSmokeTests {
    static func main() {
        testHeldMovementIsAvailableForHeartbeatResync()
        testHeldMovementCanBeReassertedAfterRemoteHeartbeatTimeout()
        testReleasingOneSameButtonTouchKeepsOtherTouchActive()
        testIdentifiedPressDoesNotClearAnonymousHold()
        testReleaseAllClearsHeldInputs()
        print("ControllerActiveInputState smoke tests passed")
    }

    private static func testHeldMovementIsAvailableForHeartbeatResync() {
        var state = ControllerActiveInputState()
        state.record(button: .preset(3), state: .down, pressIdentifier: 101)

        expectEqual(
            state.activePresses,
            [.init(button: .preset(3), pressIdentifier: 101)],
            "held left is retained for heartbeat re-sync"
        )

        state.record(button: .preset(3), state: .up, pressIdentifier: 101)
        expectEqual(state.activePresses, [], "left release clears heartbeat re-sync state")
    }

    private static func testHeldMovementCanBeReassertedAfterRemoteHeartbeatTimeout() {
        var state = ControllerActiveInputState()
        state.record(button: .preset(3), state: .down, pressIdentifier: 102)

        // Simulate the Mac releasing stale keys after a missed heartbeat. The
        // phone still has the user's finger down, so heartbeat recovery must have
        // enough state to send left down again without waiting for a re-tap.
        expectEqual(
            state.activePresses,
            [.init(button: .preset(3), pressIdentifier: 102)],
            "held left can be reasserted after remote heartbeat timeout"
        )
    }

    private static func testReleasingOneSameButtonTouchKeepsOtherTouchActive() {
        var state = ControllerActiveInputState()
        state.record(button: .preset(4), state: .down, pressIdentifier: 201)
        state.record(button: .preset(4), state: .down, pressIdentifier: 202)
        state.record(button: .preset(4), state: .up, pressIdentifier: 201)

        expectEqual(
            state.activePresses,
            [.init(button: .preset(4), pressIdentifier: 202)],
            "second right touch remains active after first touch releases"
        )
    }

    private static func testIdentifiedPressDoesNotClearAnonymousHold() {
        var state = ControllerActiveInputState()
        state.record(button: .preset(6), state: .down, pressIdentifier: nil)
        state.record(button: .preset(6), state: .down, pressIdentifier: 203)
        state.record(button: .preset(6), state: .up, pressIdentifier: 203)

        expectEqual(
            state.activePresses,
            [.init(button: .preset(6), pressIdentifier: nil)],
            "identified press release does not clear anonymous hold"
        )
    }

    private static func testReleaseAllClearsHeldInputs() {
        var state = ControllerActiveInputState()
        state.record(button: .preset(3), state: .down, pressIdentifier: 301)
        state.record(button: .preset(5), state: .down, pressIdentifier: 302)
        state.removeAll()

        expectEqual(state.activePresses, [], "release all clears heartbeat re-sync state")
        expect(state.isEmpty, "release all leaves state empty")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        guard condition else {
            fputs("ControllerActiveInputStateSmokeTests failed: \(message)\n", stderr)
            exit(1)
        }
    }

    private static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        guard actual == expected else {
            fputs("ControllerActiveInputStateSmokeTests failed: \(message). Expected \(expected), got \(actual)\n", stderr)
            exit(1)
        }
    }
}
