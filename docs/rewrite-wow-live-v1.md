# Portable WoW optical observation core

`@thumble/domain/wow-live` implements the retained THWL-v1 page protocol and strict saved observation schema without capture, persistence, network or input side effects. `WowLiveAssembler.observe(source, frame, nowMs)` returns an immutable decoded observation only after a complete checksum-valid message and advancing ticks. `isLive(nowMs)` describes advancing observed transport; it does not authenticate game state or establish capture permission, optical quality, profile compatibility or delivery to a phone.

## Frame and schema bounds

A frame is exactly 512 bytes: THWL magic, version1, little-endian uint32 tick and message Adler-32 digest, uint16 page/count/payload length/total length, page Adler-32, then up to487 payload bytes and zero padding. The page checksum covers the first21 header bytes plus meaningful payload. Total message length is1..32768 bytes, with exactly the corresponding page count (at most68). A changed message identity replaces the bounded assembly; conflicting pages, invalid padding/checksums and malformed frames are rejected. Frame bytes are copied before retention.

The strict decoder admits the retained `thumble.wow-live` version1 structure, pinned classic-era/interface11509 or forever/interface16001. It rejects malformed UTF-8, duplicate JSON keys (including escaped aliases), unknown fields, non-integer numeric tokens, unsupported client pairs, invalid bank/button/command metadata, duplicate assignments/icons and inconsistent icon references. Actions/icons/devices and all text/numeric fields retain explicit bounds. Optional values follow the retained null/absent semantics. These schema identities are compatibility contracts, not claims about currently installed game builds.

## Freshness and replay

The caller supplies a positive uint32 source identity from its independently owned capture-window selection and a nonnegative safe-integer monotonic time. Neither comes from page payload. A source switch or expired transport clears partial assembly and requires two advancing ticks before delivery. uint32 wrap uses the forward half-range rule; repeated, backward and half-range ticks do not refresh liveness. Unchanged payload can advance transport freshness without being redelivered. Two seconds without advancement makes the observation stale; stale context must not interrupt physical input.

Status queries and observations share a clock high-water mark. A backward query stays false; backward observation resets partial state and rejects until time catches up. Merely querying an older time cannot revive stale observations. This clock check cannot prove a captured frame originated from the selected game. Adler-32 detects accidental corruption and does not authenticate a source; an actively fabricated advancing stream is outside this core's authority.

## Evidence and remaining integration

Synthetic fixtures cover maximum assembly, reordered and mixed pages, corruption, source changes, reload, repeated/frozen/backward ticks, wrap, clock regression, UTF-8 boundaries and strict schema rejection. They contain no character/account exports. The retained native optical producer and capture code remain migration inputs.

Launch live sync remains required. Signed headless capture permission, supported window/scaling behavior, capture identity/freshness, observation-to-profile mapping, phone delivery, visible stale state and real capture/phone acceptance are separate unfinished work. Manual snapshot import/refresh must remain available when observation is stale or unavailable. This module neither changes saved configuration nor grants input authority.

## Portable pixel decoding

`@thumble/domain/wow-optical-panel` accepts explicit top-left RGBA8 pixels, dimensions and stride. Native capture wrappers must normalize channel order and orientation. Dimensions are at most8192each and16,777,216pixels; stride padding is bounded and the entire input must fit64MiB. Discovery searches the top-left512-square area, calibrates fiducial spacing and16grays, and validates the decoded512-byte page before producing a copied256-square RGBA atlas. A fixed4,194,304sample-read budget rejects adversarial scanning work. Output bytes are independent of the capture buffer and caller-owned. PNG encoding and native capture remain outside this module.

Synthetic tests cover the retained10scales, four-corner atlas orientation, padded/offset buffers, nonlinear calibration/noise, corrupt payload, clipping and discovery bounds, output ownership and the scan-work limit. These tests establish decoder behavior on generated pixels, not real capture quality or signed capture permission.
