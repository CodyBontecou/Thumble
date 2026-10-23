import { mkdirSync, readdirSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { createHash } from "node:crypto";
const root = resolve(import.meta.dir, "..");
const args = process.argv.slice(2);
if (args.length !== 0 && (args.length !== 2 || args[0] !== "--sdk"))
  throw new Error("invalid_arguments");
const sdk = args[1] ?? "iphonesimulator";
if (sdk !== "iphonesimulator" && sdk !== "iphoneos")
  throw new Error("invalid_ios_sdk");
const probe = Bun.spawnSync(["xcrun", "--sdk", sdk, "--show-sdk-path"], {
  stdout: "pipe",
  stderr: "inherit",
});
if (probe.exitCode !== 0) process.exit(probe.exitCode);
const sdkPath = probe.stdout.toString().trim();
const destination = resolve(root, `reports/mobile-ios-${sdk}`);
mkdirSync(destination, { recursive: true });
const target = `arm64-apple-ios17.0${sdk === "iphonesimulator" ? "-simulator" : ""}`;
const modules: Array<[string, string[]]> = [
  [
    "ThumbleContracts",
    [resolve(root, "packages/contracts/generated/swift/GamepadStateV1.swift")],
  ],
  ...["MobileInputCore", "MobileInputUIKit"].map((name): [string, string[]] => [
    name,
    readdirSync(resolve(root, `native/mobile-input/ios/Sources/${name}`))
      .filter((p) => p.endsWith(".swift"))
      .sort()
      .map((p) => resolve(root, `native/mobile-input/ios/Sources/${name}`, p)),
  ]),
];
for (const [name, sources] of modules) {
  const result = Bun.spawnSync(
    [
      "xcrun",
      "swiftc",
      "-swift-version",
      "6",
      "-parse-as-library",
      "-sdk",
      sdkPath,
      "-target",
      target,
      "-I",
      destination,
      "-emit-module",
      "-emit-library",
      "-static",
      "-module-name",
      name,
      "-emit-module-path",
      resolve(destination, `${name}.swiftmodule`),
      "-o",
      resolve(destination, `lib${name}.a`),
      ...sources,
    ],
    { stdout: "inherit", stderr: "inherit" },
  );
  if (result.exitCode !== 0) process.exit(result.exitCode);
}
const artifacts: Record<string, { bytes: number; sha256: string }> = {};
for (const name of readdirSync(destination).filter((p) => p.endsWith(".a"))) {
  const bytes = await Bun.file(resolve(destination, name)).bytes();
  artifacts[name] = {
    bytes: bytes.length,
    sha256: createHash("sha256").update(bytes).digest("hex"),
  };
}
writeFileSync(
  resolve(destination, "build.json"),
  JSON.stringify(
    {
      version: 1,
      scope:
        "M2 native module SDK compilation; production signing and physical delivery unverified",
      sdk: sdkPath,
      target,
      artifacts,
    },
    null,
    2,
  ) + "\n",
);
console.log(`Built all three native modules for ${target}`);
