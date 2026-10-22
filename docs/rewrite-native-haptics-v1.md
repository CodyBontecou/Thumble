# Native touch feedback contract

The rewrite's optional `ControlRegion.hapticFeedback` metadata configures local phone feedback for accepted native touches. TypeScript, Swift and Kotlin retain the same metadata bounds and logical fallback schedules. Haptics run in native input surfaces independently of React rendering. Input reports, authenticated input packets, sequence numbers, generation/lease rules and receiver authority are unchanged; this metadata is neither remote rumble nor an input activation capability.

This contract describes the frozen twenty-file native haptics snapshot, including its TypeScript validator/generated schema, native policies and players, native touch surfaces, bridge admission/comparison, local preferences and tests. It does not include the separate phone catalog integration or Android SDK repair.

## Metadata and native renderer parity

The metadata is optional. An absent value uses the native default: `style:"light"`, `pattern:"single"`, `intensity:0.45`, `sharpness:0.48`, `duration:0.06`. A present value must contain exactly all five fields; partial objects, null, unknown fields, invalid enums, booleans in numeric fields and nonfinite/out-of-range numbers are rejected.

| Field       | Accepted values                                     |
| ----------- | --------------------------------------------------- |
| `style`     | `none`, `light`, `medium`, `heavy`, `soft`, `rigid` |
| `pattern`   | `single`, `double`, `pulse`, `buzz`                 |
| `intensity` | Finite number from 0 through 1                      |
| `sharpness` | Finite number from 0 through 1                      |
| `duration`  | Finite seconds from 0.02 through 0.30               |

`style:"none"` normalizes to `pattern:"single"`, `intensity:0`, `sharpness:0`, preserving duration. It produces no feedback. Native bridge map comparisons normalize absent/default feedback and the `none` form, so equivalent metadata does not spuriously replace an admitted map. Actual feedback changes remain part of native map comparison and normal configuration admission. Generated JSON Schema describes field admission; the TypeScript/native decoders perform normalization.

Native convenience constructors supply the following per-style defaults when intensity or sharpness is omitted by native code. Serialized metadata still requires both fields explicitly.

| Style    | Default intensity | Default sharpness |
| -------- | ----------------- | ----------------- |
| `none`   | 0                 | 0                 |
| `light`  | 0.45              | 0.48              |
| `medium` | 0.62              | 0.56              |
| `heavy`  | 0.82              | 0.66              |
| `soft`   | 0.38              | 0.24              |
| `rigid`  | 0.70              | 0.92              |

## Accepted touches and bounded schedules

A native surface requests feedback only after its input engine accepts a touch begin, and only while connected or in practice mode. It uses the same reverse-order control-region hit test as native input. Rejected, stale or duplicate touches cannot request feedback through this path. Touch movement and per-sample reports do not trigger additional pulses. Practice feedback remains local with host output disabled.

The Swift main-actor policy and Kotlin UI-thread policy reject nonfinite/negative/above-safe-integer times and backward clock samples. A forward time high-water mark also advances for suppressed attempts. Feedback starts are at least 50 milliseconds apart per player policy. Disabled feedback, zero effective intensity, invalid metadata and `none` schedule no pulses. Effective intensity is metadata intensity multiplied by a finite local preference scale from 0 through 1.

| Pattern           | Logical fallback schedule                                                                                                                  |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| `single`, `pulse` | One immediate impact at effective intensity                                                                                                |
| `double`          | Immediate impact, then an impact at 85% intensity after duration clamped to 45–180 milliseconds                                            |
| `buzz`            | 2–6 impacts, count `ceil(max(duration,0.08)/0.045)` clamped to that range, spaced 45 milliseconds apart; alternating 92% and 68% intensity |

At most six impacts are scheduled, with the last buzz impact at most 225 milliseconds after acceptance. A newly accepted schedule cancels the previous pending schedule. Touch end cancels remaining impacts owned by that touch. Cancellation, backgrounding, screen lock, rotation, profile replacement, disconnect, disposal and leaving the native surface clear pending feedback alongside normal input release. Delayed impacts recheck active state and opt-out; disconnected inactive surfaces cannot keep playing a queued pattern.

## Local preferences and platform behavior

The native connection prompt exposes a touch-feedback toggle on both phones. This preference is local and does not modify saved host configuration or credentials. Turning it off suppresses future and delayed impacts. The iOS preference retains the existing intensity key and legacy enabled-setting fallback; Android stores a private local intensity value. Invalid preference values fail closed or clamp to 0–1. The toggle restores scale 1 when enabled and scale 0 when disabled.

On iOS, `UIImpactFeedbackGenerator` supplies the style and effective intensity under system hardware/OS policy. On Android, `View.performHapticFeedback` respects view and global system settings without ignore-setting flags. Android approximates styles with `CLOCK_TICK` for light/soft, `KEYBOARD_TAP` for medium/rigid and `LONG_PRESS` for heavy. Its fallback cannot reproduce arbitrary numeric strength or sharpness; numeric strength controls policy admission and logical schedules, while the selected system effect controls the physical impact. iOS also uses fallback impacts rather than Core Haptics continuous/sharpness synthesis. Duration influences fallback scheduling, and `pulse` becomes one impact. Neither platform promises exact waveform, strength, sharpness or continuous-duration parity.

## Evidence and remaining acceptance

Synthetic TypeScript/native tests cover metadata admission, normalization/default equivalence, bounded schedules, rate/rollback rejection, opt-out, accepted-touch dispatch, cancellation and bridge behavior. The isolated public source projection passes generated/schema checks, all TypeScript configurations and 226 tests with 4,011 assertions; its standalone package test is separately gated and skipped in this source verifier. Native Swift, UIKit and Android synthetic evidence is recorded separately by the rewrite review process. These checks establish source behavior, not tactile quality or physical gameplay acceptance.

Physical iPhone/Android feedback, accessibility/system-setting interactions, hardware approximations, comfort and gameplay under load remain acceptance work. No haptic or gameplay launch gate is marked complete by this contract.
