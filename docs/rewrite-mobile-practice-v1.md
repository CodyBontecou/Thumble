# Native mobile practice application v1

This M3 slice composes the portable standard controller with a bundled Expo/React
Native iOS/Android app and local native input modules. It is local practice only:
there is no host session, saved credential or physical output admission.

The renderer shares the exact 19-region map used by native conformance fixtures.
Swift/Kotlin owns touch identities, control arbitration, continuous sampling,
feedback and cancellation. React owns labels and navigation. The bounded
configuration/inspection methods remain available for later transport integration;
there is no JavaScript per-touch/per-frame input method or event.

## Touch ownership

A native view below a React root still participates in React Native's root touch
and pointer dispatch. An Android instrumentation witness reproduced that ancestry
before this change. Capture now uses individual Activity-child regions on Android and a UIWindow
sibling on iOS. Android forwards those separate pointer streams into one native
engine in a touch-ignoring ViewGroupOverlay. A full-screen Android sibling swallowed
a second finger's Done tap while another control was held; the per-region routing
fixes that case without sending controller streams through React. The React child is a presentation/geometry anchor.

Native code follows the anchor's visible rectangle and detaches/releases when it
leaves the window. Initial touches outside controller regions pass through to
navigation. Existing native streams are cancelled on rotation, hiding,
background/focus loss, cancellation and disposal; reopening remains neutral.
UIKit also suspends the sibling while another presented controller owns the
window. These are application-window children, with no global overlay permission.

Practice admission uses an immutable prop and one native acknowledgement after
props update, avoiding an observed Fabric imperative view-tag mount race. Receipt
metadata is nested under `admission`, separate from framework-added `target` and
`timeStamp`. The portable decoder rejects unexpected fields, connected output,
non-practice receipts and invalid/full-width generation counters. No packet keys,
credential bearers or per-frame feedback cross this boundary.

## Headless validation

Android instrumentation uses a separate `.qa` variant with bundled Release
JavaScript and native dependencies. Production Release retains shrinking; QA does
not shrink the test-visible classes. Seven required cases inject actual system
MotionEvents into all 19 regions, hold six fingers while the actual React Native
JS queue is blocked, cancel natively before JS resumes, require native frame feedback to progress, release on
background/sleep, wake and rotate/reopen neutral, verify absence of React-root
ancestry for every capture region, and tap Done with a second finger while another
control stays held. Real injected stick comparisons allow one signed 16-bit
quantization unit after Float screen-coordinate conversion. Buttons/triggers and
full neutralization remain exact; canonical protocol vectors retain exact equality.
Setup wakes its synthetic emulator and captures primary
failures before teardown. CI builds APKs before booting the emulator. A checker rejects missing, failed or skipped witnesses.

iOS hosted tests run inside the bundled app, attach the actual native view beneath
its React root, verify all 19 UIKit hit-test destinations, navigation pass-through,
and release/removal of hidden or detached anchors. A saved flow also checks Home,
portrait guidance, native landscape admission, rotation back and Done. The hosted
tests do not claim six-finger system injection or JS-stall acceptance on iOS.

A reproduced Xcode dependency-scanner stall required disabling explicit Swift
module scanning for the generated QA target only. Swift 6 checks and product
compiler settings remain intact. Build-only success, zero cases and skipped cases
are not accepted as runtime evidence.

See `Rewrite/apps/mobile/README.md` for reproducible commands and the app CI
workflow for headless runner settings. Existing Windows/macOS/Linux receiver and
native SDK/provider workflows remain independent of these app witnesses.

## Open gates

This app does not yet pair/bind native transports, renew authorization/grants,
edit saved documents, provide production haptics/artwork or implement WoW/optical
presentation. It does not replace desktop functionality. Device latency, visual
and accessibility/phone-size coverage, signing and clean installation, the
physical output and gameplay acceptance remain open. Retained stack-safety
verification remains mandatory for subsequent shared-model/startup changes.
