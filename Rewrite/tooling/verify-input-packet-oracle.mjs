// Independent Node/OpenSSL verification; public fixture keys only, no runtime input.
import { createCipheriv, createDecipheriv } from "node:crypto";
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";
const f = JSON.parse(
  readFileSync(
    new URL("../packages/fixtures/input-packet-v1.json", import.meta.url),
    "utf8",
  ),
);
const buttons = [
  "south",
  "east",
  "west",
  "north",
  "leftShoulder",
  "rightShoulder",
  "leftTriggerButton",
  "rightTriggerButton",
  "select",
  "start",
  "home",
  "leftStickPress",
  "rightStickPress",
  "dpadUp",
  "dpadDown",
  "dpadLeft",
  "dpadRight",
];
const fields = [
  "leftStickX",
  "leftStickY",
  "rightStickX",
  "rightStickY",
  "leftTrigger",
  "rightTrigger",
];
const key = Buffer.from(f.keyHex, "hex");
function header(sequence) {
  const h = Buffer.alloc(40);
  h.write("THI1");
  Buffer.from(f.sessionHex, "hex").copy(h, 8);
  h.writeBigUInt64LE(BigInt(f.generation), 24);
  h.writeBigUInt64LE(BigInt(sequence), 32);
  return h;
}
function nonce(sequence) {
  const n = Buffer.alloc(12);
  Buffer.from(f.noncePrefixHex, "hex").copy(n);
  n.writeBigUInt64LE(BigInt(sequence), 4);
  return n;
}
for (const v of f.vectors) {
  const plain = Buffer.alloc(52);
  let mask = 0;
  for (const b of v.state.buttons) {
    const bit = buttons.indexOf(b);
    assert(bit >= 0);
    mask |= 1 << bit;
  }
  plain.writeUInt32LE(mask);
  fields.forEach((name, i) => plain.writeDoubleLE(v.state[name], 4 + i * 8));
  assert.equal(plain.toString("hex"), v.payloadHex);
  const h = header(v.sequence),
    cipher = createCipheriv("aes-256-gcm", key, nonce(v.sequence));
  cipher.setAAD(h);
  const packet = Buffer.concat([
    h,
    cipher.update(plain),
    cipher.final(),
    cipher.getAuthTag(),
  ]);
  assert.equal(packet.toString("hex"), v.packetHex);
}
for (const v of f.invalidAuthenticated) {
  const p = Buffer.from(v.packetHex, "hex"),
    sequence = p.readBigUInt64LE(32);
  const cipher = createDecipheriv("aes-256-gcm", key, nonce(sequence));
  cipher.setAAD(p.subarray(0, 40));
  cipher.setAuthTag(p.subarray(-16));
  Buffer.concat([cipher.update(p.subarray(40, -16)), cipher.final()]);
}
console.log(
  `Node ${process.version}; OpenSSL ${process.versions.openssl}; verified ${f.vectors.length} exact packet vectors and ${f.invalidAuthenticated.length} authenticated-invalid packets`,
);
