# Rewrite stdio MCP seam

The development CLI serves MCP with `thumble-rewrite mcp serve --runtime-dir
/absolute/path/to/runtime`. Start its service separately with the same runtime
and sibling native receiver. An agent's MCP configuration can use:

```json
{
  "mcpServers": {
    "thumble-rewrite": {
      "command": "/absolute/path/to/dist/thumble-rewrite",
      "args": ["mcp", "serve", "--runtime-dir", "/absolute/path/to/runtime"]
    }
  }
}
```

The adapter invokes the same authenticated local client operations as the CLI.
It neither starts a competing authority nor requires the desktop GUI. Closing
MCP leaves the independent service running. Windows directory protection uses an
awaited native helper with a three-second deadline before the same restricted
endpoint-file validation; tool handling does not synchronously wait on a child
process in the stdio event callback. This snapshot uses the recording
backend; no physical input is emitted.

| Tool                | Capability                           | Result                                           |
| ------------------- | ------------------------------------ | ------------------------------------------------ |
| `receiver_status`   | Default                              | Validated service/receiver status                |
| `receiver_release`  | Always available                     | Emergency neutralization                         |
| `pairing_status`    | Default                              | Native pairing status without invitation secrets |
| `pairing_list`      | Default                              | Native phone trust metadata                      |
| `receiver_activate` | Launch with `--allow-recorded-input` | CAS activation of an ephemeral runtime profile   |
| `receiver_sample`   | Launch with `--allow-recorded-input` | One validated full-state recording sample        |

The launching user's flag controls the tool catalog. A tool argument cannot
expand capabilities. Both recording operations use the existing contract decoders
and epoch/replay barriers; emergency release remains available without opt-in.
Tools have strict schemas and local-operation annotations. Receipts use structured
`{version, ok, result}` or `{version, ok, error}` data with bounded public error
codes. Endpoint bearer tokens and credential files are never returned. Pairing
open/listen and trust mutation remain explicit CLI operations in this slice;
configuration CRUD, previews, capture, addon installation and full MCP parity are
still pending their application operations and separate capability gates.

The official MCP TypeScript SDK server/core 2.3.1 serves both modern discovery
and legacy initialization over one stdio connection. Stdout contains protocol
messages only, including on CLI argument errors and connection close. Startup
errors go to stderr as a public code. The transport admits at most 64 KiB per
frame, 16 outstanding request IDs, 256 KiB queued output, and a three-second output
write deadline. IDs are bounded strings or safe integers. Duplicate outstanding
IDs, duplicate JSON keys, invalid UTF-8, excessive depth/graph, batch frames and
oversized input close the connection before the invalid frame dispatches. EOF
closes the protocol connection; clients must keep input open while awaiting
responses. Existing in-flight authority work is not rolled back by disconnect.

Headless tests use actual SDK clients for both eras against the independent
native receiver/service. They cover catalog opt-in, malformed arguments, authority
parity, recording, release and service survival. The standalone packaging test
also connects both client eras to the compiled binary in a temporary directory
with no checkout or Bun on PATH. Frame and output-budget tests cover fragmented
UTF-8, coalesced frames, duplicate keys/IDs and blocked output.

The CLI package includes runtime license notices. The notice manifest pins SDK
runtime distributions and dependency versions; verification/build rejects stale
notices. The audited Node bundle uses Ajv and excludes the separate Cloudflare
validator. No hosted service, browser transport or remote MCP listener is added.
