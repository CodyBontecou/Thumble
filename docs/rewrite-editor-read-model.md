# Saved editor read model

`ConfigurationEditorReads` is an internal application seam for future phone
editing. It does not register a service endpoint, CLI command, MCP tool or native
TLS role. Existing phone read roles remain read-only. A future authenticated
editor transport must independently bind the host certificate, authority and
session; these saved-source DTOs provide no authentication evidence.

`editor-profile` requires an explicit profile UUID, revision, source hash and
aligned control offset. The application checks both pins against one repository
snapshot before projection. Eight controls per page preserve canonical source
order and contain only control UUID, generated label and nullable user override.
An empty override is deliberate blank text; null means use the generated label.
There are at most 128 controls. Profile names retain the existing 256-scalar
limit, and each generated/user label must fit 128 valid UTF-8 bytes. Unsupported
labels reject the read rather than truncating source data. The worst escaped
page fits within 16 KiB. No asset decoding or runtime activation is performed.

The future native client must assemble all pages against one revision/hash and
reject drift, missing pages, duplicate controls and authority/session changes
before accepting a complete cached profile. The pure domain projector receives
an already verified pin; only the application repository check establishes that
pin. A caller invoking the pure projector cannot establish snapshot provenance.

`editor-label-status` accepts the complete original typed label intent and looks
up its durable receipt using exactly the same fingerprint as the write path.
Operation-ID reuse with a changed intent is rejected. Receipt lookup precedes
current-source decoding and never executes the supplied intent, reads assets or
samples a clock. An absent receipt is pending/unknown, not proof that an in-flight
operation cannot still commit. A historical receipt can reconcile its exact
queued intent but cannot refresh the cached current profile; that requires a
separate authenticated revision-pinned read.

Neither read grants write authority. Phone writes remain gated on an explicitly
negotiated editor role and a commit-lifetime fence that survives disconnect and
parent failure. Existing input grants, installed maps and receiver epochs are
unaffected by this seam. Actual phone editor UI, wire integration and end-to-end
offline recovery remain separate work.
