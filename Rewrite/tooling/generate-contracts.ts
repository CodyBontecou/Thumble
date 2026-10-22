import schema from "../packages/contracts/schema/gamepad-state-v1.schema.json";
import { resolve } from "node:path";

const root = resolve(import.meta.dir, "..");
const buttons = schema.properties.buttons.items.enum;
const fields = Object.keys(schema.properties).filter(
  (key) => key !== "buttons",
);
const banner =
  "Generated from gamepad-state-v1.schema.json; do not edit. DTO only: validate before activation.";
const typescript = `// ${banner}\nexport const GAMEPAD_BUTTONS = ${JSON.stringify(buttons)} as const;\nexport type GamepadButton = (typeof GAMEPAD_BUTTONS)[number];\nexport interface GamepadState {\n  readonly buttons: readonly GamepadButton[];\n${fields.map((field) => `  readonly ${field}: number;`).join("\n")}\n}\n`;
const swift = `// ${banner}\nimport Foundation\n\npublic enum GamepadButtonV1: String, Codable, CaseIterable, Sendable {\n${buttons.map((button) => `    case ${button}`).join("\n")}\n}\n\npublic struct GamepadStateV1: Codable, Sendable {\n    public let buttons: [GamepadButtonV1]\n${fields.map((field) => `    public let ${field}: Double`).join("\n")}\n\n    public init(buttons: [GamepadButtonV1], ${fields.map((field) => `${field}: Double`).join(", ")}) {\n        self.buttons = buttons\n${fields.map((field) => `        self.${field} = ${field}`).join("\n")}\n    }\n}\n`;
const kotlin = `// ${banner}\npackage com.thumble.rewrite.contracts\n\nenum class GamepadButtonV1 {\n    ${buttons.join(", ")}\n}\n\ndata class GamepadStateV1(\n    val buttons: List<GamepadButtonV1>,\n${fields.map((field) => `    val ${field}: Double,`).join("\n")}\n)\n`;
const rust = `// ${banner}\nuse serde::{Deserialize, Serialize};\n\n#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]\n#[serde(rename_all = "camelCase")]\npub enum GamepadButton {\n${buttons.map((button) => `    ${button[0]!.toUpperCase() + button.slice(1)},`).join("\n")}\n}\n\n#[derive(Debug, Clone, Serialize, Deserialize)]\n#[serde(rename_all = "camelCase", deny_unknown_fields)]\npub struct GamepadState {\n    pub buttons: Vec<GamepadButton>,\n${fields.map((field) => `    pub ${field.replace(/[A-Z]/g, (letter) => "_" + letter.toLowerCase())}: f64,`).join("\n")}\n}\n`;
const mobileMapSchema = {
  $schema: "https://json-schema.org/draft/2020-12/schema",
  title: "Thumble native control map v1",
  type: "object",
  additionalProperties: false,
  required: ["version", "generation", "revision", "controls"],
  properties: {
    version: { const: 1 },
    generation: { type: "string", pattern: "^[1-9][0-9]{0,19}$" },
    revision: { type: "string", pattern: "^(0|[1-9][0-9]{0,19})$" },
    controls: {
      type: "array",
      minItems: 1,
      maxItems: 64,
      items: {
        type: "object",
        additionalProperties: false,
        required: ["id", "action", "x", "y", "width", "height"],
        properties: {
          id: { type: "string", pattern: "^[A-Za-z0-9-]{1,64}$" },
          action: {
            enum: [
              ...buttons,
              "leftStick",
              "rightStick",
              "leftTrigger",
              "rightTrigger",
            ],
          },
          x: { type: "number", minimum: 0, maximum: 1 },
          y: { type: "number", minimum: 0, maximum: 1 },
          width: { type: "number", minimum: 0.001, maximum: 1 },
          height: { type: "number", minimum: 0.001, maximum: 1 },
        },
      },
    },
  },
  $comment:
    "Native and TypeScript validators additionally check u64 bounds, unique IDs, and rectangle sums within the unit viewport. Coordinates are normalized in the native surface bounds, independent of screen density.",
};
const rustPacketButtons = `// ${banner}\npub const PACKET_BUTTONS: [GamepadButton; 17] = [\n${buttons.map((button) => `    GamepadButton::${button[0]!.toUpperCase() + button.slice(1)},`).join("\n")}\n];\n`;
const packetOrder = [
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
if (JSON.stringify(buttons) !== JSON.stringify(packetOrder))
  throw new Error(
    "Input packet v1 semantics require an explicit version change",
  );
const outputs = {
  "packages/contracts/schema/mobile-input-v1.schema.json":
    JSON.stringify(mobileMapSchema, null, 2) + "\n",
  "packages/contracts/src/gamepad.generated.ts": typescript,
  "native/receiver/src/generated.rs": rust,
  "native/receiver/src/generated-packet.rs":
    "use crate::generated::GamepadButton;\n" + rustPacketButtons,
  "packages/contracts/generated/swift/GamepadStateV1.swift": swift,
  "packages/contracts/generated/kotlin/GamepadStateV1.kt": kotlin,
};
for (const [path, content] of Object.entries(outputs)) {
  const file = Bun.file(resolve(root, path));
  if (Bun.argv.includes("--check")) {
    if (!(await file.exists()) || (await file.text()) !== content)
      throw new Error(`Stale generated contract: ${path}`);
  } else {
    await Bun.write(file, content);
  }
}

await import("./generate-input-packet-fixtures.ts");

await import("./generate-controller-layout-fixture.ts");
