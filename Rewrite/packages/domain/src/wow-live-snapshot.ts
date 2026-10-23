import { isGamepadButton, type GamepadButton } from "@thumble/contracts";
import { LosslessJson } from "@thumble/contracts/json";
import { decodeWowLiveUtf8, wowLiveUtf8Size } from "./wow-live-utf8.ts";

export const WOW_LIVE_MAX_BYTES = 32768;
export type WowLiveBank =
  | "base"
  | "left-trigger"
  | "right-trigger"
  | "both-triggers";
export interface WowLiveAction {
  readonly bank: WowLiveBank;
  readonly button: GamepadButton;
  readonly command: string;
  readonly label: string;
  readonly kind: string;
  readonly slot: number | null;
  readonly actionID: number | null;
  readonly iconFileID: number | null;
  readonly iconIndex: number | null;
}
export interface WowLiveSnapshot {
  readonly schema: "thumble.wow-live";
  readonly version: 1;
  readonly client: Readonly<{
    flavor: "classic-era" | "forever";
    interface: number;
  }>;
  readonly character: Readonly<{
    id: string;
    name: string;
    realm: string;
    classTag: string;
  }>;
  readonly actions: readonly WowLiveAction[];
  readonly icons: readonly number[];
  readonly devices: readonly Readonly<{
    name: string;
    vendorID: number | null;
    productID: number | null;
  }>[];
  readonly consolePortVersion: string;
}
const invalid = (): never => {
  throw new Error("invalid_wow_live_snapshot");
};
function object(
  value: unknown,
  required: readonly string[],
  optional: readonly string[] = [],
): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value))
    return invalid();
  const row = value as Record<string, unknown>;
  if (
    required.some((key) => !Object.hasOwn(row, key)) ||
    Object.keys(row).some(
      (key) => !required.includes(key) && !optional.includes(key),
    )
  )
    return invalid();
  return row;
}
function text(value: unknown, bytes: number): string {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.length > bytes ||
    wowLiveUtf8Size(value) > bytes ||
    /\p{Cc}/u.test(value)
  )
    return invalid();
  return value;
}
function integer(value: unknown, min: number, max: number): number {
  if (
    typeof value !== "number" ||
    !Number.isInteger(value) ||
    value < min ||
    value > max
  )
    return invalid();
  return value;
}
function optionalInteger(value: unknown, max: number): number | null {
  return value === undefined || value === null ? null : integer(value, 1, max);
}
function list(value: unknown, maximum: number): unknown[] {
  if (!Array.isArray(value) || value.length > maximum) return invalid();
  return value;
}

/** Untrusted configuration observation only. This never grants input authority. */
export function decodeWowLiveSnapshot(bytes: Uint8Array): WowLiveSnapshot {
  if (
    !(bytes instanceof Uint8Array) ||
    bytes.byteLength === 0 ||
    bytes.byteLength > WOW_LIVE_MAX_BYTES
  )
    return invalid();
  try {
    const source = decodeWowLiveUtf8(bytes);
    // Reuse the bounded source codec to reject duplicate (including escaped) keys.
    const parsed = LosslessJson.parse(source);
    function unsignedTokens(node: LosslessJson): void {
      if (
        node.kind === "number" &&
        !/^(?:0|[1-9][0-9]*)$/.test(node.numberToken!)
      )
        invalid();
      if (node.kind === "array")
        for (let index = 0; index < node.length!; index++)
          unsignedTokens(node.get(`/${index}`)!);
      if (node.kind === "object")
        for (const key of node.keys)
          unsignedTokens(
            node.get(`/${key.replaceAll("~", "~0").replaceAll("/", "~1")}`)!,
          );
    }
    // Retained numeric fields are unsigned integers, never coerced floats.
    unsignedTokens(parsed);
    const root = object(JSON.parse(parsed.text()), [
      "schema",
      "version",
      "client",
      "character",
      "actions",
      "icons",
      "devices",
      "consolePortVersion",
    ]);
    const client = object(root.client, ["flavor", "interface"]);
    if (
      root.schema !== "thumble.wow-live" ||
      root.version !== 1 ||
      !(
        (client.flavor === "classic-era" && client.interface === 11509) ||
        (client.flavor === "forever" && client.interface === 16001)
      )
    )
      return invalid();
    const character = object(root.character, [
      "id",
      "name",
      "realm",
      "classTag",
    ]);
    const id = text(character.id, 96);
    if (!/^Player-[A-Za-z0-9-]*$/.test(id)) return invalid();
    const icons = list(root.icons, 64).map((value) =>
      integer(value, 1, 2147483647),
    );
    if (new Set(icons).size !== icons.length) return invalid();
    const seen = new Set<string>();
    const actions = list(root.actions, 64).map((value) => {
      const row = object(
        value,
        ["bank", "button", "command", "label", "kind"],
        ["slot", "actionID", "iconFileID", "iconIndex"],
      );
      if (
        typeof row.bank !== "string" ||
        !["base", "left-trigger", "right-trigger", "both-triggers"].includes(
          row.bank,
        ) ||
        !isGamepadButton(row.button)
      )
        return invalid();
      const key = `${row.bank}:${row.button}`;
      if (seen.has(key)) return invalid();
      seen.add(key);
      const iconFileID = optionalInteger(row.iconFileID, 2147483647),
        iconIndex = optionalInteger(row.iconIndex, 4294967295);
      if (
        !(iconFileID === null && iconIndex === null) &&
        !(
          iconFileID !== null &&
          iconIndex !== null &&
          icons[iconIndex - 1] === iconFileID
        )
      )
        return invalid();
      return Object.freeze({
        bank: row.bank as WowLiveBank,
        button: row.button,
        command: text(row.command, 128),
        label: text(row.label, 128),
        kind: text(row.kind, 32),
        slot: optionalInteger(row.slot, 180),
        actionID: optionalInteger(row.actionID, 2147483647),
        iconFileID,
        iconIndex,
      });
    });
    const devices = list(root.devices, 16).map((value) => {
      const row = object(value, ["name"], ["vendorID", "productID"]);
      // Retained UInt32 device identifiers permit zero, unlike action identities.
      const deviceID = (v: unknown) =>
        v === undefined || v === null ? null : integer(v, 0, 4294967295);
      return Object.freeze({
        name: text(row.name, 128),
        vendorID: deviceID(row.vendorID),
        productID: deviceID(row.productID),
      });
    });
    return Object.freeze({
      schema: "thumble.wow-live",
      version: 1,
      client: Object.freeze({
        flavor: client.flavor as "classic-era" | "forever",
        interface: client.interface as number,
      }),
      character: Object.freeze({
        id,
        name: text(character.name, 96),
        realm: text(character.realm, 96),
        classTag: text(character.classTag, 32),
      }),
      actions: Object.freeze(actions),
      icons: Object.freeze(icons),
      devices: Object.freeze(devices),
      consolePortVersion: text(root.consolePortVersion, 32),
    });
  } catch {
    return invalid();
  }
}
