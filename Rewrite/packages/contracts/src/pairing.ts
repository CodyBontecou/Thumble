import { exact, identity, record } from "./receiver.ts";
export const PAIRING_WINDOW_MS = 120_000;
export const PAIRING_ATTEMPTS = 5;
export type PairingCommand =
  | Readonly<{
      command:
        | "pairing-open"
        | "pairing-status"
        | "pairing-list"
        | "pairing-cancel"
        | "pairing-stop-listening";
    }>
  | Readonly<{
      command: "pairing-revoke";
      phoneId: string;
    }>
  | Readonly<{
      command: "pairing-listen";
      bindAddress: string;
      advertiseHost: string;
    }>;
export type PairingStatus = Readonly<{
  state: "closed" | "open";
  windowId: string | null;
  expiresAt: number | null;
  attemptsRemaining: number;
  networkEnabled: boolean;
}>;
export type PairingOffer = Readonly<{
  windowId: string;
  secret: string;
  expiresAt: number;
}>;
export type PairingInvitation = PairingOffer &
  Readonly<{
    host: string;
    port: number;
    certificatePin: string;
    authorityInstanceId: string;
  }>;
export type PairingTransport = Readonly<{
  listening: boolean;
  bindAddress: string | null;
  advertiseHost: string | null;
  port: number | null;
  certificatePin: string;
  certificateDER: string;
  persistentIdentity: boolean;
  serverName: "thumble-rewrite.local";
  controlVersion: 2;
  inputEnabled: false;
}>;
export type TrustedPhone = Readonly<{
  phoneId: string;
  label: string;
  credentialEpoch: string;
  active: boolean;
  expiresAt: number;
}>;
export type PairingReply = Readonly<{
  authorityInstanceId: string;
  pairing: PairingStatus;
  offer: PairingOffer | PairingInvitation | null;
  transport?: PairingTransport;
  phones?: readonly TrustedPhone[];
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
function port(value: unknown): number {
  if (
    typeof value !== "number" ||
    !Number.isInteger(value) ||
    value < 1 ||
    value > 65535
  )
    throw new Error("invalid_pairing_port");
  return value;
}
function host(value: unknown): string {
  if (
    typeof value !== "string" ||
    value.length > 253 ||
    !/^[A-Za-z0-9.:-]+$/.test(value) ||
    ["0.0.0.0", "::"].includes(value)
  )
    throw new Error("invalid_pairing_host");
  return value;
}
function bind(value: unknown): string {
  if (typeof value !== "string" || !/^[0-9a-fA-F:.\[\]]{1,96}$/.test(value))
    throw new Error("invalid_pairing_bind_address");
  return value;
}
export function decodePairingCommand(value: unknown): PairingCommand {
  const raw = record(value),
    withPhone = Object.hasOwn(raw, "phoneId"),
    withAddress =
      Object.hasOwn(raw, "bindAddress") || Object.hasOwn(raw, "advertiseHost");
  const d = data(
    value,
    withAddress
      ? ["command", "bindAddress", "advertiseHost"]
      : withPhone
        ? ["command", "phoneId"]
        : ["command"],
  );
  if (d.command === "pairing-revoke" && withPhone) {
    return Object.freeze({
      command: "pairing-revoke",
      phoneId: identity(d.phoneId),
    });
  }
  if (d.command === "pairing-listen" && withAddress) {
    return Object.freeze({
      command: "pairing-listen",
      bindAddress: bind(d.bindAddress),
      advertiseHost: host(d.advertiseHost),
    });
  }
  if (
    withAddress ||
    withPhone ||
    (d.command !== "pairing-open" &&
      d.command !== "pairing-status" &&
      d.command !== "pairing-list" &&
      d.command !== "pairing-cancel" &&
      d.command !== "pairing-stop-listening")
  )
    throw new Error("unsupported_pairing_command");
  return Object.freeze({ command: d.command });
}
function transport(value: unknown): PairingTransport {
  const d = data(value, [
    "listening",
    "bindAddress",
    "advertiseHost",
    "port",
    "certificatePin",
    "certificateDER",
    "persistentIdentity",
    "serverName",
    "controlVersion",
    "inputEnabled",
  ]);
  if (
    typeof d.listening !== "boolean" ||
    typeof d.persistentIdentity !== "boolean" ||
    d.serverName !== "thumble-rewrite.local" ||
    d.controlVersion !== 2 ||
    d.inputEnabled !== false
  )
    throw new Error("invalid_pairing_transport");
  const pin = pairingSecret(d.certificatePin);
  if (
    typeof d.certificateDER !== "string" ||
    !/^(?:[0-9a-f]{2}){1,16384}$/.test(d.certificateDER)
  )
    throw new Error("invalid_pairing_transport");
  const certificateDER = d.certificateDER;
  if (d.listening) {
    const address = bind(d.bindAddress),
      number = port(d.port);
    if (!d.persistentIdentity || !address.endsWith(`:${number}`))
      throw new Error("invalid_pairing_transport");
    return Object.freeze({
      listening: true,
      bindAddress: address,
      advertiseHost: host(d.advertiseHost),
      port: number,
      certificatePin: pin,
      certificateDER,
      persistentIdentity: true,
      serverName: "thumble-rewrite.local",
      controlVersion: 2,
      inputEnabled: false,
    });
  }
  if (d.bindAddress !== null || d.advertiseHost !== null || d.port !== null)
    throw new Error("invalid_pairing_transport");
  return Object.freeze({
    listening: false,
    bindAddress: null,
    advertiseHost: null,
    port: null,
    certificatePin: pin,
    certificateDER,
    persistentIdentity: d.persistentIdentity,
    serverName: "thumble-rewrite.local",
    controlVersion: 2,
    inputEnabled: false,
  });
}
function utf8Size(value: string): number {
  let count = 0;
  for (const character of value) {
    const point = character.codePointAt(0)!;
    count += point < 0x80 ? 1 : point < 0x800 ? 2 : point < 0x10000 ? 3 : 4;
  }
  return count;
}
function phones(value: unknown): readonly TrustedPhone[] {
  if (
    !Array.isArray(value) ||
    Object.getPrototypeOf(value) !== Array.prototype ||
    value.length > 32
  )
    throw new Error("invalid_trusted_phones");
  const descriptors = Object.getOwnPropertyDescriptors(value);
  if (
    Reflect.ownKeys(value).length !== value.length + 1 ||
    Object.values(descriptors).some((d) => !("value" in d))
  )
    throw new Error("invalid_trusted_phones");
  let previous = "";
  return Object.freeze(
    Array.from({ length: value.length }, (_, index) => {
      if (!Object.hasOwn(descriptors, index))
        throw new Error("invalid_trusted_phones");
      const d = data(descriptors[String(index)]!.value, [
        "phoneId",
        "label",
        "credentialEpoch",
        "active",
        "expiresAt",
      ]);
      const phoneId = identity(d.phoneId);
      if (
        phoneId <= previous ||
        typeof d.label !== "string" ||
        !d.label.length ||
        utf8Size(d.label) > 128 ||
        /[\p{Cc}\p{Cs}]/u.test(d.label) ||
        typeof d.credentialEpoch !== "string" ||
        !/^[1-9][0-9]{0,18}$/.test(d.credentialEpoch) ||
        BigInt(d.credentialEpoch) > 9223372036854775807n ||
        typeof d.active !== "boolean" ||
        timestamp(d.expiresAt) === 0
      )
        throw new Error("invalid_trusted_phone");
      previous = phoneId;
      return Object.freeze({
        phoneId,
        label: d.label,
        credentialEpoch: d.credentialEpoch,
        active: d.active,
        expiresAt: timestamp(d.expiresAt),
      });
    }),
  );
}
export function decodePairingReply(value: unknown): PairingReply {
  const raw = record(value),
    withTransport = Object.hasOwn(raw, "transport"),
    withPhones = Object.hasOwn(raw, "phones");
  const d = data(value, [
    "authorityInstanceId",
    "pairing",
    "offer",
    ...(withTransport ? ["transport"] : []),
    ...(withPhones ? ["phones"] : []),
  ]);
  const authorityInstanceId = identity(d.authorityInstanceId),
    connection = withTransport ? transport(d.transport) : undefined;
  const p = data(d.pairing, [
    "state",
    "windowId",
    "expiresAt",
    "attemptsRemaining",
    "networkEnabled",
  ]);
  if (
    typeof p.networkEnabled !== "boolean" ||
    !Number.isInteger(p.attemptsRemaining) ||
    Number(p.attemptsRemaining) < 0 ||
    Number(p.attemptsRemaining) > PAIRING_ATTEMPTS ||
    (connection
      ? connection.listening !== p.networkEnabled
      : p.networkEnabled !== false)
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
      networkEnabled: p.networkEnabled,
    });
  else if (p.state === "open" && Number(p.attemptsRemaining) > 0)
    pairing = Object.freeze({
      state: "open",
      windowId: identity(p.windowId),
      expiresAt: timestamp(p.expiresAt),
      attemptsRemaining: Number(p.attemptsRemaining),
      networkEnabled: p.networkEnabled,
    });
  else throw new Error("invalid_pairing_message");
  let offer: PairingOffer | PairingInvitation | null = null;
  if (d.offer !== null) {
    const o = data(
      d.offer,
      p.networkEnabled
        ? [
            "windowId",
            "secret",
            "expiresAt",
            "host",
            "port",
            "certificatePin",
            "authorityInstanceId",
          ]
        : ["windowId", "secret", "expiresAt"],
    );
    const bootstrap = Object.freeze({
      windowId: identity(o.windowId),
      secret: pairingSecret(o.secret),
      expiresAt: timestamp(o.expiresAt),
    });
    if (
      pairing.state !== "open" ||
      bootstrap.windowId !== pairing.windowId ||
      bootstrap.expiresAt !== pairing.expiresAt
    )
      throw new Error("invalid_pairing_message");
    if (p.networkEnabled) {
      const invitation = Object.freeze({
        ...bootstrap,
        host: host(o.host),
        port: port(o.port),
        certificatePin: pairingSecret(o.certificatePin),
        authorityInstanceId: identity(o.authorityInstanceId),
      });
      if (
        invitation.authorityInstanceId !== authorityInstanceId ||
        invitation.host !== connection?.advertiseHost ||
        invitation.port !== connection.port ||
        invitation.certificatePin !== connection.certificatePin
      )
        throw new Error("invalid_pairing_invitation");
      offer = invitation;
    } else offer = bootstrap;
  }
  return Object.freeze({
    authorityInstanceId,
    pairing,
    offer,
    ...(connection ? { transport: connection } : {}),
    ...(withPhones ? { phones: phones(d.phones) } : {}),
  });
}
