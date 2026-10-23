import { expect, test } from "bun:test";
import {
  mkdtempSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
  rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";

test("clean mobile fixture preparation installs exact shared saved-map vectors in both SDK bundles", () => {
  const parent = mkdtempSync(join(tmpdir(), "thumble-fixture-preparation-"));
  const root = join(parent, "Rewrite");
  try {
    const script = readFileSync(
      resolve(import.meta.dir, "../tooling/prepare-mobile-fixtures.ts"),
      "utf8",
    );
    mkdirSync(join(root, "tooling"), { recursive: true });
    writeFileSync(join(root, "tooling/prepare-mobile-fixtures.ts"), script);
    const sources = [
      ...script.matchAll(
        /"(packages\/fixtures\/[^"\n]+\.json|\.\.\/Host\/fixtures\/[^"\n]+\.json)"/g,
      ),
    ].map((m) => m[1]!);
    for (const name of [
      "physical-input-control-v9.json",
      "saved-controller-control-v8.json",
      "saved-controller-presentation-control-v10.json",
      "saved-controller-presentation-control-v11.json",
      "saved-controller-v1.json",
      "saved-controller-analog-control-v8.json",
      "saved-controller-analog-v1.json",
    ])
      sources.push(`packages/fixtures/${name}`);
    for (const source of sources) {
      const path = resolve(root, source);
      mkdirSync(dirname(path), { recursive: true });
      writeFileSync(
        path,
        JSON.stringify({ syntheticCopyWitness: source }) + "\n",
      );
    }
    const result = Bun.spawnSync(
      [process.execPath, join(root, "tooling/prepare-mobile-fixtures.ts")],
      { stdout: "pipe", stderr: "pipe" },
    );
    expect(result.exitCode).toBe(0);
    for (const name of [
      "physical-input-control-v9.json",
      "saved-controller-control-v8.json",
      "saved-controller-presentation-control-v10.json",
      "saved-controller-presentation-control-v11.json",
      "saved-controller-v1.json",
      "saved-controller-analog-control-v8.json",
      "saved-controller-analog-v1.json",
    ]) {
      const expected = readFileSync(
        join(root, "packages/fixtures", name),
        "utf8",
      );
      for (const target of [
        "native/mobile-input/ios/Tests/MobileInputTests/Fixtures",
        "native/mobile-input/android/src/test/resources/Fixtures",
      ])
        expect(readFileSync(join(root, target, name), "utf8")).toBe(expected);
    }
  } finally {
    rmSync(parent, { recursive: true, force: true });
  }
});
