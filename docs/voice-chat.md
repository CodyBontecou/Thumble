# Voice chat messages

Tap **Chat** while playing to start dictation directly on the controller. Tap the same button again to stop. Movement and action controls stay on screen and continue receiving touches while you dictate; live captions do not capture touches. After recognition finishes, a compact transcript panel offers editing, channel selection, **Send**, and **Cancel**. There is no separate chat screen. Profiles without a Chat control get a small Chat button in the controller's top center.

WoW must be the foreground Mac app when you tap Send. The receiver needs Accessibility permission to type into WoW. Its acknowledgement means keyboard input was handed to the game; it cannot confirm that the WoW server accepted a message.

Chat is a local app action: its controller mapping no longer opens the game's edit box. Other gamepad controls retain their mappings. Starting dictation leaves held controls active, so a player can keep moving. Backgrounding, loss of focus or connection recovery still releases gameplay controls. Typed entry works without speech permissions. In practice mode, dictation works but Send is disabled. The composer uses the phone's current locale; availability depends on the speech provider and installed language assets.

## Native recognition

- **iOS 26 and later:** check `SpeechTranscriber.isAvailable` and resolve a supported locale, then use `SpeechAnalyzer` with progressive results. Download system language assets when needed. No Apple Intelligence subscription or Foundation Models text-generation step is involved.
- **Older iOS / unavailable hardware or language / model preparation failure:** use `SFSpeechRecognizer`, requiring on-device processing when supported. Existing minimum iOS version remains 16.4.
- **Android:** first check ML Kit's advanced on-device recognition model, download it when available, and stream microphone results. Unsupported devices fall back to `android.speech.SpeechRecognizer`, preferring its dedicated on-device recognizer on API 31+. The ML Kit library requires Android 8 / API 26, which is now the app minimum. The pinned library is `com.google.mlkit:genai-speech-recognition:1.0.0-alpha1`; Google's advanced API is alpha and requires testing on supported hardware.
- **Online fallback:** disabled initially. The explicit switch permits Apple or the Android system speech provider to process audio online if local recognition cannot handle the device or language. Android's dedicated on-device provider can still report missing language assets; the UI suggests downloading the language or enabling online recognition.

The app saves no microphone recordings. System speech models may be downloaded to system-managed storage. Partial text is editable after dictation ends. Each recording has a distinct session ID; late results cannot overwrite a later recording. Backgrounding, audio interruptions, cancellation, or disconnecting release the microphone. Sessions stop after 55 seconds, with a bounded wait for final text.

## Delivery protocol

The receiver advertises `chat: 1` in its authenticated `ready` response. Older receivers keep Send disabled. Confirmed text travels over the paired TLS WebSocket, including when gameplay uses UDP. Each request contains `type: "chat"`, a unique `id`, `text`, `channel`, the current profile `revision`, and a short-lived receiver `lease`. Replies use `type: "chat-result"`, the same `id`, and an optional `error`.

Only a single message may be in flight. The receiver remembers IDs for the pairing (up to 1,000), checks input freshness, releases the gamepad, verifies the foreground app against WoW bundle IDs, and posts keyboard events to that process. It opens a fresh chat edit box and prefixes the chosen channel itself. Transcript text cannot choose a slash command. Newlines and control characters are rejected. The 240-byte UTF-8 limit leaves room for the game's channel prefix, including non-ASCII messages. Neither side retries an uncertain delivery automatically. A disconnect cancels a pending delivery before its final Enter when possible; check the game before retrying any uncertain delivery.

## Build and verification

A new native mobile build and receiver build are required; an OTA JavaScript update alone cannot add this module. Microphone usage descriptions, Android RECORD_AUDIO permission and speech service visibility are configured through Expo app config and plugins. The module also declares its Android permission and query.

Run:

```sh
npm run typecheck --workspace @tapping/mobile
npm run lint --workspace @tapping/mobile
npm test
npm run test:chat  # macOS Swift validation
```

Native checks: build both mobile apps, exercise permission denial and grant, background cancellation, unsupported language/device, missing model download, offline operation, and transcript editing. Physical speech accuracy must be tested on a recent iPhone, an older iPhone and a supported Android phone. Simulator availability is not evidence of production speech availability. Test actual WoW input, each channel, rapid focus changes and Accessibility permission on the Mac without posting to real players during automated tests.

References: [Apple Speech framework](https://developer.apple.com/documentation/speech/), [SpeechAnalyzer introduction](https://developer.apple.com/videos/play/wwdc2025/277/), [Apple runtime availability guidance](https://developer.apple.com/forums/thread/802863), [Google ML Kit speech guide](https://developers.google.com/ml-kit/genai/speech-recognition/android), [Android SpeechRecognizer](https://developer.android.com/reference/android/speech/SpeechRecognizer).

### Implementation verification (2026-10-23)

- iOS simulator Debug app build and Android arm64 Debug APK build passed. The macOS receiver compiled and linked successfully.
- Mobile lint/typecheck, the Node test suite, and native chat validation passed.
- Initial full-screen prototype (replaced by the inline controller workflow): iOS simulator opened composer, granted microphone permission, denied speech permission, verified actionable error and typed fallback, changed channel, and returned to the controller. A local recording is saved under `.argent/recordings/` (ignored by Git). Added a modal-local safe area provider after inspecting the landscape layout.
- Android API 35 emulator: opened composer, observed `Listening · Android on-device dictation`, observed the no-speech error, and entered an editable typed message. No message was sent to other players. The automation backend had stale landscape tap coordinates; fallback adb taps used observed accessibility frames and the measured display dimensions.
- Physical end-to-end dictation and WoW delivery passed on the iPhone 17 Pro and Pixel 7 (see live verification below). The exact native recognition engine used on each phone, older-iPhone fallback, and additional WoW channels still need separate verification. Permission dialogs retain pairing; backgrounding still disconnects and releases controls.

### Controller integration

The Chat control now invokes dictation without routing or releasing the player’s held touches. A touch-ID set consumes duplicate responder callbacks for Chat while forwarding all other fingers to the existing touch controller. Captions use `pointerEvents="none"`; only the post-dictation review panel captures touches in its own bounds. The separate `/chat` route and menu entry were removed.

The revised standalone Release builds were installed on Cody's iPhone 17 Pro and Pixel 7 for live testing, and the signed Mac receiver was rebuilt and restarted. The receiver accepts one phone at a time.

### Live verification (2026-10-23)

- Cody confirmed that controller-integrated dictation, transcript review, and Send delivered a message to WoW on both the Pixel 7 and iPhone 17 Pro.
- The iPhone initially transcribed “pull” as “poll?”; the transcript was editable before sending. Speech accuracy is not guaranteed.
- Send was disabled after the iPhone disconnected from the Mac. Re-pairing and completing the flow while Tapping stayed in the foreground succeeded. Re-pairing cleared the earlier draft, so the successful retry used a new dictation.
