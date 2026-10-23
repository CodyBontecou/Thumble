import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { mobileProfile } from "../apps/mobile/store-profile.cjs";
import { storeReviewConfiguration } from "../apps/mobile/store-review-policy.cjs";
const base = JSON.parse(
  readFileSync(new URL("../apps/mobile/app.json", import.meta.url), "utf8"),
).expo;
const env = {
  THUMBLE_MOBILE_VARIANT: "store",
  THUMBLE_STORE_VERSION: "1.0.0",
  THUMBLE_STORE_BUILD: "4",
};
test("store alone declares app-local preference and timer reasons and blocks inherited storage/overlay permissions", () => {
  const before = JSON.stringify(base),
    store = mobileProfile(base, env);
  expect(mobileProfile(base, {})).toBe(base);
  expect(base.ios.privacyManifests).toBeUndefined();
  expect(base.android.blockedPermissions).toBeUndefined();
  expect(store.ios?.privacyManifests).toEqual({
    NSPrivacyTracking: false,
    NSPrivacyAccessedAPITypes: [
      {
        NSPrivacyAccessedAPIType: "NSPrivacyAccessedAPICategoryUserDefaults",
        NSPrivacyAccessedAPITypeReasons: ["CA92.1"],
      },
      {
        NSPrivacyAccessedAPIType: "NSPrivacyAccessedAPICategorySystemBootTime",
        NSPrivacyAccessedAPITypeReasons: ["35F9.1"],
      },
    ],
  });
  expect(store.android?.blockedPermissions).toEqual([
    "android.permission.READ_EXTERNAL_STORAGE",
    "android.permission.WRITE_EXTERNAL_STORAGE",
    "android.permission.SYSTEM_ALERT_WINDOW",
  ]);
  expect(store.ios?.infoPlist?.ITSAppUsesNonExemptEncryption).toBeUndefined();
  expect(store.ios?.config?.usesNonExemptEncryption).toBeUndefined();
  expect(JSON.stringify(base)).toBe(before);
});
test("store privacy merge preserves other SDK declarations without mutating source and refuses tracking or malformed claims", () => {
  const first = mobileProfile(base, env),
    config = {
      ...first,
      ios: {
        ...first.ios,
        privacyManifests: {
          NSPrivacyAccessedAPITypes: [
            {
              NSPrivacyAccessedAPIType:
                "NSPrivacyAccessedAPICategoryUserDefaults",
              NSPrivacyAccessedAPITypeReasons: ["CA92.1"],
            },
            {
              NSPrivacyAccessedAPIType:
                "NSPrivacyAccessedAPICategoryFileTimestamp",
              NSPrivacyAccessedAPITypeReasons: ["C617.1"],
            },
          ],
        },
      },
      android: { ...first.android, blockedPermissions: ["custom.permission"] },
    };
  const before = JSON.stringify(config),
    merged = storeReviewConfiguration(config);
  expect(merged.ios?.privacyManifests?.NSPrivacyAccessedAPITypes).toHaveLength(
    3,
  );
  expect(merged.android?.blockedPermissions).toContain("custom.permission");
  expect(JSON.stringify(config)).toBe(before);
  expect(() => storeReviewConfiguration(base)).toThrow(
    "store_review_profile_required",
  );
  const tracking = JSON.parse(JSON.stringify(first));
  tracking.ios.privacyManifests.NSPrivacyTracking = true;
  expect(() => storeReviewConfiguration(tracking)).toThrow(
    "store_tracking_not_supported",
  );
  const malformed = JSON.parse(JSON.stringify(first));
  malformed.ios.privacyManifests.NSPrivacyAccessedAPITypes = [{}];
  expect(() => storeReviewConfiguration(malformed)).toThrow(
    "store_privacy_manifest_invalid",
  );
});

test("store icon stays binary in Git and export template cannot silently select an account or upload", () => {
  expect(
    readFileSync(new URL("../.gitattributes", import.meta.url), "utf8"),
  ).toMatch(/^\*\.png -text$/m);
  const template = readFileSync(
    new URL(
      "../apps/mobile/release/ExportOptions.example.plist",
      import.meta.url,
    ),
    "utf8",
  );
  for (const marker of [
    "__EXISTING_TEAM_ID__",
    "__EXISTING_DISTRIBUTION_CERTIFICATE_SHA1__",
    "__EXISTING_APP_STORE_PROFILE_UUID__",
  ])
    expect(template).toContain(marker);
  expect(template).toContain("<key>destination</key><string>export</string>");
  expect(template).toContain("<key>signingStyle</key><string>manual</string>");
  expect(template).not.toContain("<string>upload</string>");
});
