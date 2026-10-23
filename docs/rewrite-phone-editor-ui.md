# Phone label editor

Home → Edit labels opens an independent editor. Opening the editor, choosing a cached profile, loading its controls, and queueing an edit use the native journal without a network request. Refresh profiles explicitly reads the current catalog. The UI retains the native context ID, displayed revision, source hash, control ID, and operation ID for each draft; retry never substitutes a newer base.

Controls load in native pages of at most eight and render in a virtualized FlatList. A label has three distinct modes: custom text, a deliberately blank string confirmed with a native alert, and the generated label represented by null. Cancel/back protects an unsaved draft; queueing reports success only after the durable native snapshot contains that exact edit.

Changes on this phone is a separate queue. Ready changes can be sent explicitly. Uncertain, conflicting, and rejected changes can only be checked with their original operation. Only an exact committed result displays “Saved on your Mac”; the editor then refreshes the current catalog and profile cache. An older origin remains in the queue with plain recovery instructions. The UI never silently moves an edit to the current profile or recreates it with new pins.

The editor follows the existing Expo Router native stack, semantic colors, native buttons, text input, alerts, safe areas, and automatic font scaling. It adds no controller skin, art, navigation dependency, or custom transition. The queue uses an opaque native navigation header so scrolling feedback to the top cannot place it behind a translucent header. New drafts hide notices belonging to an earlier edit. The root router uses the current `anchor` setting in place of its deprecated `initialRouteName` alias.

## Design study and evidence

The Appllama design skill was applied. Appllama tools were unavailable, so no competitor screen collection or benchmark comparison is claimed. Research used the retained/current Thumble Home, controller navigation and Android layout editor, together with Apple's [text-field guidance](https://developer.apple.com/design/human-interface-guidelines/text-fields). The editor preserves their native control and navigation conventions.

Actual iOS 26.5 Simulator evidence was captured on the dedicated Thumble Rewrite QA simulator. The normal production entry exercised Home → unpaired editor, native app background/resume, process restart, JavaScript reload, and reopening. This is limited unpaired evidence; it does not prove a paired native journal owner is reclaimed on JavaScript runtime destruction. The separate [native module lifecycle gate](rewrite-editor-module-lifecycle.md) covers actual SDK ownership and canceled creation through the production registries. Same-process paired JavaScript reload acceptance remains separate.

A separate test-only entry, `apps/mobile/tests/editor-ui/preview-entry.tsx`, renders the actual product routes with an injected synthetic model. Its fixture contains cached controls and queued, uncertain, conflict, and older-origin changes. It never supplies a native endpoint or credential. Simulator checks covered native text entry, queued feedback, blank confirmation/queueing, generated reset, exact committed feedback and refreshed cache, and older-origin recovery. Light and dark appearances and the largest regular Dynamic Type setting were inspected. Background/resume preserved the synthetic queue screen. This iOS synthetic run does not establish a paired host, physical phone, release performance, landscape, accessibility-size font settings, or 60 fps performance acceptance. Android emulator evidence is recorded separately below.

Final reusable iOS flows passed uninterrupted: production entry 6/6, custom label 23/23, and send → uncertain → exact reconcile 10/10. Custom-label and product lifecycle motion were captured in untrimmed videos. One raw typed-value wait remains because the live accessibility tree includes the input value while the flow runner's selector tree omits it. Earlier failed/empty authoring flows are historical evidence and are not accepted runs. A prior router deprecation warning appears in older captures; the final source uses `anchor`.

Evidence remains in the durable `build/editor-ui-evidence` artifact, separate from source. Simulator video is visual behavior evidence, not a release timing measurement. The simulator's software keyboard appearance was not independently established; native input focus and typed values were verified.

## Reproduce

The default package entry remains `expo-router/entry`. Build the app normally and start the existing Expo Metro server. For synthetic UI QA only, temporarily set the app package `main` to `tests/editor-ui/preview-entry.tsx`, restart the selected simulator/emulator app, and restore the original package immediately afterward. No production route uses the synthetic entry.

The fixture resets on process restart to revision 7 with eighteen controls. Send `qa-queued` to make its status uncertain; check it to commit revision 8 and refresh the cache. Other original edits at revision 7 then conflict instead of rebasing. Checking `qa-origin` retains it and shows recovery instructions. The synthetic fixture is not evidence of native durability, transport security, or a real committed host write; those have separate SDK/native integration gates.

Run `bun test tests/native-editor-ui.test.ts tests/native-controller-component.test.ts` from Rewrite. The editor wrapper isolates model and actual label-screen renderer tests so native mocks do not leak into other tests. Also run mobile TypeScript checks and an Expo export for both platforms. Actual Expo native module compilation and SDK/stack-safety gates remain separate from this React-only change.

## Android emulator evidence

Android emulator validation also passed on the owned API35 AVD: unpaired Home/editor recovery, cached18-control paging, custom text with the native keyboard, hardware Back draft protection, deliberately blank/generated-label queueing, exact-commit feedback/refresh, uncertain/conflict and origin-recovery states. Dark mode and font scale1.5 kept row actions and modal controls readable. The product entry, font scale and night setting were restored; physical devices were untouched. This UI fixture uses an in-memory adapter, so its queue behavior is not evidence of disk persistence or paired native-factory execution. Native journal/provider and actual-service SDK evidence are separate.
