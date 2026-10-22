import { spawnSync } from "node:child_process";
import { isAbsolute } from "node:path";
import { exact, parseStrictJson, record } from "@thumble/contracts/receiver";
/** Trusted child-only bounded native publication. Never runs on parent input IO. */
export function publishConfigurationFile(
  executable: string,
  path: string,
  bytes: Uint8Array,
): Readonly<{ artifactHash: string; byteCount: number; replayed: boolean }> {
  if (!isAbsolute(path) || path.includes("\0") || path.length > 4096)
    throw new Error("configuration_export_path_invalid");
  const result = spawnSync(executable, ["configuration-export-file", path], {
    input: bytes,
    timeout: 10000,
    maxBuffer: 4096,
    windowsHide: true,
  });
  if (result.error || result.status !== 0 || result.stderr.length) {
    const code = result.stderr?.toString("utf8").trim();
    throw new Error(
      code && /^configuration_export_[a-z_]{1,60}$/.test(code)
        ? code
        : "configuration_export_failed",
    );
  }
  try {
    const v = record(
      parseStrictJson(
        new TextDecoder("utf-8", { fatal: true }).decode(result.stdout),
      ),
    );
    exact(v, ["version", "artifactHash", "byteCount", "replayed"]);
    if (
      v.version !== 1 ||
      typeof v.artifactHash !== "string" ||
      !/^[0-9a-f]{64}$/.test(v.artifactHash) ||
      v.byteCount !== bytes.length ||
      typeof v.replayed !== "boolean"
    )
      throw new Error();
    return Object.freeze({
      artifactHash: v.artifactHash,
      byteCount: bytes.length,
      replayed: v.replayed,
    });
  } catch {
    throw new Error("configuration_export_response_invalid");
  }
}
