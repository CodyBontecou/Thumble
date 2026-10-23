const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const crypto = require("node:crypto");
const plugin = require("../apps/mobile/plugins/with-android-store-notices.cjs");
const sha = (v) => crypto.createHash("sha256").update(v).digest("hex");
function fixture(run) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "android-notices-test-"));
  try {
    const projectRoot = path.join(root, "apps/mobile");
    const assets = path.join(projectRoot, "assets/legal/android");
    fs.mkdirSync(assets, { recursive: true });
    fs.writeFileSync(path.join(root, "bun.lock"), "locked");
    const text = Buffer.from("Pinned actual license\n");
    const inventory = {
      schemaVersion: 1,
      platform: "android",
      packageName: "com.thumble.android",
      completeCoverageVerified: false,
      distributionAccepted: false,
      bundleFile: "ThumbleAndroidSelectedNotices.txt",
      bundleSHA256: sha(text),
      bundleByteCount: text.length,
      lockFile: "bun.lock",
      lockSHA256: sha("locked"),
      selectedTexts: [
        {
          sha256: sha(text),
          offset: 0,
          byteCount: text.length,
          origins: [{ kind: "synthetic-pinned-source" }],
        },
      ],
      unresolved: [{ reason: "native-vendored-unverified" }],
    };
    const save = () =>
      fs.writeFileSync(
        path.join(assets, "ThumbleAndroidNoticeInventory.json"),
        JSON.stringify(inventory),
      );
    fs.writeFileSync(path.join(assets, inventory.bundleFile), text);
    save();
    run({ root, projectRoot, assets, inventory, save, text });
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}
test("default dev leaves config unchanged and reads no resources", () => {
  const config = { android: { package: "example.rewrite" } };
  assert.equal(plugin(config, { variant: "development" }), config);
  assert.throws(
    () => plugin(config, { variant: "store" }),
    /store_identity_required/,
  );
});
test("verified incomplete subset copies exact two assets idempotently", () =>
  fixture(({ root, projectRoot, text }) => {
    const android = path.join(root, "generated-android");
    plugin.registerSelectedNotices(projectRoot, android, "com.thumble.android");
    plugin.registerSelectedNotices(projectRoot, android, "com.thumble.android");
    assert.deepEqual(
      fs.readFileSync(
        path.join(
          android,
          "app/src/main/assets/ThumbleAndroidSelectedNotices.txt",
        ),
      ),
      text,
    );
    const result = JSON.parse(
      fs.readFileSync(
        path.join(
          android,
          "app/src/main/assets/ThumbleAndroidNoticeInventory.json",
        ),
      ),
    );
    assert.equal(result.completeCoverageVerified, false);
    assert.equal(result.distributionAccepted, false);
  }));
test("wrong current store identity fails before creating generated outputs", () =>
  fixture(({ root, projectRoot }) => {
    const android = path.join(root, "android");
    assert.throws(
      () =>
        plugin.registerSelectedNotices(projectRoot, android, "example.rewrite"),
      /store_identity_required/,
    );
    assert.equal(fs.existsSync(android), false);
  }));
test("changed lock or bundle fails before copy", () =>
  fixture(({ root, projectRoot, assets }) => {
    fs.writeFileSync(path.join(root, "bun.lock"), "changed");
    assert.throws(
      () => plugin.verifySelectedNotices(projectRoot),
      /inventory_mismatch/,
    );
    fs.writeFileSync(path.join(root, "bun.lock"), "locked");
    fs.appendFileSync(
      path.join(assets, "ThumbleAndroidSelectedNotices.txt"),
      "changed",
    );
    assert.throws(
      () => plugin.verifySelectedNotices(projectRoot),
      /inventory_mismatch/,
    );
  }));
test("individual ranges, hashes and duplicate text IDs are checked", () =>
  fixture(({ projectRoot, inventory, save }) => {
    const original = { ...inventory.selectedTexts[0] };
    for (const patch of [
      { sha256: "0".repeat(64) },
      { offset: -1 },
      { byteCount: 999999 },
    ]) {
      inventory.selectedTexts = [{ ...original, ...patch }];
      save();
      assert.throws(
        () => plugin.verifySelectedNotices(projectRoot),
        /selected_text_mismatch/,
      );
    }
    inventory.selectedTexts = [original, original];
    save();
    assert.throws(
      () => plugin.verifySelectedNotices(projectRoot),
      /selected_text_mismatch/,
    );
  }));
test("symlinked input and output files are rejected without altering target", () =>
  fixture(({ root, projectRoot, assets, text }) => {
    const input = path.join(assets, "ThumbleAndroidSelectedNotices.txt");
    fs.renameSync(input, input + ".real");
    fs.symlinkSync(input + ".real", input);
    assert.throws(() => plugin.verifySelectedNotices(projectRoot));
    fs.unlinkSync(input);
    fs.renameSync(input + ".real", input);
    const android = path.join(root, "android");
    const out = path.join(android, "app/src/main/assets");
    fs.mkdirSync(out, { recursive: true });
    const unrelated = path.join(root, "unrelated");
    fs.writeFileSync(unrelated, "preserve");
    fs.symlinkSync(
      unrelated,
      path.join(out, "ThumbleAndroidSelectedNotices.txt"),
    );
    assert.throws(() =>
      plugin.registerSelectedNotices(
        projectRoot,
        android,
        "com.thumble.android",
      ),
    );
    assert.equal(fs.readFileSync(unrelated, "utf8"), "preserve");
    assert.deepEqual(fs.readFileSync(input), text);
  }));
test("coverage and distribution claims cannot silently become true", () =>
  fixture(({ projectRoot, inventory, save }) => {
    for (const key of ["completeCoverageVerified", "distributionAccepted"]) {
      inventory[key] = true;
      save();
      assert.throws(
        () => plugin.verifySelectedNotices(projectRoot),
        /inventory_mismatch/,
      );
      inventory[key] = false;
    }
    inventory.unresolved = [];
    save();
    assert.throws(
      () => plugin.verifySelectedNotices(projectRoot),
      /inventory_mismatch/,
    );
  }));

test("symlinked generated assets directory cannot redirect copying", () =>
  fixture(({ root, projectRoot }) => {
    const android = path.join(root, "android");
    const parent = path.join(android, "app/src/main");
    fs.mkdirSync(parent, { recursive: true });
    const outside = path.join(root, "outside");
    fs.mkdirSync(outside);
    fs.symlinkSync(outside, path.join(parent, "assets"));
    assert.throws(
      () =>
        plugin.registerSelectedNotices(
          projectRoot,
          android,
          "com.thumble.android",
        ),
      /output_invalid/,
    );
    assert.deepEqual(fs.readdirSync(outside), []);
  }));
