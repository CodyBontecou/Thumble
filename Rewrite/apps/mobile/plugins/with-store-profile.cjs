const { withAppBuildGradle, withXcodeProject } = require("expo/config-plugins");
function stripStoreDebugSigning(source) {
  const matches = [...source.matchAll(/^        release \{$/gm)];
  const anchor = "            signingConfig signingConfigs.debug";
  if (
    matches.length !== 1 ||
    (source.match(/signingConfig signingConfigs\.debug/g) ?? []).length !== 2
  )
    throw new Error("store_signing_template_changed");
  const start = matches[0].index + matches[0][0].length;
  const end = source.indexOf("\n        }", start);
  if (end < start) throw new Error("store_signing_template_changed");
  const block = source.slice(start, end);
  if (block.split(anchor).length !== 2)
    throw new Error("store_signing_template_changed");
  return (
    source.slice(0, start) +
    block.replace(
      anchor,
      "            // Store release signing must be configured explicitly; no debug-key fallback.",
    ) +
    source.slice(end)
  );
}
// Fresh store prebuild only. No credential is supplied or selected by this mod.
module.exports = (config) => {
  config = withAppBuildGradle(config, (mod) => {
    mod.modResults.contents = stripStoreDebugSigning(mod.modResults.contents);
    return mod;
  });
  return withXcodeProject(config, (mod) => {
    const sections = mod.modResults.pbxXCBuildConfigurationSection();
    let count = 0;
    for (const section of Object.values(sections)) {
      const settings =
        section && typeof section === "object"
          ? section.buildSettings
          : undefined;
      if (!settings) continue;
      const id = String(settings.PRODUCT_BUNDLE_IDENTIFIER ?? "").replaceAll(
        '"',
        "",
      );
      if (id !== "com.codybontecou.PocketPad.iOS") continue;
      settings.CURRENT_PROJECT_VERSION = config.ios.buildNumber;
      settings.MARKETING_VERSION = JSON.stringify(config.version);
      count++;
    }
    if (count !== 2) throw new Error("store_xcode_template_changed");
    return mod;
  });
};
module.exports.stripStoreDebugSigning = stripStoreDebugSigning;
