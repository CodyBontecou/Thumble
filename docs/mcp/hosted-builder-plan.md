# Hosted controller builder (tunnel-free) — end-to-end plan

Status: **Phases 0–3, Phase 4 local integration, Phase 5 local iPhone pickup/practice/adoption, and Phase 6 local desktop adoption/docs decision are implemented; production deployment, physical-device acceptance, and the visible ChatGPT alpha remain pending.** This document turns the deferred "stateless cloud
builder" alternative from [`remote-deployment-plan.md`](remote-deployment-plan.md)
into a scoped, phased plan. Every phase keeps the existing relay connector unchanged; the
builder is a second connector mode, not a replacement.

## Goal

Let any user build a complete controller setup in ChatGPT through hosted
MCP with **no Mac, no `thumble` CLI, and no Xcode** — then carry the result
forward:

```text
ChatGPT ──HTTPS (Streamable HTTP, OAuth 2.1)──> thumble-gateway (cloud)
                                                   │  builder sessions
                                                   │  run thumble-core
                                                   │  server-side
                 emits portable profile artifact ──┘
                        │
        (a) iPhone picks it up now:  scan / open link → practice-mode keypad
        (b) Desktop adopts it later: profile import → host authority →
            paired-phone delivery (unchanged single-authority model)
```

The cloud never becomes a live authority over any phone. It builds
**pre-adoption state** and emits an **importable artifact**. The iPhone may
hold and preview that artifact in practice mode, but adoption is reserved
for an explicit import into the Mac's `thumble-host` authority.

## Constraints that shape the design

1. **Single authority stands.** `thumble-host` remains the only
   configuration authority with phone delivery
   ([`README.md`](README.md) § Authority). The builder avoids dual
   authority by being stateless-per-artifact: build → emit → done. Cloud
   storage between sessions is a *workspace* (editable draft state), never
   a synchronized mirror of any device.
2. **No Swift in the cloud.** `thumble-core` already independently owns
   documents, revisions, drafts, commits, templates, built-in generation,
   customization, elements, styles, groups, bindings, outputs, control-bar,
   orientation, and device frames (`docs/rust-host.md`). The builder uses
   only migrated Rust operations. Anything still Swift-only is out of scope
   for v1 (see § Skins).
3. **Capability honesty rule.** Hosted-only tools live in
   `docs/mcp/hosted-builder-capabilities-v1.json`, never in the CLI-to-MCP
   ledger with invented CLI paths. Builder entries move from `planned` to
   `current` only when the operation actually runs through the hosted
   surface. `docs/mcp/cli-capabilities-v1.json` continues to track only
   shared CLI operations such as profile import/export and spec generation;
   both contract verifiers must stay green at every phase.
4. **ChatGPT connector mechanics are already solved.** OAuth 2.1 + DCR,
   per-tool scopes, rate limits, Streamable HTTP, and the action-catalog
   budget constraints are production-proven by the relay connector
   (`openai-client-acceptance.md`).

## Why now: the two named blockers have moved

The relay plan deferred this mode because it (a) needed a Linux-capable
Swift bridge and (b) needed full profile/package export+import. Since then:

- (a) is gone for the profile surface — `thumble-cli-bridge` routes the
  migrated families through Rust with no Swift dependency
  (`docs/rust-host.md`: the helper runs begin/edit/validate/CAS entirely
  through Rust when no live host owns the lock).
- (b) is implemented for profiles: `profile export` / `profile import`
  now route raw bounded artifacts through the Rust authority using a
  hashed portable v1 codec, deterministic draft/CAS import, and an exact
  sibling Swift/Rust CLI bridge. The operations are `host-cli-only` in
  the CLI-to-MCP ledger because their mapped general MCP tools are still
  future work; package/skin export remains separate.
- The one large remaining Swift-only family is **skins** (scaffold, CSS
  lint/computed, compile, quality, preview — `docs/skins/`). The skin
  compiler, CSS profile, deterministic package build, and native preview
  pipeline are substantial Swift code with stack-safety budgets
  (`docs/stack-safety.md`); porting them to Rust is its own project and is
  **explicitly out of scope** for builder v1. Hosted skins can be
  reconsidered after the artifact flow proves out.

## Components and changes

### 1. Portable profile artifact — `Host/crates/thumble-core` (+ protocol)

- Define one canonical **profile artifact** format: a self-describing
  document containing a profile set (or one profile), semantic bindings,
  outputs, customization, orientation preferences, control-bar
  configuration, catalog revision, schema version, and a canonical
  content hash. JSON, bounded, no binaries, no credentials, no device
  identity.
- Implement encode/decode in Rust next to the existing configuration
  model. The hard cross-language gate is the real Swift `thumble` CLI
  invoking its exact-sibling Rust bridge for export → raw file routing →
  import, plus a checked-in artifact/canonical/hash vector consumed by
  both Rust and Swift tests. Swift never re-encodes current artifact JSON.
- Ledger: `profile.export` and `profile.import` are `host-cli-only` after
  the Rust codec, authority transaction, Swift transport, stack-safety,
  and real-binary flow gates pass. They move to `current` only if their
  mapped general MCP tools actually ship.
- Versioned from day one (`artifactVersion: 1`) with forward-compatible
  decoding rules; unknown fields are preserved, not dropped.

### 2. Spec-based generation in Rust — `Host/crates/thumble-core`

- The agent-spec generation path (the `generate --spec` JSON documented
  in repo `SKILL.md`) now lives in `thumble-core` as strict generation
  spec v1: aliases, roles, slots, thumb layout, basic/rich appearance,
  joystick/trigger/trackpad settings, semantic keys, deterministic UUIDs,
  bounded warnings, layout quality, generated JSON, and artifact v1.
- The schema-8 CLI bridge exposes read-only `generation.plan-spec`; the
  Swift CLI uses that result for native reporting/preview and installs by
  sending the generated artifact through the existing `profile.import`
  draft/CAS transaction. No Swift generation or direct persistence sits
  on the spec path.
- `generation.install-spec` is `host-cli-only`: the migrated CLI is
  shipped and real-binary verified, while hosted `generate_from_spec`
  remains `planned` until the builder endpoint lands.

### 3. Builder crate — `Host/crates/thumble-builder`

- Implemented pure builder sessions over `thumble-core`: revisioned,
  replay-safe typed edits, generate-from-spec, all 17 template installs,
  validation, sanitized preview, deterministic artifact emission, discard,
  expiry checks, and bounded serialization. No host socket, filesystem,
  pairing, phone delivery, input, clock, randomness, or subprocess API.
- Gateway persistence is intentionally external and principal-keyed. The
  session owns only pre-adoption state; Phase 4 deletes expired/discarded
  sessions and sessions whose emitted artifact was stored successfully.
- Template parity uses SHA-manifested portable post-materialization fixtures
  regenerated by the real Swift/Rust sibling trio and atomically verified.
  Public projections expose no raw document, numeric key codes, owner IDs,
  credentials, or operation descriptors.

### 4. Gateway integration — `Host/crates/thumble-gateway`

- New connector mode at a distinct endpoint (suggested
  `https://thumble-mcp-gateway.fly.dev/builder/mcp`) so the existing
  `/mcp` relay surface and its cached manifests are untouched.
- Reuse the proven OAuth 2.1/DCR/PKCE, token-family rotation, rate-limit,
  and audit implementations — **not** the relay's device-bound identity
  model as-is. Add builder-specific protected-resource metadata and an
  authorization flow that creates an opaque `builder` principal after
  explicit consent without requiring a linked Mac. Builder access and
  refresh tokens carry that principal kind/id and one independent token
  family; they cannot call the relay `/mcp` endpoint, and device-bound
  relay tokens cannot call `/builder/mcp` without a separate builder
  authorization. Builder workspaces and artifacts are keyed to the
  builder principal; revocation remains token-family scoped. Later Mac
  adoption transfers only the emitted artifact and never merges cloud
  principal state into a device identity.
- New scope: `thumble.build` — builder session tools. The
  `thumble.read`/`thumble.draft`/`thumble.config`/`thumble.input` relay
  scopes and the relay tunnel are unrelated to this endpoint; a builder
  connector needs no linked device and works with zero Macs online.
- Tool surface (v1, names indicative): `begin_builder_session`,
  `builder_status`, `edit_builder_profile` (typed operation envelope,
  reusing the edit-operation discriminators), `validate_builder_profile`,
  `preview_builder_profile` (structured/JSON + textual fallback, same
  projections as `preview_configuration_draft`), `install_template`
  (catalog-bounded), `generate_from_spec` (the §2 operation),
  `emit_profile_artifact` (returns the artifact document + share URL),
  `discard_builder_session`. Every tool is catalog-scoped and bounded;
  schemas stay inside the action-discovery budget using the compact
  strict-envelope technique proven on the relay.
- Artifact delivery: `emit_profile_artifact` stores the artifact under
  the user's account (bounded count/size, expiring) and returns (a) the
  full artifact JSON inline for the agent to save, and (b) a short-lived
  share URL (`/share/<id>` + token) suitable for QR / universal link.
- Audit logging unchanged in spirit: account id, tool, outcome — never
  profile content or key material.

### 5. iPhone pickup — `Sources/iOS` + gateway share endpoint

- The iOS app already has a QR pipeline (`QRCodeScannerView`),
  practice-mode UX (`IOSLocalKeypadUX`), complete local profile snapshots
  (`GamepadConfigurationProfilePersistence`), and a separate pending-edit
  store. None is a portable builder-artifact store with origin, expiry,
  hash, and adoption metadata. Add a dedicated, bounded
  pending-builder-artifact store rather than overloading profile or
  pending-edit persistence.
- v1 flow: scan QR (or open universal link) → fetch artifact from the
  gateway share endpoint → validate + decode in Swift (mirror of the Rust
  codec, shipped as shared model code where possible) → offer
  **"Keep on iPhone"**: save the artifact in the new pending-artifact
  store and render it in practice mode. The screen clearly states the
  keypad is practice-only until a Mac adopts it.
- Adoption handoff: when the user later pairs with a Mac, the locally
  held artifact is offered for explicit upload to the authenticated host
  authority. The dedicated `profile-artifact-adoption-v1` capability uses
  ordered 256 KiB chunks, raw and semantic hash validation, append-as-copies
  import, a persisted idempotency ledger, and authoritative snapshot
  confirmation before the phone deletes its quarantine copy. The phone
  never becomes an authority. Local evidence and remaining physical-device
  checks are recorded in [`phase5-adoption-local-acceptance.md`](phase5-adoption-local-acceptance.md).
- Per AGENTS.md CLI parity: any iPhone-side import affordance must have a
  CLI/app counterpart (`profile import` covers it; verify parity
  documentation).

### 6. Desktop / CLI adoption — small surface, already half-built

- `thumble profile import ARTIFACT.json` adopts a builder artifact into
  the Mac authority (same operation as §1's Rust import).
- Mac app: an "Import shared keypad…" entry that accepts the share URL or
  file. Mac-app changes require CLI parity (AGENTS.md); the CLI command
  above satisfies it.
- `thumble relay`/relay connector users see no change.

### 7. Contracts, docs, gates

- `docs/mcp/hosted-builder-capabilities-v1.json`: hosted-only builder
  operations, connector path/scope, and share endpoint ship as `planned`
  in phase 0; status flips per phase as capabilities actually land. Its
  independent verifier (`scripts/verify-hosted-builder-capabilities.py`)
  enforces the exact tool set, `builder-session` / `share-read` gates,
  authority boundary, and shared-operation references without weakening
  the CLI ledger's mandatory CLI-path rule.
- `docs/rust-host.md`: new "Hosted builder" section (authority stance,
  session model, artifact format pointer).
- `docs/mcp/README.md`: builder mode paragraph — the gateway gains
  builder sessions that are **pre-adoption state only**; the "router,
  never an authority" sentence gains a precise exception statement: the
  builder owns no synchronized state and emits importable artifacts.
- Swift/shared-model changes (artifact codec mirror, iOS import) must
  preserve `Tests/StackSafetyRegressionTests.swift` budgets and run
  `./scripts/verify-stack-safety.sh` (AGENTS.md).

## Security checklist (ship blockers)

- The builder endpoint reuses OAuth/DCR/token-family code but issues
  builder-principal tokens under builder-specific protected-resource
  metadata. Builder sessions require the `thumble.build` scope and bearer
  auth on every request; builder and relay tokens are mutually unusable
  across endpoints.
- Builder sessions are catalog-bounded and typed — no arbitrary file
  access, no paths, no commands, no input injection (there is no device
  to inject into; the endpoint has no tunnel by construction).
- Artifacts contain no credentials, tokens, device identity, or pairing
  data. Share URLs are short-lived, token-gated, single-purpose, and
  rate-limited; artifact storage is bounded and expiring per account.
- No cross-user access: share tokens are unguessable and scoped to one
  artifact id; the builder tools only touch the calling account's
  workspaces.
- Audit logs record account/tool/outcome only.
- iPhone import validates and decodes defensively (bounded sizes,
  schema-validated) exactly like any other untrusted input at the
  authority boundary; a malformed artifact can never reach keypad
  rendering without passing the codec's validation.
- The relay connector's security posture is untouched: no new tunnels,
  no new input paths, no change to local flags.

## Verification plan

1. Rust unit + round-trip tests: artifact codec parity vs Swift
   `profile export` fixtures; spec-generation parity vs Swift `generate
   --spec` fixtures (same layouts, same warnings).
2. Builder crate tests: session lifecycle, workspace expiry, bounded
   operation behavior, artifact emission determinism (same inputs →
   same artifact hash).
3. Gateway e2e (extend `Host/crates/thumble-gateway/tests/e2e.rs`
   pattern): DCR → builder scope → begin/edit/validate/preview/generate/
   emit → share fetch → 401/scope/rate-limit cases.
4. `cargo test --workspace`, `scripts/verify-rust-host.sh`,
   `python3 scripts/verify-mcp-cli-parity.py`, and
   `python3 scripts/verify-hosted-builder-capabilities.py` green at every
   phase.
5. Swift side: stack-safety suite green; checked-in Rust artifact fixture
   inspected/routed by Swift tests; real sibling CLI export/import flow
   green.
6. iOS: artifact import UI test with a generated share link; practice-mode
   preview; adoption upload to a test host.
7. Manual: ChatGPT developer-mode builder connector end-to-end (build a
   real game profile from a natural-language request → artifact → iPhone
   scan → practice preview → Mac import → paired-phone delivery).
   Record receipts in `docs/mcp/openai-client-acceptance.md` style.

## Phased rollout

| Phase | Deliverable | Rough effort | Depends on |
|---|---|---|---|
| 0 | Separate hosted-builder capability ledger (`planned`) + verifier + this doc linked from `docs/mcp/README.md`; workspace scaffolding for `thumble-builder` | small | — |
| 1 | Portable profile artifact codec in Rust + Swift/Rust authority parity; `profile.export`/`profile.import` ledger `host-cli-only` until mapped MCP tools ship | medium | 0 |
| 2 | Spec-based generation migrated to `thumble-core`; Swift CLI plan → artifact-import flow; `generation.install-spec` `host-cli-only` until hosted tool ships | medium | 0 |
| 3 | `thumble-builder`: pure replay-safe sessions, safe edits/generation/all templates, preview/validation, deterministic artifact emission | medium | 1, 2 |
| 4 | Gateway builder endpoint: OAuth reuse, `thumble.build` scope, tools, share URLs, rate limits, e2e tests; Fly deploy | medium–large | 3 |
| 5 | iPhone pickup: QR/universal-link import, practice-mode hold, adoption upload | medium | 4 |
| 6 | Desktop adoption polish (Mac app import entry), docs finalize, alpha with own accounts; write the cloud-skins scoping decision | small–medium | 4 (5 parallel) |

Sequencing notes: phases 1 and 2 are independent and can run in parallel
after 0. Everything through phase 4 is buildable and testable locally
against an in-process gateway before any deploy. Skins stay CLI/local
throughout; revisit cloud skins only after the artifact flow proves out
(phase 6 exit criterion).

## Implementation state

| Phase | Evidence | State |
|---|---|---|
| 0 | `hosted-builder-capabilities-v1.json`, its verifier, CI gate, and `thumble-builder` workspace crate | complete |
| 1 | `thumble-core` artifact codec + RFC 8785 fixtures; schema-8 Rust authority export/import with draft/CAS/replay; bounded Swift transport and raw CLI routing; `verify-profile-artifact-flow.sh`; stack-safety and Rust workspace gates | complete |
| 2 | Deterministic generation spec v1 in `thumble-core`; schema-8 read-only planning; Swift native report/preview + artifact import; cross-language fixtures and `verify-generation-spec-flow.sh` | complete |
| 3 | Pure `thumble-builder` session state machine; safe edits/generation/all-template fixtures; preview/validation; deterministic emission and deletion handoff | complete |
| 4 local | Gateway OAuth/builder MCP/share integration, full loopback e2e, restart/migration/prune and backup-restore gate, Linux Docker build gate; production and ChatGPT receipts remain pending | locally verified, unavailable |
| 5 local | Defensive share pickup, quarantine, practice-only preview, and explicit paired-Mac append-as-copies adoption with replay/snapshot confirmation; physical-device checks remain pending | locally verified, unavailable |
| 6 local | Mac "Import Shared Keypad…" (share link or file → token-free review → explicit append/replace through the same authority import), Rust-authority pointer to `thumble profile import --append`, docs finalize, cloud-skins decision recorded; alpha production/device/ChatGPT receipts remain pending | locally verified, unavailable |

## Decision: cloud skins stay out of v1 and the Phase 6 alpha

**Decision:** hosted-builder v1 and its alpha do **not** include skin
authoring, CSS tooling, compilation, or `.pocketpad` emission from the cloud.
Skins remain local/CLI/package-import only.

Rationale: the Swift skin/CSS compiler family (`docs/skins/css-authoring.md`)
is the largest remaining Swift-only surface and was explicitly out of scope
for v1. The profile artifact flow has not yet passed production deployment,
visible ChatGPT acceptance, or physical-device pickup/adoption; widening the
cloud surface now would expand untrusted-asset/CSS processing, artifact
semantics, and parity obligations before the simpler profile authority
boundary has proven out.

Revisit only as a **separately approved project after Phase 6 profile
acceptance**, with all of the following prerequisites satisfied first:

- a versioned skin artifact/authority contract (schema, hash, and migration);
- an explicit Rust-vs-Swift compiler strategy (no silent dual codecs);
- bounded CSS, asset, and archive safety (decompression/quota limits);
- deterministic package hashes across platforms;
- native-render review evidence for cloud-built skins;
- stack-safety coverage for any new Swift decode paths; and
- CLI/Mac parity plus explicit product/security sign-off.

## Explicitly out of scope (v1)

- Skin authoring, compilation, CSS tooling, or `.pocketpad` emission from
  the cloud (Swift-only compiler; see `docs/skins/css-authoring.md` for
  the surface that would need porting).
- Any cloud → phone push path. Phone delivery stays host-owned.
- Live cloud sync or multi-device editing of an adopted profile.
- Any `thumble.input` scope or input tools on the builder endpoint (the
  existing relay's defined-but-ungrantable scope remains unchanged).
- Replacing or altering the relay connector.
