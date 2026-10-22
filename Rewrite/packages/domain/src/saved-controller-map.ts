import { GAMEPAD_BUTTONS, type GamepadButton } from "@thumble/contracts";
import { counter } from "@thumble/contracts/receiver";
import {
  decodeControlMap,
  decodeTouchHapticFeedback,
  type ControlMap,
  type ControlRegion,
} from "@thumble/contracts/mobile-input";
import type { LosslessJson } from "@thumble/contracts/json";
import type {
  OwnedConfigurationDocument,
  OwnedElement,
} from "./owned-configuration.ts";
import { entries, field, uuid, uuidPairs } from "./owned-json.ts";
import { readOwnedOutput } from "./owned-bindings.ts";
import { synchronizeOwnedActiveBindings } from "./owned-selection.ts";

export type SafeControllerViewport = Readonly<{
  width: number;
  height: number;
}>;
export type SavedControllerPin = Readonly<{
  profileId: string;
  authorityRevision: string;
  sourceSha256: string;
}>;
export type SavedControllerProjection = Readonly<
  SavedControllerPin & { viewport: SafeControllerViewport; map: ControlMap }
>;
/** Established host SHA-256 over exact UTF-8 source; never imported or caller code. */
export type ControllerSourceDigest = (source: string) => string;
function fail(code: string): never {
  throw new Error(`saved_controller_${code}`);
}
function number(source: LosslessJson, key: string, fallback?: number): number {
  const value = field(source, key);
  if (!value && fallback !== undefined) return fallback;
  const token = value?.numberToken;
  if (token === undefined || !Number.isFinite(Number(token)))
    return fail("unsupported_geometry");
  return Number(token);
}
function rectangle(
  layout: LosslessJson,
  id: string,
  scale: number,
  viewport: SafeControllerViewport,
) {
  if (
    field(layout, "shape")?.stringValue !== "rectangle" ||
    number(layout, "rotationDegrees", 0) !== 0
  )
    fail("unsupported_transform");
  const centerX = number(layout, "centerX"),
    centerY = number(layout, "centerY"),
    widthScale = number(layout, "widthScale", 1),
    heightScale = number(layout, "heightScale", 1);
  if (
    centerX < 0 ||
    centerX > 1 ||
    centerY < 0 ||
    centerY > 1 ||
    widthScale < 0.001 ||
    widthScale > 12 ||
    heightScale < 0.001 ||
    heightScale > 12
  )
    fail("unsupported_geometry");
  const side = Math.min(
    86 * scale,
    Math.max(
      50 * scale,
      Math.min(viewport.width, viewport.height) * 0.24 * scale,
    ),
  );
  // Retained starter 9/10 use distinct base dimensions; custom UUIDs use a square.
  const width =
    side *
    widthScale *
    (id === "00000000-0000-0000-0000-000000000109"
      ? 1.48
      : id === "00000000-0000-0000-0000-00000000010a"
        ? 1.66
        : 1);
  const height =
    side *
    heightScale *
    (/^00000000-0000-0000-0000-00000000010[9a]$/.test(id) ? 0.72 : 1);
  if (width > viewport.width || height > viewport.height)
    fail("unsupported_geometry");
  const halfWidth = Math.max(width / 2, 1),
    halfHeight = Math.max(height / 2, 1);
  const x =
    Math.min(
      Math.max(centerX * viewport.width, halfWidth),
      viewport.width - halfWidth,
    ) -
    width / 2;
  const y =
    Math.min(
      Math.max(centerY * viewport.height, halfHeight),
      viewport.height - halfHeight,
    ) -
    height / 2;
  return {
    x: x / viewport.width,
    y: y / viewport.height,
    width: width / viewport.width,
    height: height / viewport.height,
  };
}
function action(binding: LosslessJson | undefined): GamepadButton {
  if (!binding) fail("unbound_control");
  const output = readOwnedOutput(binding);
  if (
    output.keyboard !== null ||
    output.gamepadButtons.length !== 1 ||
    !(GAMEPAD_BUTTONS as readonly string[]).includes(output.gamepadButtons[0]!)
  )
    fail("unsupported_binding");
  return output.gamepadButtons[0] as GamepadButton;
}
function haptic(layout: LosslessJson): Pick<ControlRegion, "hapticFeedback"> {
  const feedback = field(layout, "hapticFeedback"),
    style = field(layout, "hapticStyle");
  if (feedback) {
    const value: Record<string, unknown> = {};
    for (const key of [
      "style",
      "pattern",
      "intensity",
      "sharpness",
      "duration",
    ]) {
      const v = field(feedback, key);
      value[key] =
        key === "style" || key === "pattern"
          ? v?.stringValue
          : v?.numberToken === undefined
            ? undefined
            : Number(v.numberToken);
    }
    try {
      return { hapticFeedback: decodeTouchHapticFeedback(value) };
    } catch {
      return fail("unsupported_haptic");
    }
  }
  // Missing style uses the existing native accepted-touch default. Explicit none
  // is representable; other legacy styles need their retained normalization seam.
  if (style) {
    if (style.stringValue !== "none") fail("unsupported_haptic");
    return {
      hapticFeedback: decodeTouchHapticFeedback({
        style: "none",
        pattern: "single",
        intensity: 0,
        sharpness: 0,
        duration: 0.06,
      }),
    };
  }
  return {};
}
function layoutFor(
  element: OwnedElement,
  overrides: ReadonlyMap<string, LosslessJson>,
): LosslessJson {
  const starter = /^00000000-0000-0000-0000-00000000010[1-9a]$/.test(
    element.id,
  );
  const layout =
    (starter ? overrides.get(element.id) : undefined) ??
    element.source.get("/layout");
  if (layout?.kind !== "object") return fail("unsupported_geometry");
  return layout;
}
/** Pure projection of a pinned saved selection. No authority mutation, resource
 * materialization, native admission, transport, rendering or output activation. */
export function projectSavedController(
  snapshot: Readonly<{
    document: OwnedConfigurationDocument;
    authorityRevision: string;
  }>,
  pin: SavedControllerPin,
  admission: Readonly<{ generation: string; revision: string }>,
  viewport: SafeControllerViewport,
  digest: ControllerSourceDigest,
): SavedControllerProjection {
  const { document } = snapshot;
  if (
    counter(snapshot.authorityRevision) !== counter(pin.authorityRevision) ||
    uuid(pin.profileId) !== document.catalog.activeProfileID ||
    !/^[0-9a-f]{64}$/.test(pin.sourceSha256) ||
    digest(document.source.text()) !== pin.sourceSha256
  )
    fail("source_conflict");
  if (
    !Number.isFinite(viewport.width) ||
    !Number.isFinite(viewport.height) ||
    viewport.height < 240 ||
    viewport.width < viewport.height ||
    viewport.width > 4096 ||
    viewport.height > 4096
  )
    fail("unsupported_viewport");
  const profile = document.profile(pin.profileId),
    layout = profile.source.get("/customization")!;
  if (field(profile.source, "outputMode")?.stringValue !== "controller")
    fail("unsupported_output_mode");
  const scaleName = field(layout, "controlScale")?.stringValue ?? "standard";
  const scale =
    scaleName === "compact"
      ? 0.86
      : scaleName === "standard"
        ? 1
        : scaleName === "large"
          ? 1.14
          : fail("unsupported_geometry");
  const index = document.catalog.profiles.findIndex(
    (p) => p.id === document.catalog.activeProfileID,
  );
  const resolved = synchronizeOwnedActiveBindings(
    document.source,
    index,
    new Set(document.catalog.profiles.map((p) => p.id)),
  );
  const bindings = new Map(
    entries(resolved.get("/outputBindings")).map(([id, value]) => [
      uuid(id),
      value,
    ]),
  );
  const overrides = uuidPairs(field(layout, "buttonCustomizations"));
  const mirrors = layout.get("/customButtons");
  if (mirrors?.kind === "array")
    for (let i = 0; i < mirrors.length!; i++) {
      const id = uuid(mirrors.get(`/${i}/id`)?.stringValue);
      if (!/^00000000-0000-0000-0000-00000000010[1-9a]$/.test(id))
        fail("unsupported_layout_mirror");
    }
  const controls: ControlRegion[] = [];
  for (const element of profile.elements) {
    if (element.kind === "text" || element.kind === "decoration") continue;
    const geometry = layoutFor(element, overrides);
    const hidden = field(geometry, "isHidden");
    if (hidden && hidden.booleanValue === undefined)
      fail("unsupported_geometry");
    if (hidden?.booleanValue === true) continue;
    if (element.kind !== "button") fail("unsupported_control_kind");
    if (number(geometry, "zIndex", 0) !== 0) fail("unsupported_transform");
    if (element.partOutputs.length || element.joystickMapping)
      fail("unsupported_binding");
    controls.push({
      id: element.id,
      action: action(bindings.get(element.id)),
      ...rectangle(geometry, element.id, scale, viewport),
      ...haptic(geometry),
    });
    if (controls.length > 64) fail("control_limit");
    const latest = controls[controls.length - 1]!;
    for (const other of controls.slice(0, -1))
      if (
        latest.x < other.x + other.width &&
        other.x < latest.x + latest.width &&
        latest.y < other.y + other.height &&
        other.y < latest.y + latest.height
      )
        fail("overlapping_controls");
  }
  if (!controls.length) fail("no_controls");
  let map: ControlMap;
  try {
    map = decodeControlMap({
      version: 1,
      generation: admission.generation,
      revision: admission.revision,
      controls,
    });
  } catch {
    return fail("invalid_map_or_admission");
  }
  return Object.freeze({
    profileId: document.catalog.activeProfileID,
    authorityRevision: pin.authorityRevision,
    sourceSha256: pin.sourceSha256,
    viewport: Object.freeze({ ...viewport }),
    map,
  });
}
