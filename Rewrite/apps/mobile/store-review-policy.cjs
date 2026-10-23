/** Store-only declarations for app-owned native APIs and least-privilege permissions.
 * Does not choose encryption classification, labels, signing or store accounts.
 */
const blocked = [
  "android.permission.READ_EXTERNAL_STORAGE",
  "android.permission.WRITE_EXTERNAL_STORAGE",
  "android.permission.SYSTEM_ALERT_WINDOW",
];
function storeReviewConfiguration(config) {
  if (
    config.ios?.bundleIdentifier !== "com.codybontecou.PocketPad.iOS" ||
    config.android?.package !== "com.thumble.android"
  )
    throw new Error("store_review_profile_required");
  const privacy = config.ios.privacyManifests ?? {};
  if (
    privacy.NSPrivacyTracking !== undefined &&
    privacy.NSPrivacyTracking !== false
  )
    throw new Error("store_tracking_not_supported");
  const existing = privacy.NSPrivacyAccessedAPITypes ?? [];
  if (!Array.isArray(existing))
    throw new Error("store_privacy_manifest_invalid");
  const required = new Map([
    ["NSPrivacyAccessedAPICategoryUserDefaults", "CA92.1"],
    ["NSPrivacyAccessedAPICategorySystemBootTime", "35F9.1"],
  ]);
  const seen = new Set();
  const entries = existing.map((entry) => {
    if (
      !entry ||
      typeof entry.NSPrivacyAccessedAPIType !== "string" ||
      !Array.isArray(entry.NSPrivacyAccessedAPITypeReasons) ||
      entry.NSPrivacyAccessedAPITypeReasons.some(
        (reason) => typeof reason !== "string",
      )
    )
      throw new Error("store_privacy_manifest_invalid");
    if (seen.has(entry.NSPrivacyAccessedAPIType))
      throw new Error("store_privacy_manifest_invalid");
    seen.add(entry.NSPrivacyAccessedAPIType);
    const reason = required.get(entry.NSPrivacyAccessedAPIType);
    required.delete(entry.NSPrivacyAccessedAPIType);
    return {
      ...entry,
      NSPrivacyAccessedAPITypeReasons: [
        ...new Set([
          ...entry.NSPrivacyAccessedAPITypeReasons,
          ...(reason ? [reason] : []),
        ]),
      ],
    };
  });
  for (const [type, reason] of required)
    entries.push({
      NSPrivacyAccessedAPIType: type,
      NSPrivacyAccessedAPITypeReasons: [reason],
    });
  return {
    ...config,
    ios: {
      ...config.ios,
      privacyManifests: {
        ...privacy,
        NSPrivacyTracking: false,
        NSPrivacyAccessedAPITypes: entries,
      },
    },
    android: {
      ...config.android,
      blockedPermissions: [
        ...new Set([...(config.android.blockedPermissions ?? []), ...blocked]),
      ],
    },
  };
}
module.exports.storeReviewConfiguration = storeReviewConfiguration;
