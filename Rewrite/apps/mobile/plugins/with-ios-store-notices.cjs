const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const BUNDLE = "ThumbleThirdPartyNotices.txt";
const INVENTORY = "ThumbleThirdPartyNoticeInventory.json";
const digest = (bytes) =>
  crypto.createHash("sha256").update(bytes).digest("hex");
function readFile(file, cap) {
  const stat = fs.lstatSync(file);
  if (
    !stat.isFile() ||
    stat.isSymbolicLink() ||
    stat.size < 1 ||
    stat.size > cap
  )
    throw new Error("ios_notice_file_invalid");
  return fs.readFileSync(file);
}
function verifySelectedNotices(projectRoot) {
  const assets = path.join(projectRoot, "assets", "legal");
  const inventoryBytes = readFile(path.join(assets, INVENTORY), 256 * 1024);
  const inventory = JSON.parse(inventoryBytes.toString("utf8"));
  const bundle = readFile(path.join(assets, BUNDLE), 1024 * 1024);
  const lock = readFile(
    path.resolve(projectRoot, "..", "..", "bun.lock"),
    16 * 1024 * 1024,
  );
  if (
    inventory.schemaVersion !== 1 ||
    inventory.platform !== "ios" ||
    inventory.completeCoverageVerified !== false ||
    inventory.bundleFile !== BUNDLE ||
    inventory.lockFile !== "bun.lock" ||
    inventory.bundleSHA256 !== digest(bundle) ||
    inventory.bundleByteCount !== bundle.length ||
    inventory.lockSHA256 !== digest(lock) ||
    !Array.isArray(inventory.selectedTexts) ||
    inventory.selectedTexts.length < 1 ||
    inventory.selectedTexts.length > 256 ||
    !Array.isArray(inventory.unresolved) ||
    inventory.unresolved.length < 1 ||
    inventory.unresolved.length > 256
  )
    throw new Error("ios_notice_inventory_mismatch");
  let end = 0;
  const seen = new Set();
  for (const text of inventory.selectedTexts) {
    if (
      !text ||
      !/^[a-f0-9]{64}$/.test(text.sha256) ||
      seen.has(text.sha256) ||
      !Number.isSafeInteger(text.offset) ||
      text.offset < end ||
      !Number.isSafeInteger(text.byteCount) ||
      text.byteCount < 1 ||
      text.byteCount > 256 * 1024 ||
      text.offset + text.byteCount > bundle.length ||
      !Array.isArray(text.origins) ||
      text.origins.length < 1 ||
      digest(bundle.subarray(text.offset, text.offset + text.byteCount)) !==
        text.sha256
    )
      throw new Error("ios_notice_selected_text_mismatch");
    seen.add(text.sha256);
    end = text.offset + text.byteCount;
  }
  return { bundle, inventoryBytes, inventory };
}
function registerSelectedNotices(project, request) {
  const { projectRoot, platformProjectRoot, projectName } = request;
  if (!/^[A-Za-z][A-Za-z0-9_-]{0,63}$/.test(projectName))
    throw new Error("ios_notice_project_invalid");
  // Validate all inputs before changing generated files or the Xcode project.
  const verified = verifySelectedNotices(projectRoot);
  const target = project.getFirstTarget();
  if (!target || !target.uuid) throw new Error("ios_notice_target_missing");
  const relativeDirectory = `${projectName}/StoreNotices`;
  const directory = path.join(platformProjectRoot, relativeDirectory);
  fs.mkdirSync(directory, { recursive: true });
  for (const [name, bytes] of [
    [BUNDLE, verified.bundle],
    [INVENTORY, verified.inventoryBytes],
  ]) {
    fs.writeFileSync(path.join(directory, name), bytes);
    const relative = `${relativeDirectory}/${name}`;
    if (!project.hasFile(relative)) {
      const added = project.addResourceFile(relative, { target: target.uuid });
      if (!added) throw new Error("ios_notice_resource_registration_failed");
    }
  }
  return project;
}
function withIosStoreNotices(config, options = {}) {
  const variant = options.variant ?? process.env.THUMBLE_MOBILE_VARIANT;
  if (variant !== "store") return config;
  if (config.ios?.bundleIdentifier !== "com.codybontecou.PocketPad.iOS")
    throw new Error("ios_notice_store_identity_required");
  const { withXcodeProject } = require("expo/config-plugins");
  return withXcodeProject(config, (mod) => {
    registerSelectedNotices(mod.modResults, mod.modRequest);
    return mod;
  });
}
module.exports = withIosStoreNotices;
module.exports.verifySelectedNotices = verifySelectedNotices;
module.exports.registerSelectedNotices = registerSelectedNotices;
