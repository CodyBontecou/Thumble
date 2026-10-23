const { withDangerousMod } = require("expo/config-plugins");
const fs = require("node:fs/promises");
const path = require("node:path");

// Android textColorPrimary/Secondary can be ColorStateLists. React Native's
// PlatformColor theme-attribute resolver reads TypedValue.data as a plain color,
// so use named color resources with native day/night selection instead.
module.exports = (config) =>
  withDangerousMod(config, [
    "android",
    async (mod) => {
      const palettes = {
        values: {
          label: "#1C1B1F",
          secondary_label: "#49454F",
          separator: "#CAC4D0",
        },
        "values-night": {
          label: "#E6E1E5",
          secondary_label: "#CAC4D0",
          separator: "#49454F",
        },
      };
      for (const [folder, colors] of Object.entries(palettes)) {
        const directory = path.join(
          mod.modRequest.platformProjectRoot,
          "app/src/main/res",
          folder,
        );
        await fs.mkdir(directory, { recursive: true });
        const source =
          '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n' +
          Object.entries(colors)
            .map(
              ([role, value]) =>
                `  <color name="thumble_${role}">${value}</color>`,
            )
            .join("\n") +
          "\n</resources>\n";
        await fs.writeFile(
          path.join(directory, "thumble_semantic_colors.xml"),
          source,
        );
      }
      return mod;
    },
  ]);
