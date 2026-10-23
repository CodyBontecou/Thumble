import { exact } from "./receiver.ts";
import { WOW_CAPTURE_STATUSES, wowCaptureCounter } from "./wow-capture.ts";
export type WowCaptureCommand =
  | Readonly<{
      command:
        | "wow-capture-status"
        | "wow-capture-request"
        | "wow-capture-stop";
    }>
  | Readonly<{ command: "wow-capture-start"; source: "world-of-warcraft" }>;
export type WowCaptureReceiptMetadata = Readonly<{
  source: number;
  generation: string;
  receipt: string;
  observedAtMs: number;
}> &
  (
    | Readonly<{
        kind: "frame";
        frameSha256: string;
        atlasSha256: string;
        atlasBytes: number;
      }>
    | Readonly<{
        kind: "status";
        status: (typeof WOW_CAPTURE_STATUSES)[number];
      }>
  );
export type WowCaptureControlStatus = Readonly<{
  kind: "wow-capture";
  enabled: boolean;
  state:
    | "disabled"
    | "stopped"
    | "waiting"
    | "capturing"
    | "stopping"
    | "ready"
    | "unavailable";
  permission: "not-inspected";
  source: number | null;
  generation: string | null;
  receipt: WowCaptureReceiptMetadata | null;
}>;
function record(value: unknown): Record<string, unknown> {
  if (
    !value ||
    typeof value !== "object" ||
    ![Object.prototype, null].includes(Object.getPrototypeOf(value))
  )
    invalid();
  const out: Record<string, unknown> = Object.create(null);
  for (const key of Reflect.ownKeys(value)) {
    if (typeof key !== "string") invalid();
    const d = Object.getOwnPropertyDescriptor(value, key);
    if (!d || !("value" in d) || !d.enumerable) invalid();
    out[key] = d.value;
  }
  return out;
}
function invalid(): never {
  throw new Error("invalid_wow_capture_control");
}
export function decodeWowCaptureCommand(input: unknown): WowCaptureCommand {
  const v = record(input);
  exact(
    v,
    v.command === "wow-capture-start" ? ["command", "source"] : ["command"],
  );
  if (v.command === "wow-capture-start") {
    if (v.source !== "world-of-warcraft") invalid();
    return { command: v.command, source: v.source };
  }
  if (
    v.command !== "wow-capture-status" &&
    v.command !== "wow-capture-request" &&
    v.command !== "wow-capture-stop"
  )
    invalid();
  return { command: v.command };
}
export function decodeWowCaptureControlStatus(
  input: unknown,
): WowCaptureControlStatus {
  const v = record(input);
  exact(v, [
    "kind",
    "enabled",
    "state",
    "permission",
    "source",
    "generation",
    "receipt",
  ]);
  if (
    v.kind !== "wow-capture" ||
    typeof v.enabled !== "boolean" ||
    v.permission !== "not-inspected" ||
    typeof v.state !== "string" ||
    ![
      "disabled",
      "stopped",
      "waiting",
      "capturing",
      "stopping",
      "ready",
      "unavailable",
    ].includes(v.state)
  )
    invalid();
  if ((v.source === null) !== (v.generation === null)) invalid();
  if (
    v.source !== null &&
    (!Number.isInteger(v.source) ||
      Number(v.source) < 1 ||
      Number(v.source) > 4294967295)
  )
    invalid();
  if (v.generation !== null) wowCaptureCounter(v.generation);
  if (
    (!v.enabled &&
      (v.state !== "disabled" || v.source !== null || v.receipt !== null)) ||
    (v.enabled && v.state === "disabled")
  )
    invalid();
  if (v.receipt !== null) {
    if (v.source === null || v.state !== "ready") invalid();
    const r = record(v.receipt);
    exact(r, [
      "source",
      "generation",
      "receipt",
      "observedAtMs",
      ...(r.kind === "frame"
        ? ["kind", "frameSha256", "atlasSha256", "atlasBytes"]
        : ["kind", "status"]),
    ]);
    if (
      r.source !== v.source ||
      r.generation !== v.generation ||
      !Number.isSafeInteger(r.observedAtMs) ||
      Number(r.observedAtMs) < 0
    )
      invalid();
    wowCaptureCounter(r.receipt);
    if (r.kind === "frame") {
      if (
        typeof r.frameSha256 !== "string" ||
        !/^[a-f0-9]{64}$/.test(r.frameSha256) ||
        typeof r.atlasSha256 !== "string" ||
        !/^[a-f0-9]{64}$/.test(r.atlasSha256) ||
        !Number.isInteger(r.atlasBytes) ||
        Number(r.atlasBytes) < 57 ||
        Number(r.atlasBytes) > 2097152
      )
        invalid();
    } else if (
      r.kind !== "status" ||
      !(WOW_CAPTURE_STATUSES as readonly unknown[]).includes(r.status)
    )
      invalid();
  }
  if (v.state === "ready" && v.receipt === null) invalid();
  return Object.freeze({
    ...v,
    receipt: v.receipt === null ? null : Object.freeze(record(v.receipt)),
  }) as unknown as WowCaptureControlStatus;
}
export function disabledWowCaptureStatus(): WowCaptureControlStatus {
  return {
    kind: "wow-capture",
    enabled: false,
    state: "disabled",
    permission: "not-inspected",
    source: null,
    generation: null,
    receipt: null,
  };
}
