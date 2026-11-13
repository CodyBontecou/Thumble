import Foundation
import ApplicationServices
func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
var events = [CGEvent]()
let output = DesktopInput(post: { events.append($0) }, trusted: { true })
let held = DesktopState(keys: ["key:KeyA", "key:ControlLeft"], buttons: 1, x: 12, y: 8, scrollX: 0, scrollY: 2)
try output.write(held)
let count = events.count
try output.write(held)
check(events.count == count, "A heartbeat repeated keyboard/pointer events")
check(events[0].type == .flagsChanged && events[0].getIntegerValueField(.keyboardEventKeycode) == 59, "Modifier must press first")
check(events[1].type == .keyDown && events[1].getIntegerValueField(.keyboardEventKeycode) == 0 && events[1].flags.contains(.maskControl), "Chord must carry Ctrl")
check(events.contains { $0.type == .leftMouseDragged }, "Held left button must drag")
check(events.contains { $0.type == .scrollWheel }, "Trackpad scroll must reach CGEvent")
try output.write(nil)
check(events.suffix(3).map(\.type) == [.keyUp, .flagsChanged, .leftMouseUp], "Release must clear keys and mouse")
check(events[count].getIntegerValueField(.keyboardEventKeycode) == 0, "Ordinary key must release before modifier")
let after = events.count
try output.write(nil)
check(events.count == after, "Neutral release must be idempotent")
let blocked = DesktopInput(post: { _ in fatalError("Input bypassed permission") }, trusted: { false })
do { try blocked.write(held); fatalError("Missing Accessibility permission was accepted") } catch {}
// Missing Accessibility blocks only keyboard and mouse; the receiver keeps the gamepad running.
var allowed = false
var granted = [CGEvent]()
let waiting = DesktopInput(post: { granted.append($0) }, trusted: { allowed })
check(try waiting.deliver(held) && waiting.blocked && granted.isEmpty, "Missing Accessibility must block keys without failing the report")
check(try !waiting.deliver(held) && waiting.blocked, "A blocked heartbeat must not report a new change")
check(try !waiting.deliver(nil) && waiting.blocked && granted.isEmpty, "A neutral release must not clear the blocked state")
allowed = true
check(try waiting.deliver(held) && !waiting.blocked && granted.contains { $0.type == .keyDown }, "Granting access must press held keys and clear the block")
allowed = false
check(try waiting.deliver(held) && waiting.blocked, "Revoked access must block again")
waiting.forgetAccess()
check(!waiting.blocked, "A new session or layout must not inherit the blocked state")
check(CloudProfile.desktopDefinitions.count > 75, "Bundled key registry missing")
check(DesktopState.parse(["keys": ["key:ShellCommand"], "buttons": 0, "x": 0, "y": 0, "scrollX": 0, "scrollY": 0]) == nil, "Unsupported key accepted")
print("PASS native Mac keyboard chord, pointer drag, scroll, heartbeat, release and permission events")
