# Physical phone input-capture target

Build with `bash tools/physical-desktop-qa/build-macos.sh` from the repository root. This creates the separately named `build/Thumble Hardware QA.app` using the production receiver sources, except its generated Receiver copy redirects CoreGraphics output into a JSONL capture and exposes QA-only access diagnostics in the isolated receiver status file. The C gamepad implementation is the existing report-capture stub.

The build uses `THUMBLE_LOCAL_TESTING`; do not package or distribute it as a production receiver. It needs no keyboard Accessibility grant because it never posts captured events. It does not establish entitlement or gameplay correctness.

Launch with a fresh private directory and these environment variables:

```sh
TAPPING_PROFILE_DIR=/private/tmp/thumble-hardware-qa
TAPPING_TEST_INVITATION=/private/tmp/thumble-hardware-qa/invitation
THUMBLE_QA_EVENTS=/private/tmp/thumble-hardware-qa/events.jsonl
TAPPING_TEST_REPORTS=/private/tmp/thumble-hardware-qa/gamepad.txt
```

Create the directory with mode 0700 and export the variables before launching `build/Thumble Hardware QA.app/Contents/MacOS/hardware-qa`. Pair only the owner's chosen QA phone. The invitation and file secrets must remain private and must not be committed. Use the shared ProfileStore to activate the seeded `Physical phone QA` fixture; verify actual phone rendering, receiver revision acknowledgement, and captured events rather than trusting gesture-tool success.

The workspace window supports only the QA actions wired in `main.swift`; this harness is not evidence that every production connection/settings action works.
