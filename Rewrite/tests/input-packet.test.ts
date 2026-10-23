import { expect, test } from "bun:test";
import { createDecipheriv } from "node:crypto";
import {
  encodeInputState,
  decodeInputState,
  INPUT_PACKET_BYTES,
  INPUT_PACKET_LIMIT,
} from "../packages/contracts/src/input-packet.ts";
import { neutralGamepadState } from "@thumble/contracts";
import f from "../packages/fixtures/input-packet-v1.json";
function decrypt(hex: string): Buffer {
  const packet = Buffer.from(hex, "hex"),
    nonce = Buffer.alloc(12);
  Buffer.from(f.noncePrefixHex, "hex").copy(nonce);
  packet.copy(nonce, 4, 32, 40);
  const cipher = createDecipheriv(
    "aes-256-gcm",
    Buffer.from(f.keyHex, "hex"),
    nonce,
  );
  cipher.setAAD(packet.subarray(0, 40));
  cipher.setAuthTag(packet.subarray(-16));
  return Buffer.concat([
    cipher.update(packet.subarray(40, -16)),
    cipher.final(),
  ]);
}
test("shared input packet vectors authenticate exact metadata and portable semantic bytes", () => {
  expect(f.vectors).toHaveLength(33);
  expect(f.packetLimit).toBe(INPUT_PACKET_LIMIT);
  expect(f.packetBytes).toBe(INPUT_PACKET_BYTES);
  for (const v of f.vectors) {
    const packet = Buffer.from(v.packetHex, "hex");
    expect(packet.length).toBe(INPUT_PACKET_BYTES);
    expect(packet.subarray(0, 4).toString()).toBe("THI1");
    expect(packet.readUInt32LE(4)).toBe(0);
    expect(packet.subarray(8, 24).toString("hex")).toBe(f.sessionHex);
    expect(packet.readBigUInt64LE(24).toString()).toBe(f.generation);
    expect(packet.readBigUInt64LE(32).toString()).toBe(v.sequence);
    const plain = decrypt(v.packetHex);
    expect(plain.toString("hex")).toBe(v.payloadHex);
    expect(Buffer.from(encodeInputState(v.state)).toString("hex")).toBe(
      v.payloadHex,
    );
    expect(
      Buffer.from(encodeInputState(decodeInputState(plain))).toString("hex"),
    ).toBe(v.payloadHex);
    const offset = new Uint8Array(plain.length + 3);
    offset.set(plain, 3);
    expect(
      Buffer.from(
        encodeInputState(decodeInputState(offset.subarray(3))),
      ).toString("hex"),
    ).toBe(v.payloadHex);
  }
});
test("authenticated malformed semantic payloads are refused independently of encryption", () => {
  expect(f.invalidAuthenticated).toHaveLength(5);
  for (const v of f.invalidAuthenticated)
    expect(() => decodeInputState(decrypt(v.packetHex))).toThrow();
  for (const length of [0, 51, 53, 108])
    expect(() => decodeInputState(new Uint8Array(length))).toThrow();
  for (const value of [NaN, Infinity, -Infinity, 1.001, -1.001])
    expect(() =>
      encodeInputState({ ...neutralGamepadState(), leftStickX: value }),
    ).toThrow();
});
test("semantic payload encoding cannot execute button array accessors or accept sparse lists", () => {
  let reads = 0;
  const buttons: string[] = [];
  Object.defineProperty(buttons, "0", {
    get: () => {
      reads++;
      return "south";
    },
    enumerable: true,
  });
  buttons.length = 1;
  expect(() =>
    encodeInputState({ ...neutralGamepadState(), buttons }),
  ).toThrow();
  expect(reads).toBe(0);
  expect(() =>
    encodeInputState({ ...neutralGamepadState(), buttons: new Array(1) }),
  ).toThrow();
  const extra = ["south"];
  Object.defineProperty(extra, "secret", { value: "extra" });
  expect(() =>
    encodeInputState({ ...neutralGamepadState(), buttons: extra }),
  ).toThrow();
});
