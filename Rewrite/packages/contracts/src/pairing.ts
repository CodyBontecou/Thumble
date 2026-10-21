import { exact, identity, record } from "./receiver.ts";

export const PAIRING_WINDOW_MS = 120_000;
export const PAIRING_ATTEMPTS = 5;
export type PairingCommand =
  | Readonly<{ command: "pairing-open" }>
  | Readonly<{ command: "pairing-status" }>
  | Readonly<{ command: "pairing-cancel" }>;
export type PairingStatus = Readonly<{
  state: "closed" | "open";
  windowId: string | null;
  expiresAt: number | null;
  attemptsRemaining: number;
  networkEnabled: false;
}>;
/** Local bootstrap material only; the pinned TLS endpoint must complete an invitation. */
export type PairingOffer = Readonly<{
  windowId: string;
  secret: string;
  expiresAt: number;
}>;
export type PairingReply = Readonly<{
  authorityInstanceId: string;
  pairing: PairingStatus;
  offer: PairingOffer | null;
}>;
function data(
  value: unknown,
  fields: readonly string[],
): Record<string, unknown> {
  const object = record(value);
  if (
    ![Object.prototype, null].includes(Object.getPrototypeOf(object)) ||
    Reflect.ownKeys(object).length !== fields.length ||
    Object.values(Object.getOwnPropertyDescriptors(object)).some(
      (d) => !("value" in d),
    )
  )
    throw new Error("invalid_pairing_message");
  exact(object, fields);
  return object;
}
export function pairingSecret(value: unknown): string {
  if (typeof value !== "string" || !/^[0-9a-f]{64}$/.test(value))
    throw new Error("invalid_pairing_secret");
  return value;
}
function timestamp(value: unknown): number {
  if (!Number.isSafeInteger(value) || Number(value) < 0)
    throw new Error("invalid_pairing_timestamp");
  return Number(value);
}
export function decodePairingCommand(value: unknown): PairingCommand {
  const d = data(value, ["command"]);
  if (
    d.command !== "pairing-open" &&
    d.command !== "pairing-status" &&
    d.command !== "pairing-cancel"
  )
    throw new Error("unsupported_pairing_command");
  return Object.freeze({ command: d.command });
}
export function decodePairingReply(value: unknown): PairingReply {
  const d = data(value, ["authorityInstanceId", "pairing", "offer"]);
  const p = data(d.pairing, [
    "state",
    "windowId",
    "expiresAt",
    "attemptsRemaining",
    "networkEnabled",
  ]);
  if (
    p.networkEnabled !== false ||
    !Number.isInteger(p.attemptsRemaining) ||
    Number(p.attemptsRemaining) < 0 ||
    Number(p.attemptsRemaining) > PAIRING_ATTEMPTS
  )
    throw new Error("invalid_pairing_message");
  let pairing: PairingStatus;
  if (
    p.state === "closed" &&
    p.windowId === null &&
    p.expiresAt === null &&
    p.attemptsRemaining === 0
  )
    pairing = Object.freeze({
      state: "closed",
      windowId: null,
      expiresAt: null,
      attemptsRemaining: 0,
      networkEnabled: false,
    });
  else if (p.state === "open" && Number(p.attemptsRemaining) > 0)
    pairing = Object.freeze({
      state: "open",
      windowId: identity(p.windowId),
      expiresAt: timestamp(p.expiresAt),
      attemptsRemaining: Number(p.attemptsRemaining),
      networkEnabled: false,
    });
  else throw new Error("invalid_pairing_message");
  let offer: PairingOffer | null = null;
  if (d.offer !== null) {
    const o = data(d.offer, ["windowId", "secret", "expiresAt"]);
    offer = Object.freeze({
      windowId: identity(o.windowId),
      secret: pairingSecret(o.secret),
      expiresAt: timestamp(o.expiresAt),
    });
    if (
      pairing.state !== "open" ||
      offer.windowId !== pairing.windowId ||
      offer.expiresAt !== pairing.expiresAt
    )
      throw new Error("invalid_pairing_message");
  }
  return Object.freeze({
    authorityInstanceId: identity(d.authorityInstanceId),
    pairing,
    offer,
  });
}
