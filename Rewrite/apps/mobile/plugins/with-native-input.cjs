const { withPodfile } = require("expo/config-plugins");
const path = require("node:path");
module.exports = (config) =>
  withPodfile(config, (mod) => {
    const marker = "  # Thumble native input sources";
    if (mod.modResults.contents.includes(marker)) return mod;
    const relative = (target) =>
      path
        .relative(
          mod.modRequest.platformProjectRoot,
          path.resolve(mod.modRequest.projectRoot, "../..", target),
        )
        .replaceAll("\\", "/");
    const pods = [
      ["ThumbleContracts", "packages/contracts/generated/swift"],
      ["MobileInputCore", "native/mobile-input/ios"],
      ["MobileInputUIKit", "native/mobile-input/ios"],
    ]
      .map(
        ([name, location]) =>
          `  pod '${name}', :path => '${relative(location)}'`,
      )
      .join("\n");
    const anchor = "  use_expo_modules!";
    if (!mod.modResults.contents.includes(anchor))
      throw new Error("native_input_podfile_anchor_missing");
    mod.modResults.contents = mod.modResults.contents.replace(
      anchor,
      `${anchor}\n${marker}\n${pods}`,
    );
    return mod;
  });
