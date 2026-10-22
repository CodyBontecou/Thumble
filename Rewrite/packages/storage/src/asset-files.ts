import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { isAbsolute } from "node:path";
import {
  exact,
  identity,
  parseStrictJson,
  record,
} from "@thumble/contracts/receiver";
const MAX_BYTES = 8 * 1024 * 1024;
export type StoredAsset = Readonly<{ sha256: string; byteCount: number }>;
export type AssetPreparation = Readonly<{
  version: 1;
  stageId: string;
  operationId: string;
  payloadHash: string;
  assets: readonly StoredAsset[];
  totalBytes: number;
}>;
export type PendingAssets = Readonly<{
  stageId: string;
  operationId: string;
  payloadHash: string;
  assetCount: number;
  totalBytes: number;
}>;
function invalid(): never {
  throw new Error("asset_response_invalid");
}
function hash(value: unknown): string {
  if (typeof value !== "string" || !/^[0-9a-f]{64}$/.test(value)) invalid();
  return value;
}
function number(value: unknown, maximum: number): number {
  if (
    typeof value !== "number" ||
    !Number.isSafeInteger(value) ||
    value < 0 ||
    value > maximum
  )
    invalid();
  return value;
}
function stageId(operationId: string, payloadHash: string): string {
  return createHash("sha256")
    .update(`thumble-asset-stage-v1\0${operationId}\0${payloadHash}`, "utf8")
    .digest("hex");
}
function preparation(value: unknown): AssetPreparation {
  const v = record(value);
  exact(v, [
    "version",
    "stageId",
    "operationId",
    "payloadHash",
    "assets",
    "totalBytes",
  ]);
  const operationId = identity(v.operationId),
    payloadHash = hash(v.payloadHash),
    id = hash(v.stageId);
  if (
    v.version !== 1 ||
    id !== stageId(operationId, payloadHash) ||
    !Array.isArray(v.assets) ||
    v.assets.length > 256
  )
    invalid();
  const assets: StoredAsset[] = [];
  let total = 0,
    previous = "";
  for (const item of v.assets) {
    const a = record(item);
    exact(a, ["sha256", "byteCount"]);
    const sha256 = hash(a.sha256),
      byteCount = number(a.byteCount, MAX_BYTES);
    if (sha256 <= previous) invalid();
    previous = sha256;
    total += byteCount;
    if (total > MAX_BYTES) invalid();
    assets.push(Object.freeze({ sha256, byteCount }));
  }
  if (v.totalBytes !== total) invalid();
  return Object.freeze({
    version: 1,
    stageId: id,
    operationId,
    payloadHash,
    assets: Object.freeze(assets),
    totalBytes: total,
  });
}
/** Host-only immutable files and durable preparation records. Configuration
 * commits/receipts remain the authority; retirement never deletes asset bytes.
 * Never expose this port's payloadHash or binary prepare input as an RPC tool. */
export class FileAssetStore {
  constructor(
    private readonly root: string,
    private readonly executable: string,
  ) {
    if (
      ![root, executable].every(
        (v) => typeof v === "string" && isAbsolute(v) && !v.includes("\0"),
      )
    )
      throw new Error("asset_path_invalid");
    Object.freeze(this);
  }
  private call(mode: string, key?: string, input?: Uint8Array): Uint8Array {
    const result = spawnSync(
      this.executable,
      [mode, this.root, ...(key === undefined ? [] : [key])],
      {
        ...(input === undefined ? {} : { input }),
        timeout: 5000,
        maxBuffer: MAX_BYTES + 65536,
        windowsHide: true,
      },
    );
    if (result.error || result.status !== 0) {
      if (
        result.error &&
        "code" in result.error &&
        result.error.code === "ETIMEDOUT"
      )
        throw new Error("asset_operation_timeout");
      const code = result.stderr?.toString("utf8").trim();
      throw new Error(
        code && /^(?:asset|runtime|unsafe_runtime)_[a-z_]{1,80}$/.test(code)
          ? code
          : "asset_operation_failed",
      );
    }
    if (result.stderr?.length) throw new Error("asset_response_invalid");
    return result.stdout;
  }
  private json(mode: string, key?: string, input?: Uint8Array): unknown {
    return parseStrictJson(
      new TextDecoder("utf-8", { fatal: true }).decode(
        this.call(mode, key, input),
      ),
    );
  }
  prepare(
    operationId: string,
    payloadHash: string,
    input: readonly Uint8Array[],
  ): AssetPreparation {
    operationId = identity(operationId);
    payloadHash = hash(payloadHash);
    if (!Array.isArray(input) || input.length > 256)
      throw new Error("asset_request_invalid");
    const pool = new Map<string, Uint8Array>();
    let total = 0;
    for (let index = 0; index < input.length; index++) {
      const entry = Object.getOwnPropertyDescriptor(input, String(index));
      if (!entry || !("value" in entry) || !(entry.value instanceof Uint8Array))
        throw new Error("asset_request_invalid");
      if (entry.value.byteLength > MAX_BYTES)
        throw new Error("asset_batch_too_large");
      const bytes = new Uint8Array(entry.value);
      const sha = createHash("sha256").update(bytes).digest("hex");
      if (!pool.has(sha)) {
        total += bytes.length;
        if (total > MAX_BYTES) throw new Error("asset_batch_too_large");
        pool.set(sha, bytes);
      }
    }
    const assets = [...pool.entries()]
      .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
      .map(([sha256, bytes]) => ({ sha256, byteCount: bytes.length }));
    const header = Buffer.from(
        JSON.stringify({ version: 1, operationId, payloadHash, assets }),
        "utf8",
      ),
      prefix = Buffer.alloc(4);
    prefix.writeUInt32BE(header.length);
    const body = Buffer.concat([
      prefix,
      header,
      ...assets.map((a) => pool.get(a.sha256)!),
    ]);
    const result = preparation(this.json("assets-prepare", undefined, body));
    if (
      result.stageId !== stageId(operationId, payloadHash) ||
      JSON.stringify(result.assets) !== JSON.stringify(assets)
    )
      invalid();
    return result;
  }
  read(sha256: string): Uint8Array {
    sha256 = hash(sha256);
    const bytes = this.call("assets-read", sha256);
    if (
      bytes.length > MAX_BYTES ||
      createHash("sha256").update(bytes).digest("hex") !== sha256
    )
      throw new Error("asset_integrity_failed");
    return bytes;
  }
  manifest(id: string): AssetPreparation {
    id = hash(id);
    const value = preparation(this.json("assets-manifest", id));
    if (value.stageId !== id) invalid();
    return value;
  }
  pending(): readonly PendingAssets[] {
    const value = this.json("assets-pending");
    if (!Array.isArray(value) || value.length > 64) invalid();
    const pending: PendingAssets[] = [];
    let previous = "";
    for (const item of value) {
      const v = record(item);
      exact(v, [
        "stageId",
        "operationId",
        "payloadHash",
        "assetCount",
        "totalBytes",
      ]);
      const id = hash(v.stageId),
        operationId = identity(v.operationId),
        payloadHash = hash(v.payloadHash);
      if (id !== stageId(operationId, payloadHash) || id <= previous) invalid();
      previous = id;
      pending.push(
        Object.freeze({
          stageId: id,
          operationId,
          payloadHash,
          assetCount: number(v.assetCount, 256),
          totalBytes: number(v.totalBytes, MAX_BYTES),
        }),
      );
    }
    return Object.freeze(pending);
  }
  retire(id: string): void {
    if (this.call("assets-retire", hash(id)).length) invalid();
  }
}

Object.freeze(FileAssetStore.prototype);
