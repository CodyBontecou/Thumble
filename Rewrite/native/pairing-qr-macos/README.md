# Native macOS pairing QR renderer

A standalone Swift package with no external dependencies. Generation uses Apple's [CIQRCodeGenerator](https://developer.apple.com/documentation/coreimage/ciqrcodegenerator), as the retained renderer did. The explicit four-module white quiet zone and integer eight-times nearest scaling produce a bounded PNG. Tests use [VNDetectBarcodesRequest](https://developer.apple.com/documentation/vision/vndetectbarcodesrequest) against generated images, with no camera access.

`thumble-pairing-qr-macos render` accepts at most 4096 ASCII bytes on stdin and writes at most 1 MiB of PNG on stdout. Input is the canonical, sorted-key JSON encoding of exactly the existing seven native invitation fields: authorityInstanceId, certificatePin, expiresAt, host, port, secret, windowId. Duplicate/unknown fields, noncanonical spellings, invalid host/port/hash/id values and excessive data fail closed. Input is never a URI or deep link. No profile, token, source document, device or network APIs are used. Failure emits one fixed error code; no argument or invitation data is logged.

```sh
swift test --package-path Rewrite/native/pairing-qr-macos
swift build -c release --package-path Rewrite/native/pairing-qr-macos
cd Rewrite
THUMBLE_REWRITE_PAIRING_QR_TEST=1 bun test tests/pairing-qr.test.ts
```

All native integration invitations use isolated test services. Vision witnesses read the exact expected payload from stdin, not command arguments, and print only a fixed verification result. No current user invitation is checked into source or retained in test logs. Tests do not pair a phone or create input devices.
