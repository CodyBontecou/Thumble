import type { LosslessJson } from "@thumble/contracts/json";
import { readOwnedOutput, type OwnedOutput } from "./owned-bindings.ts";
import {
  entries,
  field,
  invalidOwned,
  object,
  only,
  rows,
  unsigned,
  uuid,
  uuidPairs,
  visit,
} from "./owned-json.ts";
import {
  hasResourceData,
  OwnedResourceTable,
  type ResourceDigest,
} from "./owned-resources.ts";
const KINDS = [
  "button",
  "joystick",
  "trigger",
  "trackpad",
  "text",
  "decoration",
] as const;
const PARTS = [
  "primary",
  "joystick_up",
  "joystick_down",
  "joystick_left",
  "joystick_right",
  "trigger_digital",
] as const;
const ACTIONS = ["base", "left-trigger", "right-trigger", "both-triggers"];
const SCHEMES = ["light", "dark"];
const ACCENTS = ["monochrome", "blue", "green", "purple", "pink", "amber"];
const SURFACE = [
  "backgroundLightColor",
  "backgroundDarkColor",
  "backgroundFillStyle",
  "backgroundLightFillStyle",
  "backgroundDarkFillStyle",
  "accentStyle",
  "showsButtonLabels",
];
const OWNERS = [
  "artworkLayers",
  "controls",
  "topBar",
  "controlBar",
  "styleLibrary",
  "assetLibrary",
];
const CONTROL = [
  "shape",
  "accentStyle",
  "fillColor",
  "lightFillColor",
  "darkFillColor",
  "fillStyle",
  "lightFillStyle",
  "darkFillStyle",
  "joystickKnobColor",
  "lightJoystickKnobColor",
  "darkJoystickKnobColor",
  "joystickVisualStyle",
  "styleID",
  "visualStyle",
  "icon",
  "hapticStyle",
  "hapticFeedback",
  "cornerRadius",
  "cornerRadii",
  "shadowStrength",
  "showsIntegratedLabel",
];
const BARS = [
  "status",
  "profile_menu",
  "launch_target",
  "spacer",
  "edit_layout",
  "settings",
  "home",
  "connection",
];
const DEVICES = [
  "iphone-17-pro",
  "iphone-17",
  "iphone-16-pro",
  "iphone-17-pro-max",
  "iphone-16-pro-max",
  "iphone-air",
  "iphone-16",
  "iphone-15-pro",
  "iphone-15",
  "iphone-14-pro",
  "iphone-16-plus",
  "iphone-15-pro-max",
  "iphone-15-plus",
  "iphone-14-pro-max",
  "iphone-14-plus",
  "iphone-13-pro-max",
  "iphone-12-pro-max",
  "iphone-17e",
  "iphone-16e",
  "iphone-14",
  "iphone-13-pro",
  "iphone-13",
  "iphone-12-pro",
  "iphone-12",
  "iphone-se-3",
  "iphone-se-2",
  "iphone-13-mini",
  "iphone-12-mini",
  "iphone-11-pro",
  "iphone-xs",
  "iphone-11-pro-max",
  "iphone-11",
  "iphone-xr",
  "iphone-xs-max",
];
export type OwnedControlKind = (typeof KINDS)[number];
export type OwnedInputPart = (typeof PARTS)[number];
export type OwnedPresentation = Readonly<{
  schemaVersion: 1;
  actionID: string | null;
  purposeID: string | null;
  groupIDs: readonly string[];
  legend: string | null;
  caption: string | null;
  accessibilityName: string | null;
}>;
type OwnedInputFields = Readonly<{
  output: OwnedOutput | null;
  defaultOutput: OwnedOutput | null;
  partOutputs: readonly Readonly<{
    part: OwnedInputPart;
    output: OwnedOutput;
  }>[];
  joystickMapping: Readonly<{
    up: OwnedOutput;
    down: OwnedOutput;
    left: OwnedOutput;
    right: OwnedOutput;
  }> | null;
  presentation: OwnedPresentation | null;
}>;
export type OwnedElement = Readonly<{
  id: string;
  kind: OwnedControlKind;
  source: LosslessJson;
}> &
  OwnedInputFields;
export type OwnedProfile = Readonly<{
  source: LosslessJson;
  elements: readonly OwnedElement[];
  appearanceStates: readonly string[];
  resources: OwnedResourceTable | undefined;
}>;
function kind(value: LosslessJson, property = "kind"): OwnedControlKind {
  const raw = field(value, property),
    result = raw ? raw.stringValue : "button";
  if (!result || !(KINDS as readonly string[]).includes(result)) invalidOwned();
  return result as OwnedControlKind;
}
function starter(id: string): boolean {
  return /^00000000-0000-0000-0000-00000000010[1-9a]$/.test(id);
}
function tag(value: LosslessJson): void {
  if (!value.stringValue || !/^[a-z0-9._-]{1,64}$/.test(value.stringValue))
    invalidOwned();
}
function presentation(value: LosslessJson): void {
  only(value, [
    "schemaVersion",
    "actionID",
    "purposeID",
    "groupIDs",
    "legend",
    "caption",
    "accessibilityName",
  ]);
  if (
    value.get("/schemaVersion") &&
    value.get("/schemaVersion")!.integerValue !== 1
  )
    invalidOwned();
  for (const key of ["actionID", "purposeID"]) {
    const v = field(value, key);
    if (v) tag(v);
  }
  const groups = field(value, "groupIDs");
  if (groups) {
    const values = rows(groups, 16);
    values.forEach(tag);
    if (new Set(values.map((v) => v.stringValue)).size !== values.length)
      invalidOwned();
  }
  // Rust's Vec default accepts omission, but not an explicit null.
  else if (value.get("/groupIDs")) invalidOwned();
  for (const [key, maximum] of [
    ["legend", 64],
    ["caption", 128],
    ["accessibilityName", 128],
  ] as const) {
    const v = field(value, key);
    if (!v) continue;
    const text = v.stringValue;
    if (
      text === undefined ||
      [...text].length > maximum ||
      /[\u0000-\u001f\u007f-\u009f]/.test(text) ||
      (key === "accessibilityName" && !text.trim())
    )
      invalidOwned();
  }
}
function inputFields(value: LosslessJson): OwnedInputFields {
  for (const key of [
    "button",
    "mappedButton",
    "builtInButton",
    "legacySlot",
    "inputID",
    "defaultControlID",
  ])
    if (value.keys.includes(key)) invalidOwned();
  const rawPresentation = field(value, "presentation");
  let text: OwnedPresentation | null = null;
  if (rawPresentation) {
    presentation(rawPresentation);
    const groups = field(rawPresentation, "groupIDs");
    text = Object.freeze({
      schemaVersion: 1,
      actionID: field(rawPresentation, "actionID")?.stringValue ?? null,
      purposeID: field(rawPresentation, "purposeID")?.stringValue ?? null,
      groupIDs: Object.freeze(
        groups ? rows(groups, 16).map((v) => v.stringValue!) : [],
      ),
      legend: field(rawPresentation, "legend")?.stringValue ?? null,
      caption: field(rawPresentation, "caption")?.stringValue ?? null,
      accessibilityName:
        field(rawPresentation, "accessibilityName")?.stringValue ?? null,
    });
  }
  const output = field(value, "output"),
    defaultOutput = field(value, "defaultOutput");
  const mapping = field(value, "joystickMapping");
  let joystickMapping: OwnedInputFields["joystickMapping"] = null;
  if (mapping) {
    only(mapping, ["up", "down", "left", "right"]);
    joystickMapping = Object.freeze({
      up: readOwnedOutput(object(mapping.get("/up"))),
      down: readOwnedOutput(object(mapping.get("/down"))),
      left: readOwnedOutput(object(mapping.get("/left"))),
      right: readOwnedOutput(object(mapping.get("/right"))),
    });
  }
  const parts = field(value, "partOutputs");
  const partOutputs: Array<
    Readonly<{ part: OwnedInputPart; output: OwnedOutput }>
  > = [];
  if (parts) {
    let pairs: readonly (readonly [string | undefined, LosslessJson])[];
    if (parts.kind === "object") pairs = entries(parts, 6);
    else {
      const values = rows(parts, 12);
      if (values.length % 2) invalidOwned();
      pairs = Array.from(
        { length: values.length / 2 },
        (_, i) => [values[i * 2]!.stringValue, values[i * 2 + 1]!] as const,
      );
    }
    const seen = new Set<string>();
    for (const [key, partOutput] of pairs) {
      if (!key || !(PARTS as readonly string[]).includes(key) || seen.has(key))
        invalidOwned();
      seen.add(key);
      partOutputs.push(
        Object.freeze({
          part: key as OwnedInputPart,
          output: readOwnedOutput(partOutput),
        }),
      );
    }
  }
  return Object.freeze({
    output: output ? readOwnedOutput(output) : null,
    defaultOutput: defaultOutput ? readOwnedOutput(defaultOutput) : null,
    partOutputs: Object.freeze(partOutputs),
    joystickMapping,
    presentation: text,
  });
}

const SETTINGS = {
  joystickOutputSettings: {
    analogTarget: "none",
    sendsDigitalDirections: true,
    deadZone: 0.12,
    sensitivity: 1,
    invertX: false,
    invertY: false,
    snapToCardinal: false,
  },
  triggerSettings: {
    target: "right",
    orientation: "vertical",
    deadZone: 0.03,
    sensitivity: 1,
    sendsDigitalButton: false,
    digitalThreshold: 0.5,
  },
  trackpadSettings: {
    sensitivity: 1.2,
    scrollSensitivity: 0.85,
    naturalScrolling: true,
    tapToClick: true,
    twoFingerScroll: true,
  },
} as const;
function settings(
  key: keyof typeof SETTINGS,
  value: LosslessJson | undefined,
): string {
  const result: Record<string, string | number | boolean> = {
    ...SETTINGS[key],
  };
  if (value) {
    object(value);
    for (const [name, defaultValue] of Object.entries(result)) {
      const v = value.get("/" + name);
      if (typeof defaultValue === "boolean") {
        if (v?.booleanValue === undefined) invalidOwned();
        result[name] = v.booleanValue;
      } else if (typeof defaultValue === "number") {
        if (v?.numberToken === undefined) invalidOwned();
        const number = Number(v.numberToken);
        if (!Number.isFinite(number)) invalidOwned();
        const [lower, upper] =
          name === "deadZone"
            ? [0, 0.85]
            : name === "digitalThreshold"
              ? [0.01, 1]
              : name === "scrollSensitivity"
                ? [0.1, 4]
                : key === "trackpadSettings"
                  ? [0.2, 4]
                  : [0.2, 3];
        result[name] = Math.max(lower!, Math.min(upper!, number));
      } else {
        const choices =
          name === "analogTarget"
            ? ["none", "left_stick", "right_stick", "mouse_look"]
            : name === "target"
              ? ["left", "right"]
              : ["vertical", "horizontal"];
        const text = v?.stringValue;
        if (!text || !choices.includes(text)) invalidOwned();
        result[name] = text;
      }
    }
    if (key === "trackpadSettings") {
      const button = field(value, "clickButton");
      if (button) {
        const text = button.stringValue;
        if (!text || !["left", "right", "middle"].includes(text))
          invalidOwned();
        result.clickButton = text;
      }
      const moves = field(value, "movesCursor");
      if (moves) {
        if (moves.booleanValue === undefined) invalidOwned();
        if (!moves.booleanValue) result.movesCursor = false;
      }
    }
  }
  if (key === "joystickOutputSettings" && result.analogTarget === "none")
    result.sendsDigitalDirections = true;
  if (key === "joystickOutputSettings" && result.analogTarget === "mouse_look")
    result.sendsDigitalDirections = false;
  return JSON.stringify(result);
}
function mirror(m: LosslessJson, declared: OwnedElement): void {
  const mapping = field(m, "joystickMapping");
  if (mapping) {
    const owned = field(declared.source, "joystickMapping");
    if (declared.kind !== "joystick" || !owned) invalidOwned();
    for (const direction of ["up", "down", "left", "right"])
      if (
        JSON.stringify(
          readOwnedOutput(object(mapping.get("/" + direction))),
        ) !==
        JSON.stringify(readOwnedOutput(object(owned.get("/" + direction))))
      )
        invalidOwned();
  }
  for (const [key, controlKind] of [
    ["joystickOutputSettings", "joystick"],
    ["triggerSettings", "trigger"],
    ["trackpadSettings", "trackpad"],
  ] as const) {
    const value = field(m, key);
    if (
      value &&
      declared.kind === controlKind &&
      settings(key, value) !== settings(key, field(declared.source, key))
    )
      invalidOwned();
  }
}
function designIdentity(value: LosslessJson): string {
  let kind_: string | undefined, raw: string | undefined;
  if (value.kind === "string") {
    const text = value.stringValue!,
      at = text.indexOf(".");
    if (at >= 0) {
      kind_ = text.slice(0, at);
      raw = text.slice(at + 1);
    } else {
      kind_ = text === "top_bar_activation" ? "system" : "builtin";
      raw = text;
    }
  } else {
    kind_ = value.get("/kind")?.stringValue;
    raw =
      kind_ === "builtin"
        ? value.get("/button")?.stringValue
        : kind_ === "custom"
          ? value.get("/id")?.stringValue
          : kind_ === "system"
            ? (value.get("/system") ?? value.get("/id"))?.stringValue
            : undefined;
  }
  if (kind_ === "system" && raw === "top_bar_activation")
    return "system.top_bar_activation";
  if (kind_ !== "builtin" && kind_ !== "custom") invalidOwned();
  return kind_ + "." + uuid(raw);
}
function design(
  value: LosslessJson | undefined,
  elements: readonly OwnedElement[],
): void {
  if (!value) return;
  object(value);
  const available = new Set([
    "system.top_bar_activation",
    ...elements.map(
      (e) =>
        (e.kind === "button" && starter(e.id) ? "builtin." : "custom.") + e.id,
    ),
  ]);
  function controls(value: LosslessJson | undefined): void {
    const seen = new Set<string>();
    for (const item of rows(value, 129)) {
      const id = designIdentity(item);
      if (!available.has(id) || seen.has(id)) invalidOwned();
      seen.add(id);
    }
  }
  const order = value.get("/layerOrder");
  if (order) controls(order);
  const groups = value.get("/groups");
  if (groups) {
    const seen = new Set<string>();
    for (const group of rows(groups, 4096)) {
      const id = uuid(group.get("/id")?.stringValue);
      if (seen.has(id)) invalidOwned();
      seen.add(id);
      controls(group.get("/children"));
    }
  }
}
function canvas(value: LosslessJson | undefined): void {
  const id = value?.stringValue;
  if (!id || id.length > 256) invalidOwned();
  if (DEVICES.some((device) => id === device + "-landscape")) return;
  const custom = /^custom-([1-9][0-9]*)x([1-9][0-9]*)-landscape$/.exec(id);
  if (!custom) invalidOwned();
  const width = Number(custom[1]),
    height = Number(custom[2]);
  if (
    !Number.isSafeInteger(width) ||
    width < 240 ||
    height < width ||
    height > 1800
  )
    invalidOwned();
}
function keyed(value: LosslessJson | undefined): readonly LosslessJson[] {
  const values = rows(value, 4096),
    seen = new Set<string>();
  for (const item of values) {
    const id = item.get("/id")?.stringValue;
    if (!id || seen.has(id)) invalidOwned();
    seen.add(id);
  }
  return values;
}
function paint(
  roots: readonly LosslessJson[],
  assets: readonly LosslessJson[],
  table: OwnedResourceTable | undefined,
): void {
  const available = new Set<string>();
  for (const asset of assets)
    if (hasResourceData(field(asset, "data"), table))
      available.add(asset.get("/id")!.stringValue!);
  for (const root of roots)
    visit(root, (node) => {
      if (node.kind !== "object") return;
      if (node.keys.includes("resourceSHA256")) {
        if (!table) invalidOwned();
        table.referenceSize(node);
        return;
      }
      if (node.get("/kind")?.stringValue === "image") {
        const image = node.get("/image"),
          id = image?.get("/assetID")?.stringValue;
        if (
          id &&
          !available.has(id) &&
          !hasResourceData(image ? field(image, "data") : undefined, table)
        )
          invalidOwned();
      }
      if (node.get("/source")?.stringValue === "asset") {
        const id = node.get("/value")?.stringValue;
        if (id === undefined || !available.has(id)) invalidOwned();
      }
    });
}
function canonicalPaint(
  layout: LosslessJson,
  elements: readonly OwnedElement[],
  table: OwnedResourceTable | undefined,
): void {
  const roots: LosslessJson[] = [];
  const accent = field(layout, "accentStyle"),
    labels = field(layout, "showsButtonLabels");
  if (accent && (!accent.stringValue || !ACCENTS.includes(accent.stringValue)))
    invalidOwned();
  if (labels && labels.booleanValue === undefined) invalidOwned();
  for (const key of SURFACE) {
    const v = field(layout, key);
    if (v) roots.push(v);
  }
  const artwork = field(layout, "artworkLayers");
  if (artwork) {
    const visible = rows(artwork).filter(
        (v) => v.get("/isHidden")?.booleanValue !== true,
      ),
      seen = new Set<string>();
    for (const item of visible) {
      const id = item.get("/id")?.stringValue;
      if (!id || seen.has(id)) invalidOwned();
      seen.add(id);
      roots.push(item);
    }
  }
  const style = field(layout, "styleLibrary");
  if (style) roots.push(...keyed(style.get("/styles")));
  const library = field(layout, "assetLibrary"),
    assets = library ? keyed(library.get("/assets")) : [];
  roots.push(...assets);
  const overrides = uuidPairs(field(layout, "buttonCustomizations"));
  for (const element of elements) {
    const source =
      element.kind === "button" && starter(element.id)
        ? (overrides.get(element.id) ?? element.source.get("/layout"))
        : element.source.get("/layout");
    if (source)
      for (const key of CONTROL) {
        const v = field(source, key);
        if (v) roots.push(v);
      }
  }
  const top = field(layout, "topBarActivationRegion");
  if (top)
    for (const key of CONTROL) {
      const v = field(top, key);
      if (v) roots.push(v);
    }
  const bars = layout.get("/controlBarItemCustomizations");
  if (bars?.kind === "array")
    for (const bar of rows(bars)) {
      const id = bar.get("/item")?.stringValue;
      if (!id || !BARS.includes(id)) invalidOwned();
      const value = bar.get("/appearance");
      if (value)
        for (const key of CONTROL) {
          const v = field(value, key);
          if (v) roots.push(v);
        }
    }
  paint(roots, assets, table);
}
function appearanceBank(
  bank: LosslessJson | undefined,
  table: OwnedResourceTable | undefined,
): readonly string[] {
  if (!bank) return Object.freeze([]);
  only(bank, ["schemaVersion", "variants"]);
  if (bank.get("/schemaVersion")?.integerValue !== 1) invalidOwned();
  const variants = rows(bank.get("/variants"), 8);
  if (variants.length !== 8) invalidOwned();
  const states = new Set<string>();
  let identities: string | undefined;
  for (const variant of variants) {
    const scheme = variant.get("/colorScheme")?.stringValue,
      action = variant.get("/actionSet")?.stringValue;
    if (
      !scheme ||
      !SCHEMES.includes(scheme) ||
      !action ||
      !ACTIONS.includes(action) ||
      states.has(scheme + "/" + action)
    )
      invalidOwned();
    states.add(scheme + "/" + action);
    const value = object(variant.get("/appearance"));
    only(value, [...SURFACE, ...OWNERS]);
    if (
      value.get("/showsButtonLabels")?.booleanValue === undefined ||
      !ACCENTS.includes(value.get("/accentStyle")?.stringValue ?? "")
    )
      invalidOwned();
    const controls = entries(value.get("/controls"), 2048);
    for (const [id, control] of controls) {
      if (uuid(id) !== id) invalidOwned();
      only(control, CONTROL);
    }
    const ids = JSON.stringify(controls.map(([id]) => id).sort());
    if (identities !== undefined && identities !== ids) invalidOwned();
    identities = ids;
    const bars = entries(value.get("/controlBar"), BARS.length);
    for (const [id, control] of bars) {
      if (!BARS.includes(id)) invalidOwned();
      only(control, CONTROL);
    }
    only(object(value.get("/topBar")), CONTROL);
    keyed(value.get("/artworkLayers"));
    keyed(value.get("/styleLibrary/styles"));
    const assets = keyed(value.get("/assetLibrary/assets"));
    paint([value], assets, table);
  }
  return Object.freeze([...states].sort());
}
/** Structural owned-v5/interchange admission, preserving exact opaque source.
 * Image decoding, platform output support and activation require separate gates. */
export function readOwnedProfile(
  source: LosslessJson,
  digest: ResourceDigest,
): OwnedProfile {
  const layout = object(source.get("/customization"));
  canvas(layout.get("/deviceCanvas/frameID"));
  const mode = field(source, "outputMode");
  if (
    mode &&
    !["keyboard", "controller", "custom"].includes(mode.stringValue ?? "")
  )
    invalidOwned();
  const elements: OwnedElement[] = [],
    byId = new Map<string, OwnedElement>();
  for (const value of rows(layout.get("/elements"), 128)) {
    object(value);
    const id = uuid(value.get("/id")?.stringValue),
      type = kind(value);
    if (byId.has(id)) invalidOwned();
    const input = inputFields(value);
    const element = Object.freeze({ id, kind: type, source: value, ...input });
    elements.push(element);
    byId.set(id, element);
  }
  for (const [type, maximum] of [
    ["joystick", 2],
    ["trigger", 2],
    ["trackpad", 3],
  ] as const)
    if (elements.filter((e) => e.kind === type).length > maximum)
      invalidOwned();
  for (const key of ["buttonCustomizations", "labelOverrides"])
    for (const id of uuidPairs(field(layout, key)).keys())
      if (!byId.has(id)) invalidOwned();
  const mirrors = layout.get("/customButtons");
  if (mirrors) {
    const seen = new Set<string>();
    for (const value of rows(mirrors, 128)) {
      object(value);
      const id = uuid(value.get("/id")?.stringValue),
        declared = byId.get(id);
      if (
        seen.has(id) ||
        !declared ||
        kind(value, "controlKind") !== declared.kind
      )
        invalidOwned();
      seen.add(id);
      inputFields(value);
      mirror(value, declared);
    }
  }
  design(field(layout, "designMetadata"), elements);
  const resources = OwnedResourceTable.read(source, digest);
  const states = appearanceBank(field(source, "appearanceBank"), resources);
  canonicalPaint(layout, elements, resources);
  return Object.freeze({
    source,
    elements: Object.freeze(elements),
    appearanceStates: states,
    resources,
  });
}
