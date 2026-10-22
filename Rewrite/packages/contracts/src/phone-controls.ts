import { counter, exact, identity, record, FRAME_BYTES } from "./receiver.ts";
import {
  decodeControlMap,
  type ControlMap,
  type ControlRegion,
} from "./mobile-input.ts";
import { decodeSavedConfigurationPin } from "./saved-runtime.ts";
export const SAVED_MAP_ERRORS = [
  "saved_map_busy",
  "saved_map_timeout",
  "saved_map_unavailable",
  "saved_map_reactivation_required",
  "saved_map_unsupported_profile",
  "saved_map_response_too_large",
] as const;
export type SavedMapError = (typeof SAVED_MAP_ERRORS)[number];
export type PhoneControlsQuery = Readonly<{
  authorityInstanceId: string;
  expectedConfigurationRevision: string;
  expectedSourceHash: string;
  profileId: string;
  generation: string;
  revision: string;
  viewportWidth: string;
  viewportHeight: string;
}>;
export type PhoneControlsEvent = PhoneControlsQuery &
  Readonly<{ version: 1; event: "phone-controls"; eventId: string }>;
export type PhoneControlsCommand = PhoneControlsQuery &
  Readonly<{ command: "configuration-phone-controls" }>;
export type PhoneControlsResult =
  | Readonly<Record<string, string | number> & { kind: "controls" }>
  | Readonly<{ kind: "error"; error: SavedMapError }>;
const QUERY = [
  "authorityInstanceId",
  "expectedConfigurationRevision",
  "expectedSourceHash",
  "profileId",
  "generation",
  "revision",
  "viewportWidth",
  "viewportHeight",
] as const;
const HEADER = [
  "kind",
  "authorityInstanceId",
  "configurationRevision",
  "sourceHash",
  "configurationSha256",
  "profileId",
  "generation",
  "revision",
  "viewportWidth",
  "viewportHeight",
  "controlCount",
];
export function phoneControlNumber(value: unknown): number {
  if (
    typeof value !== "string" ||
    value.length > 32 ||
    !/^(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:e[+-]?[0-9]+)?$/.test(value) ||
    !Number.isFinite(Number(value))
  )
    throw new Error("invalid_phone_controls_number");
  return Number(value);
}
export function decodePhoneControlsQuery(value: unknown): PhoneControlsQuery {
  const v = record(value);
  exact(v, QUERY);
  const pin = decodeSavedConfigurationPin({
      configurationRevision: v.expectedConfigurationRevision,
      sourceHash: v.expectedSourceHash,
      profileId: v.profileId,
    }),
    generation = counter(v.generation),
    revision = counter(v.revision);
  if (generation === "0" || pin.profileId !== v.profileId)
    throw new Error("invalid_phone_controls_query");
  const width = phoneControlNumber(v.viewportWidth),
    height = phoneControlNumber(v.viewportHeight);
  if (height < 240 || width < height || width > 4096 || height > 4096)
    throw new Error("invalid_phone_controls_viewport");
  return Object.freeze({
    authorityInstanceId: identity(v.authorityInstanceId),
    expectedConfigurationRevision: pin.configurationRevision,
    expectedSourceHash: pin.sourceHash,
    profileId: pin.profileId,
    generation,
    revision,
    viewportWidth: v.viewportWidth as string,
    viewportHeight: v.viewportHeight as string,
  });
}
function queryFields(value: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(QUERY.map((k) => [k, value[k]]));
}
export function decodePhoneControlsEvent(
  value: unknown,
  authority: string,
): PhoneControlsEvent {
  const v = record(value);
  exact(v, ["version", "event", "eventId", ...QUERY]);
  const eventId = counter(v.eventId);
  if (
    v.version !== 1 ||
    v.event !== "phone-controls" ||
    eventId === "0" ||
    v.authorityInstanceId !== authority
  )
    throw new Error("invalid_phone_controls_event");
  return Object.freeze({
    ...decodePhoneControlsQuery(queryFields(v)),
    version: 1,
    event: "phone-controls",
    eventId,
  });
}
export function decodePhoneControlsCommand(
  value: unknown,
): PhoneControlsCommand {
  const v = record(value);
  exact(v, ["command", ...QUERY]);
  if (v.command !== "configuration-phone-controls")
    throw new Error("invalid_phone_controls_command");
  return Object.freeze({
    ...decodePhoneControlsQuery(queryFields(v)),
    command: "configuration-phone-controls",
  });
}
/** Scalar-only projection never includes source documents, binary assets or secrets. */
export function decodePhoneControlsResult(
  value: unknown,
  query: PhoneControlsQuery,
): PhoneControlsResult {
  const v = record(value);
  if (v.kind === "error") {
    exact(v, ["kind", "error"]);
    if (
      typeof v.error !== "string" ||
      !(SAVED_MAP_ERRORS as readonly string[]).includes(v.error)
    )
      throw new Error("invalid_phone_controls_error");
    return Object.freeze({ kind: "error", error: v.error as SavedMapError });
  }
  if (
    v.kind !== "controls" ||
    Object.keys(v).length > 845 ||
    !Number.isInteger(v.controlCount) ||
    Number(v.controlCount) < 1 ||
    Number(v.controlCount) > 64
  )
    throw new Error("invalid_phone_controls_result");
  if (
    v.authorityInstanceId !== query.authorityInstanceId ||
    v.configurationRevision !== query.expectedConfigurationRevision ||
    v.sourceHash !== query.expectedSourceHash ||
    v.profileId !== query.profileId ||
    v.generation !== query.generation ||
    v.revision !== query.revision ||
    v.viewportWidth !== query.viewportWidth ||
    v.viewportHeight !== query.viewportHeight ||
    typeof v.configurationSha256 !== "string" ||
    !/^[0-9a-f]{64}$/.test(v.configurationSha256)
  )
    throw new Error("phone_controls_pin_mismatch");
  const keys = [...HEADER],
    controls: ControlRegion[] = [];
  for (let i = 0; i < Number(v.controlCount); i++) {
    const prefix = `control${i}`,
      fields = ["Id", "Action", "X", "Y", "Width", "Height"],
      haptics = [
        "HapticStyle",
        "HapticPattern",
        "HapticIntensity",
        "HapticSharpness",
        "HapticDuration",
      ];
    keys.push(...fields.map((k) => prefix + k));
    const present = haptics.filter((k) => Object.hasOwn(v, prefix + k));
    if (present.length !== 0 && present.length !== 5)
      throw new Error("invalid_phone_controls_haptic");
    if (present.length) keys.push(...haptics.map((k) => prefix + k));
    controls.push({
      id: v[prefix + "Id"] as string,
      action: v[prefix + "Action"] as ControlRegion["action"],
      x: phoneControlNumber(v[prefix + "X"]),
      y: phoneControlNumber(v[prefix + "Y"]),
      width: phoneControlNumber(v[prefix + "Width"]),
      height: phoneControlNumber(v[prefix + "Height"]),
      ...(present.length
        ? {
            hapticFeedback: {
              style: v[prefix + "HapticStyle"] as "light",
              pattern: v[prefix + "HapticPattern"] as "single",
              intensity: phoneControlNumber(v[prefix + "HapticIntensity"]),
              sharpness: phoneControlNumber(v[prefix + "HapticSharpness"]),
              duration: phoneControlNumber(v[prefix + "HapticDuration"]),
            },
          }
        : {}),
    });
  }
  exact(v, keys);
  decodeControlMap({
    version: 1,
    generation: query.generation,
    revision: query.revision,
    controls,
  });
  // All admitted strings are bounded ASCII. Reserve both private stdio and TLS
  // envelopes; a request for64 controls never raises either existing frame limit.
  if (JSON.stringify(v).length > FRAME_BYTES - 512)
    throw new Error("phone_controls_response_too_large");
  return Object.freeze({ ...v }) as PhoneControlsResult;
}
export function projectPhoneControlsMap(
  query: PhoneControlsQuery,
  configurationSha256: string,
  map: ControlMap,
): PhoneControlsResult {
  const validated = decodeControlMap(map),
    value: Record<string, string | number> = {
      kind: "controls",
      authorityInstanceId: query.authorityInstanceId,
      configurationRevision: query.expectedConfigurationRevision,
      sourceHash: query.expectedSourceHash,
      configurationSha256,
      profileId: query.profileId,
      generation: validated.generation,
      revision: validated.revision,
      viewportWidth: query.viewportWidth,
      viewportHeight: query.viewportHeight,
      controlCount: validated.controls.length,
    };
  validated.controls.forEach((c, i) => {
    const p = `control${i}`;
    for (const [key, v] of [
      ["Id", c.id],
      ["Action", c.action],
      ["X", String(c.x)],
      ["Y", String(c.y)],
      ["Width", String(c.width)],
      ["Height", String(c.height)],
    ] as const)
      value[p + key] = v;
    if (c.hapticFeedback) {
      const h = c.hapticFeedback;
      for (const [key, v] of [
        ["HapticStyle", h.style],
        ["HapticPattern", h.pattern],
        ["HapticIntensity", String(h.intensity)],
        ["HapticSharpness", String(h.sharpness)],
        ["HapticDuration", String(h.duration)],
      ] as const)
        value[p + key] = v;
    }
  });
  return decodePhoneControlsResult(value, query);
}
