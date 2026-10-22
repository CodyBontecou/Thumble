/** Pure configuration policy. Never provisions, signs, installs or uploads. */
function mobileProfile(config, env) {
  const variant = env.THUMBLE_MOBILE_VARIANT;
  if (variant !== undefined && variant !== "development" && variant !== "store")
    throw new Error("invalid_mobile_variant");
  const version = env.THUMBLE_STORE_VERSION,
    build = env.THUMBLE_STORE_BUILD;
  if (variant !== "store") {
    if (version !== undefined || build !== undefined)
      throw new Error("store_metadata_requires_store_variant");
    return config;
  }
  // Conservative review policy, not an assertion of every platform's limits.
  if (
    typeof version !== "string" ||
    !/^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$/.test(
      version,
    )
  )
    throw new Error("invalid_store_version");
  // A single shared positive build number fits Apple's four-digit first component
  // and Android's integer versionCode without JS precision conversions.
  if (typeof build !== "string" || !/^[1-9][0-9]{0,3}$/.test(build))
    throw new Error("invalid_store_build");
  const plugins = config.plugins ?? [];
  const pluginName = (p) => (Array.isArray(p) ? p[0] : p);
  for (const required of [
    "expo-router",
    "./plugins/with-native-input.cjs",
    "./plugins/with-semantic-colors.cjs",
  ])
    if (!plugins.some((p) => pluginName(p) === required))
      throw new Error("store_required_plugin_missing");
  return {
    ...config,
    name: "Thumble",
    slug: "thumble",
    scheme: "thumble",
    version,
    icon: "./assets/store-icon.png",
    ios: {
      ...config.ios,
      bundleIdentifier: "com.codybontecou.PocketPad.iOS",
      supportsTablet: false,
      buildNumber: build,
    },
    android: {
      ...config.android,
      package: "com.thumble.android",
      versionCode: Number(build),
      allowBackup: false,
    },
    plugins: [
      ...plugins.filter(
        (p) =>
          pluginName(p) !== "./plugins/with-native-qa.cjs" &&
          pluginName(p) !== "./plugins/with-store-profile.cjs",
      ),
      "./plugins/with-store-profile.cjs",
    ],
  };
}
module.exports.mobileProfile = mobileProfile;
