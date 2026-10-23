# Recording-only phone presentation acceptance

`Rewrite/tooling/presentation-service-probe.ts` imports the public `RealServicePhoneProbe` class through its side-effect-free module entry. It reuses its isolated recording service, local identity, pinned TLS listener, saved activation and bounded hold watch. It does not copy unrelated live analog QA additions or start physical output, a game, a capture helper or an installed service.

The adapter seeds one centered South button from the production starter and removes bindings for omitted controls. Both base light/dark variants contain a bounded synthetic 32px RGBA PNG. The initial label is `Initial spell`, RGB24/64/168; the refreshed label is `Refreshed spell`, RGB144/64/48. IDs, output binding, geometry, input epochs and installed saved source remain fixed across the appearance-only CAS import. Presentation revisions and icon hashes advance independently.

The first stdout line is a **private synthetic invitation**, plus source/icon pins and the South ID. Do not publish it as a general service log. Subsequent single-byte commands return bounded JSON lines:

| Byte | Purpose                                                                                                                      |
| ---- | ---------------------------------------------------------------------------------------------------------------------------- |
| `a`  | Explicitly activate the synthetic saved profile in recording mode.                                                           |
| `z`  | Confirm fresh neutral after native input bind.                                                                               |
| `q`  | Start the byte-exact South hold watch.                                                                                       |
| `u`  | Import the changed appearance/label through normal CLI validation and CAS; assert the old active saved binding is unchanged. |
| `x`  | Reject a stale local configuration CAS.                                                                                      |
| `j`  | Verify the held report, at least 1500ms after the `q` acknowledgment, without neutral pulses and with unchanged 350ms TTL.   |
| `n`  | Confirm clean native input release after caller cancellation.                                                                |
| `c`  | Return public synthetic catalog pins.                                                                                        |
| `p`  | Explicitly open another synthetic enrollment window.                                                                         |
| `r`  | Revoke synthetic phone-b through the existing operator command.                                                              |
| `d`  | Return bounded synthetic active/epoch/release-reason diagnostics.                                                            |
| `f`  | Stop the owned service and remove its temporary directory.                                                                   |

A 60-second outer lifetime, bounded CLI/process waits, fixed sanitized failure phases and inherited public-probe cleanup limit an abandoned test. The adapter uses no production user endpoint, credentials or source data. Stdin EOF and signals clean up its owned runtime.

`PhonePresentationServiceTest` uses the actual Kotlin SDK against native TLS, the Bun service and sole configuration child in both UDP and forced TLS fallback modes. It fetches the original served map, holds South while reading metadata/icons and committing the appearance refresh, rejects the old icon request as `presentation_stale`, verifies the changed PNG and label under the original installed pin, and rejects a stale local CAS. The recording watch then proves continuity without input retirement. After clean release, it proves a revoked secondary phone cannot send a metadata query: only hello and credential proof leave that management client.

The existing local `pairing-revoke` operation deliberately releases all active input before revoking a credential. This witness preserves that policy and tests revocation **after** the independent held-input proof; it does not claim operator revocation is cosmetic.

After normal mobile fixture preparation and the default native recording build:

```sh
export THUMBLE_PRESENTATION_SERVICE_PROBE="$PWD/Rewrite/tooling/presentation-service-probe.ts"
# Put pinned Bun 1.4.3 on PATH for the adapter's shebang.
cd Rewrite/native/mobile-input/android
./gradlew --offline testDebugUnitTest --tests '*PhonePresentationServiceTest'
```

The pure Bun fixture test validates the one-control source, centered geometry, both themes, bounded PNGs and identical projected input maps before/after refresh. These SDK/service gates do not claim React image rendering, physical phone acceptance, live capture freshness, modifier banks or game compatibility. Native app and visible-image acceptance are separate gates.
