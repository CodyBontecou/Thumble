import schema from "../packages/contracts/schema/gamepad-state-v1.schema.json";
import { resolve } from "node:path";

const root = resolve(import.meta.dir, "..");
const buttons = schema.properties.buttons.items.enum;
const fields = Object.keys(schema.properties).filter((key) => key !== "buttons");
const banner = "Generated from gamepad-state-v1.schema.json; do not edit. DTO only: validate before activation.";
const typescript = `// ${banner}\nexport const GAMEPAD_BUTTONS = ${JSON.stringify(buttons)} as const;\nexport type GamepadButton = (typeof GAMEPAD_BUTTONS)[number];\nexport interface GamepadState {\n  readonly buttons: readonly GamepadButton[];\n${fields.map((field) => `  readonly ${field}: number;`).join("\n")}\n}\n`;
const swift = `// ${banner}\nimport Foundation\n\npublic enum GamepadButtonV1: String, Codable, Sendable {\n${buttons.map((button) => `    case ${button}`).join("\n")}\n}\n\npublic struct GamepadStateV1: Codable, Sendable {\n    public let buttons: [GamepadButtonV1]\n${fields.map((field) => `    public let ${field}: Double`).join("\n")}\n}\n`;
const kotlin = `// ${banner}\npackage com.thumble.rewrite.contracts\n\nenum class GamepadButtonV1 {\n    ${buttons.join(", ")}\n}\n\ndata class GamepadStateV1(\n    val buttons: List<GamepadButtonV1>,\n${fields.map((field) => `    val ${field}: Double,`).join("\n")}\n)\n`;
const outputs = {
  "packages/contracts/src/gamepad.generated.ts": typescript,
  "packages/contracts/generated/swift/GamepadStateV1.swift": swift,
  "packages/contracts/generated/kotlin/GamepadStateV1.kt": kotlin,
};
for (const [path, content] of Object.entries(outputs)) {
  const file = Bun.file(resolve(root, path));
  if (Bun.argv.includes("--check")) {
    if (!(await file.exists()) || (await file.text()) !== content) throw new Error(`Stale generated contract: ${path}`);
  } else {
    await Bun.write(file, content);
  }
}
