# Windows compiled-package timeout: stage evidence

This separate test-only diagnostic is based on public `d65e499459322af4c57028ea3508fc4ae145e939`. It changes no product source, CLI mode, protocol, timeout, retry, child arguments, or process cleanup. The package testcase retains its existing 30000 ms total budget. No Windows reproduction or root-cause repair is claimed.

## Retained failure

GitHub Actions run [39990668355](https://github.com/CodyBontecou/Thumble/actions/runs/39990668355), Windows job [120541283808](https://github.com/CodyBontecou/Thumble/actions/runs/39990668355/job/120541283808), ran Bun 1.4.3 on Windows Server 2025. Its checkout was merge `a19d35724b5a4f08c8b1daa2af3fbfdfd666c9a7`, merging public `efbba1f978adadf80c042297d0e6c267bb613bee`.

The package testcase failed after 30.001192 seconds with 53 completed assertions and one dangling process killed by Bun. Artifact `12517624103` (`rewrite-portable-tests-windows-1`) has ZIP SHA256 `26d7305c0f26d920f78f97686d10df3dcfe6fc2e6305bc20c71f2250615e3605`; `package-junit.xml` independently records the same timeout and assertion count. The job later cleaned two compiled CLI/native-receiver process pairs. Those process names do not establish which child was waiting or why.

An assertion census of the exact failing source places assertion 53 after the Node MCP probe and subsequent main-service status call. The first main-service stop is next; its response/exit would advance the count to 55. A complete success has 67 assertions. The retained data therefore narrows the timeout to waiting for the first stop invocation's exit/stdout/stderr, or exceptional cleanup repeating stop without another completed assertion. It does not distinguish a stop hang from cumulative earlier work consuming the total test budget. There is no captured per-stage elapsed evidence in that run.

## Next capture

Run the existing package test with one additional test-only flag:

```sh
THUMBLE_REWRITE_PACKAGE_STAGE_PROBE=1 bun run test:package:ci
```

PowerShell equivalent:

```powershell
$env:THUMBLE_REWRITE_PACKAGE_STAGE_PROBE = '1'
bun run test:package:ci
```

The existing test reporter captures stderr rows prefixed `package_stage `. Each contains only version 1, an allowlisted stage, an allowlisted phase, and monotonic elapsed milliseconds since testcase setup. Stages cover fixed CLI family/action pairs, the four Node configuration/MCP probes, enrollment peer, local configuration preparation/reopen, and cleanup. `begin` marks dispatch, `stdout`/`stderr`/`exit` mark completion of the same promises the original test already awaited, and `end` marks their join. No output values, arguments, paths, PIDs, phone identities, pairing secrets, credentials, free-form errors, or environment values enter this schema.

Rows are limited to 192 events, 192 characters each, and 32768 total bytes. Elapsed values clamp to 0–60000 ms. Disabled diagnostics read no clock and emit nothing. Diagnostic sink errors cannot alter the operation result or error. The helper introduces no timer, wait, retry, kill, parallel child, or deadline extension. Ordered rows disambiguate repeated CLI stages; this is a single-test trace, without cross-process clock correlation.

Evidence that would discriminate the remaining possibilities:

- A late `service-stop/begin`, near 30000 ms, after successful earlier stages supports cumulative budget exhaustion. It does not alone prove an acceptable stop latency.
- An early stop begin with no completion rows localizes the wait to the compiled CLI/process or transport path.
- An `exit` row without stdout/stderr completion identifies a pipe closure wait; stream completion without `exit` identifies process exit as the outstanding promise.

No spontaneous Windows cause is attributed to the unrelated intermittent macOS doctor adversary timeout. The existing Windows deadline stays unchanged pending a capture.

## Verification and limits

Focused tests exercise a pending stop join with exit already complete and stdout held, then release the original secret-bearing result unchanged while retaining no output in the trace. They also check error identity preservation, unknown stage/phase rejection, time clamp, event/byte caps, disabled behavior, and failing diagnostic sinks.

On macOS, the same compiled package testcase passed both with the flag enabled and disabled, each with 67 assertions and the existing 30-second budget. Enabled evidence distinguishes all child/stream joins; disabled evidence contains no diagnostic rows. These controls verify the instrumentation seam. They do not reproduce or fix the Windows timeout. The source capsule and bounded evidence remain separate from production publication.

## Exact optional CI hook

Keep the default local command unchanged. For the next opted-in Windows package capture, set `shell: bash` explicitly for the Windows package step and use this body:

```bash
mkdir -p reports
set +e
THUMBLE_REWRITE_PACKAGE_STAGE_PROBE=1 bun run test:package:ci > reports/package-stage-private.txt 2>&1
package_status=$?
cat reports/package-stage-private.txt
bun tooling/collect-package-stage.ts
collector_status=$?
rm -f reports/package-stage-private.txt
if [ "$package_status" -ne 0 ]; then exit "$package_status"; fi
exit "$collector_status"
```

Add only `Rewrite/reports/package-stage.jsonl` to the existing always-uploaded report artifact, alongside the JUnit file. Never upload `package-stage-private.txt`. The collector reads at most 64 KiB, accepts only exact canonical JSON rows with fixed stage/phase allowlists and canonical integer milliseconds, and limits output to 192 rows / 32 KiB. Unexpected fields, duplicate keys, arbitrary text, unknown stages/phases, escapes, exponent forms, `-0`, and out-of-range values are rejected. Collector failure cannot turn the original failed test into a success. A missing or empty trace establishes no phase; use the JUnit result, and do not infer success.

The focused collector regression feeds hostile raw lines and verifies that only valid diagnostic rows survive. The executable collector was also run against the actual opt-in package transcript and preserved its bounded phase rows while excluding test-runner text. The scoped workflow enables this capture only on the primary Windows package job. Local and other-platform package commands keep diagnostics disabled.
