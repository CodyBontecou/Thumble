const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const crypto = require("node:crypto");
const test = require("node:test");
const plugin = require("../apps/mobile/plugins/with-ios-store-notices.cjs");
const sha = (b) => crypto.createHash("sha256").update(b).digest("hex");
function fixture(run) {
  const root = fs.mkdtempSync(
    path.join(os.tmpdir(), "thumble-ios-notices-test-"),
  );
  const projectRoot = path.join(root, "apps", "mobile");
  const assets = path.join(projectRoot, "assets", "legal");
  fs.mkdirSync(assets, { recursive: true });
  const text = Buffer.from("Verified upstream license text\n");
  const inventory = {
    schemaVersion: 1,
    platform: "ios",
    completeCoverageVerified: false,
    bundleFile: "ThumbleThirdPartyNotices.txt",
    bundleSHA256: sha(text),
    bundleByteCount: text.length,
    lockFile: "bun.lock",
    lockSHA256: sha("pinned-lock"),
    selectedTexts: [
      {
        sha256: sha(text),
        offset: 0,
        byteCount: text.length,
        origins: [{ component: "test" }],
      },
    ],
    unresolved: [{ kind: "coverage" }],
  };
  fs.writeFileSync(path.join(root, "bun.lock"), "pinned-lock");
  fs.writeFileSync(path.join(assets, inventory.bundleFile), text);
  const save = () =>
    fs.writeFileSync(
      path.join(assets, "ThumbleThirdPartyNoticeInventory.json"),
      JSON.stringify(inventory),
    );
  save();
  try {
    run({ root, projectRoot, assets, inventory, save });
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}
test("default development configuration is untouched without asset reads", () => {
  const config = { ios: { bundleIdentifier: "example.rewrite" } };
  assert.equal(plugin(config, { variant: "development" }), config);
  assert.throws(() => plugin(config, { variant: "store" }), /store_identity/);
});
test("selected texts validate and register two real resource bytes idempotently", () =>
  fixture(({ root, projectRoot, assets }) => {
    assert.equal(
      plugin.verifySelectedNotices(projectRoot).inventory
        .completeCoverageVerified,
      false,
    );
    const files = new Set();
    const calls = [];
    const project = {
      getFirstTarget: () => ({ uuid: "TARGET" }),
      hasFile: (p) => files.has(p),
      addResourceFile: (p, o) => {
        calls.push([p, o]);
        files.add(p);
        return {};
      },
    };
    const request = {
      projectRoot,
      platformProjectRoot: path.join(root, "ios"),
      projectName: "Thumble",
    };
    plugin.registerSelectedNotices(project, request);
    plugin.registerSelectedNotices(project, request);
    assert.equal(calls.length, 2);
    assert.equal(calls[0][1].target, "TARGET");
    assert.deepEqual(
      fs.readFileSync(path.join(root, "ios", calls[0][0])),
      fs.readFileSync(path.join(assets, "ThumbleThirdPartyNotices.txt")),
    );
  }));
test("changed lock and changed bundle fail before registration", () =>
  fixture(({ root, projectRoot, assets }) => {
    fs.writeFileSync(path.join(root, "bun.lock"), "different");
    assert.throws(
      () => plugin.verifySelectedNotices(projectRoot),
      /inventory_mismatch/,
    );
    fs.writeFileSync(path.join(root, "bun.lock"), "pinned-lock");
    fs.appendFileSync(
      path.join(assets, "ThumbleThirdPartyNotices.txt"),
      "changed",
    );
    assert.throws(
      () => plugin.verifySelectedNotices(projectRoot),
      /inventory_mismatch/,
    );
  }));
test("individual selected text hash is checked independently of bundle hash", () =>
  fixture(({ projectRoot, inventory, save }) => {
    inventory.selectedTexts[0].sha256 = "0".repeat(64);
    save();
    assert.throws(
      () => plugin.verifySelectedNotices(projectRoot),
      /selected_text_mismatch/,
    );
  }));
test("missing, symlinked and overlapping selected text fail closed", () =>
  fixture(({ projectRoot, assets, inventory, save }) => {
    inventory.selectedTexts.push({ ...inventory.selectedTexts[0] });
    save();
    assert.throws(
      () => plugin.verifySelectedNotices(projectRoot),
      /selected_text_mismatch/,
    );
    const file = path.join(assets, "ThumbleThirdPartyNotices.txt");
    fs.renameSync(file, file + ".real");
    fs.symlinkSync(file + ".real", file);
    assert.throws(
      () => plugin.verifySelectedNotices(projectRoot),
      /file_invalid/,
    );
    fs.unlinkSync(file);
    assert.throws(() => plugin.verifySelectedNotices(projectRoot));
  }));
test("incomplete coverage cannot silently become a legal-clearance claim", () =>
  fixture(({ projectRoot, inventory, save }) => {
    inventory.completeCoverageVerified = true;
    save();
    assert.throws(
      () => plugin.verifySelectedNotices(projectRoot),
      /inventory_mismatch/,
    );
    inventory.completeCoverageVerified = false;
    inventory.unresolved = [];
    save();
    assert.throws(
      () => plugin.verifySelectedNotices(projectRoot),
      /inventory_mismatch/,
    );
  }));
