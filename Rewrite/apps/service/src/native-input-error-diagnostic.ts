/** Opt-in debug stderr only. Never forward arbitrary child output. */
const prefix = "native_input_error ";
const operations = new Set([
  "native-client",
  "native-server-wait",
  "native-server-send",
  "phone-control",
  "sample",
]);
const ioContexts = new Set([
  "native-read",
  "native-write",
  "native-read-options",
  "native-write-options",
]);
const codes = new Set([
  "native_input_timeout",
  "native_input_transport_failed",
  "native_input_frame_invalid",
  "native_input_rejected",
  "native_owner_reply_timeout",
  "native_owner_reply_closed",
  "native_input_owner_failed",
  "input_session_closed",
  "input_packet_invalid",
  "other",
]);
const servingCodes = new Set([
  "native_input_server_rejected",
  ...codes,
  "authenticated_control_transport_failed",
  "authenticated_control_budget_exhausted",
  "authenticated_control_message_invalid",
  "phone_authentication_rejected",
  "phone_trust_owner_unavailable",
  "phone_trust_reservation_failed",
  "phone_trust_clock_invalid",
  "phone_trust_clock_rollback",
  "phone_trust_reservation_expired",
  "phone_trust_clock_unreserved",
  "input_protocol_invalid",
  "input_packet_budget_exhausted",
  "input_broker_unavailable",
  "input_renewal_too_early",
  "native_input_release_unconfirmed",
  "clock_unavailable",
]);
const controlStages = new Set([
  "await-frame",
  "packet",
  "decode-control",
  "grant",
  "renewal",
  "configuration",
  "progress",
  "release",
  "disconnect",
  "status",
]);
const kinds = new Set([
  "would-block",
  "timed-out",
  "interrupted",
  "unexpected-eof",
  "broken-pipe",
  "connection-reset",
  "connection-aborted",
  "not-connected",
  "invalid-input",
  "permission-denied",
  "other",
]);
const exits = new Set([
  "stopped",
  "handshake",
  "read-deadline",
  "read-failure",
  "invalid-frame",
  "invalid-payload",
  "queue-full",
  "queue-closed",
  "wake-failure",
  "send-failure",
]);
export function decodeNativeInputErrorLine(line: string): string | undefined {
  if (
    line.length > 384 ||
    !/^[\x20-\x7e]*$/.test(line) ||
    !line.startsWith(prefix)
  )
    return;
  try {
    const text = line.slice(prefix.length),
      value: unknown = JSON.parse(text);
    if (!value || typeof value !== "object" || Array.isArray(value)) return;
    const row = value as Record<string, unknown>;
    if (
      row.version !== 1 ||
      (row.role !== "broker" && row.role !== "receiver") ||
      typeof row.context !== "string"
    )
      return;
    const fields = Object.keys(row)
      .filter((k) => !["version", "role", "context"].includes(k))
      .sort()
      .join(",");
    if (fields === "code,stage") {
      if (
        row.role !== "broker" ||
        row.context !== "phone-control-before-cleanup" ||
        typeof row.stage !== "string" ||
        !controlStages.has(row.stage) ||
        typeof row.code !== "string" ||
        !servingCodes.has(row.code)
      )
        return;
    } else if (fields === "code,op") {
      if (
        !operations.has(row.context) ||
        typeof row.op !== "number" ||
        !Number.isInteger(row.op) ||
        row.op < 0 ||
        row.op > 11 ||
        typeof row.code !== "string" ||
        !codes.has(row.code)
      )
        return;
    } else if (fields === "ioKind,osCode") {
      if (
        !ioContexts.has(row.context) ||
        typeof row.ioKind !== "string" ||
        !kinds.has(row.ioKind) ||
        (row.osCode !== null &&
          (typeof row.osCode !== "number" ||
            !Number.isInteger(row.osCode) ||
            row.osCode < -2147483648 ||
            row.osCode > 2147483647))
      )
        return;
    } else if (fields === "exit,owned") {
      if (
        row.role !== "receiver" ||
        row.context !== "native-server-exit" ||
        typeof row.exit !== "string" ||
        !exits.has(row.exit) ||
        typeof row.owned !== "number" ||
        !Number.isInteger(row.owned) ||
        row.owned < 0 ||
        row.owned > 2
      )
        return;
    } else if (fields === "exit") {
      if (
        !(
          (row.context === "native-read" && row.exit === "eof") ||
          (row.context === "native-write" && row.exit === "zero-write")
        )
      )
        return;
    } else return;
    // Native serde_json emits sorted, compact ASCII. Exact re-encoding also
    // rejects duplicate keys, whitespace, escapes, exponent forms and -0.
    const canonical = JSON.stringify(
      Object.fromEntries(
        Object.keys(row)
          .sort()
          .map((k) => [k, row[k]]),
      ),
    );
    return canonical === text ? prefix + canonical : undefined;
  } catch {
    return;
  }
}
export class NativeInputErrorForwarder {
  private line = "";
  private invalid = false;
  private scanned = 0;
  private count = 0;
  private bytes = 0;
  constructor(
    private readonly emit: (line: string) => void,
    private readonly limit: 16 | 32 = 16,
  ) {
    if (limit !== 16 && limit !== 32)
      throw new Error("invalid_error_probe_limit");
  }
  push(chunk: Uint8Array): void {
    for (const byte of chunk) {
      if (this.scanned >= 65536 || this.count >= this.limit) {
        this.line = "";
        return;
      }
      this.scanned++;
      if (byte === 10) {
        const line = !this.invalid
          ? decodeNativeInputErrorLine(this.line)
          : undefined;
        this.line = "";
        this.invalid = false;
        if (line && this.bytes + line.length + 1 <= 8192) {
          this.bytes += line.length + 1;
          this.count++;
          try {
            this.emit(line);
          } catch {
            /* Optional diagnostics cannot affect input. */
          }
        }
      } else if (byte < 32 || byte > 126 || this.line.length >= 384)
        this.invalid = true;
      else if (!this.invalid) this.line += String.fromCharCode(byte);
    }
  }
}
