# Hosted service retirement inventory

Source removal does not stop the deployed service. Do not destroy live resources from this file alone. Validate the owning account, actual resources, stored user work, backups, and retention needs before an operational retirement.

## Declared deployment

The retired fly.toml declared the Fly app `thumble-mcp-gateway` in region `iad`, a gateway container listening on port 8080, the volume name `thumble_gateway_data` mounted at `/data`, and SQLite state at `/data/thumble-gateway.db`. It enabled daily backups and at least one running machine. These are source declarations; current machine and volume IDs have not been verified.

Published endpoints included `https://thumble-mcp-gateway.fly.dev/mcp`, the hosted builder under `/builder/mcp`, artifact links under `/share/`, OAuth/discovery routes, and the outbound Mac tunnel under `/tunnel`. Verify any custom domains, additional environments, registered OAuth clients, backup destinations, scheduled tasks, and account billing resources before shutdown. Record credential names and revocation decisions without copying secret values into the repository.

## Recovery and shutdown sequence

1. Inventory exact deployed machines, volumes, custom domains/routes, secrets, jobs, and OAuth client registrations. Distinguish shared resources used by the main website, app release downloads, or other products.
2. Back up the live database and required immutable artifact bytes. Verify an isolated restore and an export route for recoverable user builds. Adopted local controller profiles remain on their authoritative desktop and phone.
3. Finish phone pickup retirement with a local recovery/export path for previously saved pending builds. Disable new remote sessions and shared-build creation with a clear retirement response.
4. Present the exact operational actions and resources for authorization. After authorization, revoke access and tokens, stop the isolated gateway/relay services and scheduled jobs, and remove only the approved unshared resources. Verify local controller use, editor operations, profile import/export, and local MCP with those services unavailable.
5. Keep the agreed backup/recovery window and confirm that retired endpoints no longer offer active connector tools or downloads. Record receipts and any retained resources.

The source distribution no longer installs a relay LaunchAgent. The CLI retains `thumble relay uninstall` solely to stop and remove the exact old `com.codybontecou.thumble.mcp-relay` agent after verifying its plist identity. This does not revoke cloud credentials or destroy stored cloud builds, and it is not run automatically by source changes.

## Outstanding evidence

A read-only inventory attempt could not access the service because the installed Fly CLI has no access token. Sign in with `flyctl auth login` before collecting actual machine, volume, and credential-name metadata. A sanitized local attempt receipt is at `build/HostedRetirement/live-inventory.json`. No database backup/restore, credential revocation, service shutdown, or remote resource destruction has been performed.

## Local pending-build recovery

Android and iOS no longer fetch or adopt hosted builds. Both offer read-only local export of previously stored pending builds, including expired/interrupted records and raw recovery archives for incomplete records. Neither path deletes the originals. macOS import now accepts ordinary local JSON files; shared portable codecs remain for local import. Receiver adoption uploads and capability advertisements are retired; legacy requests receive fixed errors without mutation. Apple recovery, packaged-client absence and simulator cancellation evidence are recorded in `docs/feature-removal-evidence/apple-hosted-retirement`; Android evidence remains in `docs/feature-removal-evidence/android-hosted-retirement`. This does not export or back up builds that exist only in the deployed gateway.
