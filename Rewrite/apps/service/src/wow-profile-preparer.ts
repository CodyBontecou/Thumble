import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { isAbsolute } from "node:path";
import { LosslessJson } from "@thumble/contracts/json";
import type { PendingWowObservation } from "@thumble/application/wow-live-observer";
import type {
  WowProfilePreparer,
  WowCancellationSignal,
  WowProfilePreparationRequest,
  WowProfilePreparationReply,
} from "@thumble/application/wow-profile-refresh";

export const WOW_PROFILE_HELPER_LIMITS = Object.freeze({
  requestBytes: 12 * 1024 * 1024,
  replyBytes: 16 * 1024 * 1024,
  prepareMs: 2000,
  terminateMs: 500,
});
function fail(): never {
  throw new Error("wow_profile_helper_rejected");
}
/** Retained identity derivation only; this SHA-1 UUID is never a security digest. */
export function wowLiveProfileId(observation: PendingWowObservation): string {
  const namespace = Buffer.from("6ba7b8119dad11d180b400c04fd430c8", "hex");
  const bytes = createHash("sha1")
    .update(namespace)
    .update(
      `thumble:wow-live:${observation.character.flavor}:${observation.character.id}`,
      "utf8",
    )
    .digest()
    .subarray(0, 16);
  bytes[6] = (bytes[6]! & 15) | 80;
  bytes[8] = (bytes[8]! & 63) | 128;
  const value = bytes.toString("hex");
  return `${value.slice(0, 8)}-${value.slice(8, 12)}-${value.slice(12, 16)}-${value.slice(16, 20)}-${value.slice(20)}`;
}
/** Parse four independent bounded JSON values so before+after can use the retained
 * 16MiB envelope without raising the owned document's individual 8MiB budget. */
function envelope(text: string): Map<string, LosslessJson> {
  let at = 0;
  const result = new Map<string, LosslessJson>();
  const space = () => {
    while (/[ \t\r\n]/.test(text[at] ?? "!")) at++;
  };
  const stringEnd = () => {
    if (text[at++] !== '"') fail();
    while (at < text.length) {
      const c = text[at++];
      if (c === "\\") at++;
      else if (c === '"') return;
    }
    fail();
  };
  space();
  if (text[at++] !== "{") fail();
  space();
  if (text[at] !== "}")
    for (;;) {
      space();
      const start = at;
      stringEnd();
      const key = LosslessJson.parse(text.slice(start, at)).stringValue!;
      if (
        ![
          "schemaVersion",
          "sourceSHA256",
          "beforeProfile",
          "document",
        ].includes(key) ||
        result.has(key)
      )
        fail();
      space();
      if (text[at++] !== ":") fail();
      space();
      const valueStart = at;
      let depth = 0,
        quoted = false;
      while (at < text.length) {
        const c = text[at]!;
        if (quoted) {
          if (c === "\\") {
            at += 2;
            continue;
          }
          if (c === '"') quoted = false;
        } else {
          if (c === '"') quoted = true;
          else if (c === "{" || c === "[") depth++;
          else if ((c === "}" || c === "]") && depth > 0) depth--;
          else if (depth === 0 && (c === "," || c === "}")) break;
        }
        at++;
      }
      if (quoted || depth !== 0) fail();
      result.set(key, LosslessJson.parse(text.slice(valueStart, at)));
      space();
      if (text[at] !== ",") break;
      at++;
    }
  if (text[at++] !== "}") fail();
  space();
  if (at !== text.length) fail();
  return result;
}
function decodeReply(
  text: string,
  request: WowProfilePreparationRequest,
): WowProfilePreparationReply {
  const values = envelope(text),
    source = values.get("sourceSHA256"),
    before = values.get("beforeProfile"),
    document = values.get("document");
  const sourceSHA256 =
    source?.kind === "null" || source === undefined ? null : source.stringValue;
  const beforeProfile =
    before?.kind === "null" || before === undefined ? null : before;
  const expected =
    request.existingProfileJSON === null
      ? null
      : createHash("sha256")
          .update(request.existingProfileJSON, "utf8")
          .digest("hex");
  if (
    values.get("schemaVersion")?.text().trim() !== "2" ||
    sourceSHA256 !== expected ||
    Boolean(beforeProfile) !== Boolean(request.existingProfileJSON) ||
    !document ||
    document.kind !== "object" ||
    (beforeProfile?.kind !== undefined && beforeProfile.kind !== "object")
  )
    fail();
  const profiles = document.get("/profiles"),
    profile = profiles?.get("/0"),
    snapshot = LosslessJson.parse(request.snapshotJSON);
  if (
    profiles?.kind !== "array" ||
    profiles.length !== 1 ||
    profile?.get("/id")?.stringValue?.toLowerCase() !== request.profileID ||
    document.get("/activeProfileID")?.stringValue?.toLowerCase() !==
      request.profileID ||
    document.get("/defaultProfileID")?.stringValue?.toLowerCase() !==
      request.profileID ||
    profile.get("/outputMode")?.stringValue !== "controller" ||
    profile.get("/wowLive/characterID")?.stringValue !==
      snapshot.get("/character/id")?.stringValue ||
    profile.get("/wowLive/flavor")?.stringValue !==
      snapshot.get("/client/flavor")?.stringValue
  )
    fail();
  return Object.freeze({
    schemaVersion: 2,
    sourceSHA256: expected,
    beforeProfile,
    document,
  });
}
function requestBytes(request: WowProfilePreparationRequest): Buffer {
  const keys = Object.keys(request).sort().join(",");
  if (
    keys !==
      [
        "schemaVersion",
        "wowProfileCommand",
        "profileID",
        "snapshotJSON",
        "atlasPNGBase64",
        "existingProfileJSON",
        "existingBindingsJSON",
      ]
        .sort()
        .join(",") ||
    request.schemaVersion !== 2 ||
    request.wowProfileCommand !== "prepare-owned" ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(
      request.profileID,
    )
  )
    fail();
  for (const [value, max, optional] of [
    [request.snapshotJSON, 32768, false],
    [request.atlasPNGBase64, 2796204, false],
    [request.existingProfileJSON, 8 * 1024 * 1024, true],
    [request.existingBindingsJSON, 1024 * 1024, true],
  ] as const) {
    if (optional && value === null) continue;
    if (typeof value !== "string" || Buffer.byteLength(value, "utf8") > max)
      fail();
  }
  if (
    (request.existingProfileJSON === null) !==
    (request.existingBindingsJSON === null)
  )
    fail();
  const bytes = Buffer.from(JSON.stringify(request) + "\n", "utf8");
  if (bytes.length > WOW_PROFILE_HELPER_LIMITS.requestBytes) fail();
  return bytes;
}
/** Explicit optional retained presentation tool, invoked without desktop GUI/IPC.
 * One child max; an unconfirmed termination fences future starts. Never log child
 * text, arguments, paths, profiles, atlas bytes or inherited error messages. */
export class RetainedWowProfilePreparer implements WowProfilePreparer {
  #child: ReturnType<typeof spawn> | undefined;
  constructor(private readonly executable: string) {
    if (
      !isAbsolute(executable) ||
      executable.length > 4096 ||
      executable.includes("\0")
    )
      fail();
  }
  async prepare(
    request: WowProfilePreparationRequest,
    signal: WowCancellationSignal,
  ): Promise<WowProfilePreparationReply> {
    if (this.#child) throw new Error("wow_profile_helper_busy");
    if (signal.aborted) throw new Error("wow_profile_helper_cancelled");
    const bytes = requestBytes(request);
    const child = spawn(this.executable, [], {
      stdio: ["pipe", "pipe", "ignore"],
      windowsHide: true,
    });
    this.#child = child;
    return await new Promise((resolve, reject) => {
      let unsubscribe = () => {};
      let chunks: Buffer[] = [],
        size = 0,
        failed = false,
        settled = false;
      let terminate: ReturnType<typeof setTimeout> | undefined,
        abandon: ReturnType<typeof setTimeout> | undefined;
      const rejectOnce = () => {
        if (settled) return;
        settled = true;
        chunks = [];
        unsubscribe();
        reject(new Error("wow_profile_helper_failed"));
      };
      const cancel = () => {
        if (failed) return;
        failed = true;
        child.kill("SIGTERM");
        terminate = setTimeout(
          () => child.kill("SIGKILL"),
          WOW_PROFILE_HELPER_LIMITS.terminateMs,
        );
        abandon = setTimeout(
          rejectOnce,
          2 * WOW_PROFILE_HELPER_LIMITS.terminateMs,
        );
      };
      const deadline = setTimeout(cancel, WOW_PROFILE_HELPER_LIMITS.prepareMs);
      unsubscribe = signal.onCancel(cancel);
      child.stdout!.on("data", (chunk: Buffer) => {
        if (failed || settled) return;
        if (size + chunk.length > WOW_PROFILE_HELPER_LIMITS.replyBytes) {
          cancel();
          return;
        }
        size += chunk.length;
        chunks.push(Buffer.from(chunk));
      });
      child.on("error", cancel);
      child.stdin!.on("error", cancel);
      child.on("close", (code) => {
        if (this.#child === child) this.#child = undefined;
        clearTimeout(deadline);
        if (terminate) clearTimeout(terminate);
        if (abandon) clearTimeout(abandon);
        unsubscribe();
        if (settled) return;
        if (failed || signal.aborted || code !== 0) {
          rejectOnce();
          return;
        }
        try {
          const value = decodeReply(
            new TextDecoder("utf-8", { fatal: true }).decode(
              Buffer.concat(chunks, size),
            ),
            request,
          );
          settled = true;
          chunks = [];
          resolve(value);
        } catch {
          rejectOnce();
        }
      });
      child.stdin!.end(bytes);
      if (signal.aborted) cancel();
    });
  }
}
