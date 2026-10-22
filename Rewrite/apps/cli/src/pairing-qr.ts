import { inflateSync } from "node:zlib";
import { spawnSync } from "node:child_process";
import {
  constants,
  closeSync,
  existsSync,
  fchmodSync,
  fsyncSync,
  openSync,
  writeSync,
} from "node:fs";
import { isAbsolute } from "node:path";
import { createHash } from "node:crypto";
import type { PairingReply } from "@thumble/contracts/pairing";
const MAX_PNG = 1024 * 1024;
export function validatePairingQRDestination(
  path: string,
  helper: string,
  platform = process.platform,
): void {
  if (platform !== "darwin") throw new Error("pairing_qr_requires_macos");
  if (
    !isAbsolute(path) ||
    !isAbsolute(helper) ||
    path.includes("\0") ||
    helper.includes("\0") ||
    path.length > 4096 ||
    helper.length > 4096
  )
    throw new Error("pairing_qr_absolute_path_required");
  if (existsSync(path)) throw new Error("pairing_qr_destination_exists");
}
function crc(bytes: Uint8Array): number {
  let result = 0xffffffff;
  for (const byte of bytes) {
    result ^= byte;
    for (let bit = 0; bit < 8; bit++)
      result = (result >>> 1) ^ (result & 1 ? 0xedb88320 : 0);
  }
  return (result ^ 0xffffffff) >>> 0;
}
/** Bounded full PNG structure/CRC check; native Vision tests prove exact QR content. */
export function validatePairingQRPNG(bytes: Buffer): void {
  const invalid = () => {
    throw new Error("pairing_qr_invalid_png");
  };
  if (
    bytes.length < 57 ||
    bytes.length > MAX_PNG ||
    !bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))
  )
    invalid();
  let offset = 8,
    chunks = 0,
    hasData = false,
    ended = false;
  let dimension = 0,
    channels = 0,
    dataEnded = false;
  const compressed: Buffer[] = [];
  while (offset < bytes.length) {
    if (++chunks > 128 || offset + 12 > bytes.length) invalid();
    const length = bytes.readUInt32BE(offset),
      end = offset + 12 + length;
    if (end > bytes.length) invalid();
    const kind = bytes.toString("ascii", offset + 4, offset + 8);
    if (!/^[A-Za-z]{4}$/.test(kind) || kind[2] !== kind[2]!.toUpperCase())
      invalid();
    if (
      !["IHDR", "IDAT", "IEND"].includes(kind) &&
      kind[0] === kind[0]!.toUpperCase()
    )
      invalid();
    if (
      crc(bytes.subarray(offset + 4, end - 4)) !== bytes.readUInt32BE(end - 4)
    )
      invalid();
    if (chunks === 1) {
      if (kind !== "IHDR" || length !== 13) invalid();
      const width = bytes.readUInt32BE(offset + 8),
        height = bytes.readUInt32BE(offset + 12);
      dimension = width;
      channels = bytes[offset + 17] === 2 ? 3 : 4;
      if (
        width < 232 ||
        width > 2048 ||
        width !== height ||
        width % 8 !== 0 ||
        bytes[offset + 16] !== 8 ||
        ![2, 6].includes(bytes[offset + 17]!) ||
        bytes[offset + 18] !== 0 ||
        bytes[offset + 19] !== 0 ||
        bytes[offset + 20] !== 0
      )
        invalid();
    } else if (kind === "IHDR") invalid();
    if (kind === "IDAT") {
      if (length === 0 || dataEnded) invalid();
      hasData = true;
      compressed.push(bytes.subarray(offset + 8, end - 4));
    } else if (hasData) dataEnded = true;
    if (kind === "IEND") {
      if (length !== 0 || !hasData || end !== bytes.length) invalid();
      ended = true;
    }
    if (ended && end !== bytes.length) invalid();
    offset = end;
  }
  if (!ended) invalid();
  const stride = dimension * channels + 1,
    expected = stride * dimension;
  let decoded: Buffer;
  try {
    decoded = inflateSync(Buffer.concat(compressed), {
      maxOutputLength: expected,
    });
  } catch {
    return invalid();
  }
  if (decoded.length !== expected) invalid();
  for (let y = 0; y < dimension; y++) if (decoded[y * stride]! > 4) invalid();
}
export function exportPairingQR(
  reply: PairingReply,
  path: string,
  helper: string,
): Readonly<{
  path: string;
  byteCount: number;
  sha256: string;
  containsPairingSecret: true;
}> {
  validatePairingQRDestination(path, helper);
  const offer = reply.offer;
  if (
    !offer ||
    !("host" in offer) ||
    !("certificatePin" in offer) ||
    !("authorityInstanceId" in offer)
  )
    throw new Error("pairing_qr_listener_required");
  // Only the exact already-validated native invitation. No transport DER, phone
  // credential, local token, URI scheme or caller-synthesized address enters QR.
  const payload = JSON.stringify({
    authorityInstanceId: offer.authorityInstanceId,
    certificatePin: offer.certificatePin,
    expiresAt: offer.expiresAt,
    host: offer.host,
    port: offer.port,
    secret: offer.secret,
    windowId: offer.windowId,
  });
  if (Buffer.byteLength(payload) > 4096)
    throw new Error("pairing_qr_invitation_too_large");
  const result = spawnSync(helper, ["render"], {
    input: payload,
    timeout: 5000,
    maxBuffer: MAX_PNG,
    windowsHide: true,
  });
  if (result.error || result.status !== 0 || result.stderr.length !== 0) {
    if (
      result.error &&
      "code" in result.error &&
      result.error.code === "ETIMEDOUT"
    )
      throw new Error("pairing_qr_timeout");
    throw new Error("pairing_qr_helper_failed");
  }
  validatePairingQRPNG(result.stdout);
  let fd: number;
  try {
    fd = openSync(
      path,
      constants.O_WRONLY |
        constants.O_CREAT |
        constants.O_EXCL |
        constants.O_NOFOLLOW,
      0o600,
    );
  } catch (error) {
    if (
      error &&
      typeof error === "object" &&
      "code" in error &&
      error.code === "EEXIST"
    )
      throw new Error("pairing_qr_destination_exists");
    throw new Error("pairing_qr_write_failed");
  }
  try {
    fchmodSync(fd, 0o600);
    let offset = 0;
    while (offset < result.stdout.length) {
      const written = writeSync(fd, result.stdout, offset);
      if (written <= 0) throw new Error("short_write");
      offset += written;
    }
    fsyncSync(fd);
  } catch {
    throw new Error("pairing_qr_write_failed");
  } finally {
    closeSync(fd);
  }
  return Object.freeze({
    path,
    byteCount: result.stdout.length,
    sha256: createHash("sha256").update(result.stdout).digest("hex"),
    containsPairingSecret: true,
  });
}
