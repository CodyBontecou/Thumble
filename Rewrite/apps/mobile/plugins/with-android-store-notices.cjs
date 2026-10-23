const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const BUNDLE = "ThumbleAndroidSelectedNotices.txt";
const INVENTORY = "ThumbleAndroidNoticeInventory.json";
const STORE_PACKAGE = "com.thumble.android";
const digest = (value) =>
  crypto.createHash("sha256").update(value).digest("hex");
function readFile(file, cap) {
  const initial = fs.lstatSync(file);
  if (!initial.isFile() || initial.isSymbolicLink())
    throw new Error("android_notice_file_invalid");
  const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try {
    const stat = fs.fstatSync(fd);
    if (
      !stat.isFile() ||
      stat.ino !== initial.ino ||
      stat.dev !== initial.dev ||
      stat.size < 1 ||
      stat.size > cap
    )
      throw new Error("android_notice_file_invalid");
    const value = fs.readFileSync(fd);
    if (value.length !== stat.size)
      throw new Error("android_notice_file_invalid");
    return value;
  } finally {
    fs.closeSync(fd);
  }
}
function verifySelectedNotices(projectRoot) {
  const assets = path.join(projectRoot, "assets", "legal", "android");
  const inventoryBytes = readFile(path.join(assets, INVENTORY), 512 * 1024);
  const inventory = JSON.parse(inventoryBytes.toString("utf8"));
  const bundle = readFile(path.join(assets, BUNDLE), 1024 * 1024);
  const lock = readFile(
    path.resolve(projectRoot, "..", "..", "bun.lock"),
    16 * 1024 * 1024,
  );
  if (
    inventory.schemaVersion !== 1 ||
    inventory.platform !== "android" ||
    inventory.packageName !== STORE_PACKAGE ||
    inventory.completeCoverageVerified !== false ||
    inventory.distributionAccepted !== false ||
    inventory.bundleFile !== BUNDLE ||
    inventory.bundleSHA256 !== digest(bundle) ||
    inventory.bundleByteCount !== bundle.length ||
    inventory.lockFile !== "bun.lock" ||
    inventory.lockSHA256 !== digest(lock) ||
    !Array.isArray(inventory.selectedTexts) ||
    inventory.selectedTexts.length < 1 ||
    inventory.selectedTexts.length > 256 ||
    !Array.isArray(inventory.unresolved) ||
    inventory.unresolved.length < 1 ||
    inventory.unresolved.length > 2048
  )
    throw new Error("android_notice_inventory_mismatch");
  let end = 0;
  const seen = new Set();
  for (const item of inventory.selectedTexts) {
    if (
      !item ||
      !/^[a-f0-9]{64}$/.test(item.sha256) ||
      seen.has(item.sha256) ||
      !Number.isSafeInteger(item.offset) ||
      item.offset < end ||
      !Number.isSafeInteger(item.byteCount) ||
      item.byteCount < 1 ||
      item.byteCount > 256 * 1024 ||
      item.offset + item.byteCount > bundle.length ||
      !Array.isArray(item.origins) ||
      item.origins.length < 1 ||
      item.origins.length > 2048 ||
      digest(bundle.subarray(item.offset, item.offset + item.byteCount)) !==
        item.sha256
    )
      throw new Error("android_notice_selected_text_mismatch");
    seen.add(item.sha256);
    end = item.offset + item.byteCount;
  }
  return { bundle, inventoryBytes, inventory };
}
function registerSelectedNotices(
  projectRoot,
  platformProjectRoot,
  packageName,
) {
  if (packageName !== STORE_PACKAGE)
    throw new Error("android_notice_store_identity_required");
  const verified = verifySelectedNotices(projectRoot);
  const directory = path.join(
    platformProjectRoot,
    "app",
    "src",
    "main",
    "assets",
  );
  fs.mkdirSync(platformProjectRoot, { recursive: true });
  let current = platformProjectRoot;
  for (const part of [null, "app", "src", "main", "assets"]) {
    if (part !== null) current = path.join(current, part);
    if (!fs.existsSync(current)) fs.mkdirSync(current);
    const stat = fs.lstatSync(current);
    if (!stat.isDirectory() || stat.isSymbolicLink())
      throw new Error("android_notice_output_invalid");
  }
  for (const [name, bytes] of [
    [BUNDLE, verified.bundle],
    [INVENTORY, verified.inventoryBytes],
  ]) {
    const destination = path.join(directory, name);
    if (
      fs.existsSync(destination) &&
      fs.lstatSync(destination).isSymbolicLink()
    )
      throw new Error("android_notice_output_invalid");
    // Generated outputs are owned by prebuild. Reject a symlink rather than following it.
    const fd = fs.openSync(
      destination,
      fs.constants.O_WRONLY |
        fs.constants.O_CREAT |
        fs.constants.O_TRUNC |
        fs.constants.O_NOFOLLOW,
      0o644,
    );
    try {
      fs.writeFileSync(fd, bytes);
    } finally {
      fs.closeSync(fd);
    }
  }
}
function withAndroidStoreNotices(config, options = {}) {
  const variant = options.variant ?? process.env.THUMBLE_MOBILE_VARIANT;
  if (variant !== "store") return config;
  if (config.android?.package !== STORE_PACKAGE)
    throw new Error("android_notice_store_identity_required");
  const { withDangerousMod } = require("expo/config-plugins");
  return withDangerousMod(config, [
    "android",
    (mod) => {
      registerSelectedNotices(
        mod.modRequest.projectRoot,
        mod.modRequest.platformProjectRoot,
        mod.android?.package,
      );
      return mod;
    },
  ]);
}
module.exports = withAndroidStoreNotices;
module.exports.verifySelectedNotices = verifySelectedNotices;
module.exports.registerSelectedNotices = registerSelectedNotices;
