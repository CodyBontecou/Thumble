import { decodeGamepadState } from "../packages/contracts/src/index.ts";
/** Independent Node/OpenSSL crypto oracle. Public deterministic test keys only. */
import { createCipheriv } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import schema from "../packages/contracts/schema/gamepad-state-v1.schema.json";
import retained from "../../Host/fixtures/gamepad/v2.json";
const fields = [
  "leftStickX",
  "leftStickY",
  "rightStickX",
  "rightStickY",
  "leftTrigger",
  "rightTrigger",
] as const;
const buttons = schema.properties.buttons.items.enum;
const keyHex = Array.from({ length: 32 }, (_, i) =>
  i.toString(16).padStart(2, "0"),
).join("");
const sessionHex = "00112233445566778899aabbccddeeff",
  noncePrefixHex = "a0a1a2a3",
  generation = "9007199254740993";
function plain(
  s: { buttons: readonly string[] } & Record<(typeof fields)[number], number>,
): Buffer {
  const b = Buffer.alloc(52);
  let mask = 0;
  s.buttons.forEach((v) => {
    const bit = buttons.indexOf(v);
    if (bit < 0) throw new Error("unknown fixture button");
    mask |= 1 << bit;
  });
  b.writeUInt32LE(mask);
  fields.forEach((f, i) => b.writeDoubleLE(s[f], 4 + i * 8));
  return b;
}
function packet(payload: Buffer, sequence: number): string {
  const header = Buffer.alloc(40);
  header.write("THI1");
  Buffer.from(sessionHex, "hex").copy(header, 8);
  header.writeBigUInt64LE(BigInt(generation), 24);
  header.writeBigUInt64LE(BigInt(sequence), 32);
  const nonce = Buffer.alloc(12);
  Buffer.from(noncePrefixHex, "hex").copy(nonce);
  nonce.writeBigUInt64LE(BigInt(sequence), 4);
  const cipher = createCipheriv(
    "aes-256-gcm",
    Buffer.from(keyHex, "hex"),
    nonce,
  );
  cipher.setAAD(header);
  return Buffer.concat([
    header,
    cipher.update(payload),
    cipher.final(),
    cipher.getAuthTag(),
  ]).toString("hex");
}
const states = retained.vectors
  .map((v) => ({
    name: v.name,
    state: {
      buttons: v.buttons ?? [],
      leftStickX: v.leftStickX ?? 0,
      leftStickY: v.leftStickY ?? 0,
      rightStickX: v.rightStickX ?? 0,
      rightStickY: v.rightStickY ?? 0,
      leftTrigger: v.leftTrigger ?? 0,
      rightTrigger: v.rightTrigger ?? 0,
    },
    reportHex: v.hex,
  }))
  .filter((v) =>
    fields.every(
      (f) =>
        Number.isFinite(v.state[f]) &&
        v.state[f] >= (f.endsWith("Trigger") ? 0 : -1) &&
        v.state[f] <= 1,
    ),
  );
const vectors = states.map((v, sequence) => ({
  ...v,
  sequence: String(sequence),
  payloadHex: plain(v.state).toString("hex"),
  packetHex: packet(plain(v.state), sequence),
}));
const all = {
  buttons: [...buttons],
  leftStickX: -0.125,
  leftStickY: 0.375,
  rightStickX: 0.625,
  rightStickY: -0.875,
  leftTrigger: 0.25,
  rightTrigger: 0.75,
};
vectors.push({
  name: "all semantic bits and fractional axes",
  state: all,
  reportHex: "",
  sequence: String(vectors.length),
  payloadHex: plain(all).toString("hex"),
  packetHex: packet(plain(all), vectors.length),
});
// Compute this extra report with the retained domain oracle, independent of packet packing.
const { encodeGamepadReport } = await import(
  "../packages/domain/src/gamepad-report.ts"
);
vectors[vectors.length - 1]!.reportHex = Buffer.from(
  encodeGamepadReport(decodeGamepadState(all)),
).toString("hex");
const base = plain(states[0]!.state);
const malformed = [
  { name: "unknown button bit", payload: Buffer.from(base) },
  { name: "nonfinite axis", payload: Buffer.from(base) },
  { name: "axis out of range", payload: Buffer.from(base) },
  { name: "negative trigger", payload: Buffer.from(base) },
  { name: "short payload", payload: Buffer.from(base.subarray(0, 51)) },
];
malformed[0]!.payload.writeUInt32LE(1 << 17);
malformed[1]!.payload.writeDoubleLE(NaN, 4);
malformed[2]!.payload.writeDoubleLE(1.001, 12);
malformed[3]!.payload.writeDoubleLE(-0.001, 36);
const invalidAuthenticated = malformed.map((m, i) => ({
  name: m.name,
  packetHex: packet(m.payload, 200 + i),
}));
const fixture = {
  version: 1,
  oracle:
    "Node crypto aes-256-gcm; deterministic public test keys, not credentials",
  keyHex,
  sessionHex,
  noncePrefixHex,
  generation,
  packetBytes: 108,
  packetLimit: 1048576,
  vectors,
  invalidAuthenticated,
  maximumSequencePacketHex: packet(base, 1048575),
  overLimitPacketHex: packet(base, 1048576),
};
const target = resolve(
  import.meta.dir,
  "../packages/fixtures/input-packet-v1.json",
);
const content = JSON.stringify(fixture, null, 2) + "\n";
if (process.argv.includes("--check")) {
  if (readFileSync(target, "utf8") !== content)
    throw new Error("Stale encrypted input packet fixtures");
} else writeFileSync(target, content);
console.log(
  `Generated ${vectors.length} packet vectors and ${invalidAuthenticated.length} invalid authenticated payloads`,
);
