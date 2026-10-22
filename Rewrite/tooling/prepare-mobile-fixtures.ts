import { mkdirSync, copyFileSync } from "node:fs";
import { resolve } from "node:path";
const root = resolve(import.meta.dir, "..");
const target = resolve(
  root,
  "native/mobile-input/ios/Tests/MobileInputTests/Fixtures",
);
mkdirSync(target, { recursive: true });
for (const [source, name] of [
  [
    "packages/fixtures/native-input-control-v4.json",
    "native-input-control-v4.json",
  ],
  [
    "packages/fixtures/authenticated-control-v3.json",
    "authenticated-control-v3.json",
  ],
  ["../Host/fixtures/gamepad/v2.json", "gamepad-v2.json"],
  ["packages/fixtures/mobile-input-v1.json", "mobile-input-v1.json"],
  ["packages/fixtures/input-packet-v1.json", "input-packet-v1.json"],
  ["packages/fixtures/phone-credential-v1.json", "phone-credential-v1.json"],
  [
    "packages/fixtures/enrollment-control-v2.json",
    "enrollment-control-v2.json",
  ],
]) {
  copyFileSync(resolve(root, source!), resolve(target, name!));
}
