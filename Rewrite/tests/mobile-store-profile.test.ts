import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { createHash } from "node:crypto";
import { createRequire } from "node:module";
import { mobileProfile } from "../apps/mobile/store-profile.cjs";
const require = createRequire(import.meta.url);
const { stripStoreDebugSigning } =
  require("../apps/mobile/plugins/with-store-profile.cjs") as {
    stripStoreDebugSigning: (source: string) => string;
  };
const root = resolve(import.meta.dir, ".."),
  source = readFileSync(resolve(root, "apps/mobile/app.json"), "utf8"),
  baseline = JSON.parse(source).expo;
const env = {
  THUMBLE_MOBILE_VARIANT: "store",
  THUMBLE_STORE_VERSION: "1.0.0",
  THUMBLE_STORE_BUILD: "4",
};

test("default dynamic config is identical development profile and rejects ambiguous store overrides", () => {
  expect(mobileProfile(baseline, {})).toBe(baseline);
  expect(
    mobileProfile(baseline, { THUMBLE_MOBILE_VARIANT: "development" }),
  ).toBe(baseline);
  for (const variant of ["", "dev", "production", "STORE", "store "])
    expect(() =>
      mobileProfile(baseline, { ...env, THUMBLE_MOBILE_VARIANT: variant }),
    ).toThrow("invalid_mobile_variant");
  expect(() =>
    mobileProfile(baseline, { THUMBLE_STORE_VERSION: "1.0.0" }),
  ).toThrow("store_metadata_requires_store_variant");
  expect(() => mobileProfile(baseline, { THUMBLE_STORE_BUILD: "4" })).toThrow(
    "store_metadata_requires_store_variant",
  );
});

test("store identity metadata is explicit, brand-owned, iPhone-only and excludes QA without mutating dev", () => {
  const before = JSON.stringify(baseline),
    store = mobileProfile(baseline, env);
  expect(store.name).toBe("Thumble");
  expect(store.slug).toBe("thumble");
  expect(store.scheme).toBe("thumble");
  expect(store.version).toBe("1.0.0");
  expect(store.ios?.bundleIdentifier).toBe("com.codybontecou.PocketPad.iOS");
  expect(store.ios?.supportsTablet).toBe(false);
  expect(store.ios?.buildNumber).toBe("4");
  expect(store.android?.package).toBe("com.thumble.android");
  expect(store.android?.versionCode).toBe(4);
  expect(store.android?.allowBackup).toBe(false);
  expect(store.ios?.infoPlist).toEqual(baseline.ios.infoPlist);
  const plugins = store.plugins!.map((p) => (Array.isArray(p) ? p[0] : p));
  expect(plugins).not.toContain("./plugins/with-native-qa.cjs");
  expect(plugins).toContain("./plugins/with-native-input.cjs");
  expect(plugins).toContain("./plugins/with-semantic-colors.cjs");
  expect(plugins).toContain("./plugins/with-store-profile.cjs");
  expect(JSON.stringify(baseline)).toBe(before);
  expect(readFileSync(resolve(root, "apps/mobile/app.json"), "utf8")).toBe(
    source,
  );
  const icon = readFileSync(resolve(root, "apps/mobile/assets/store-icon.png"));
  expect(createHash("sha256").update(icon).digest("hex")).toBe(
    "6eae962eb6ad8037b0d661bacdc8e1920825028aecfcc5fb05124fbcc07427a7",
  );
  expect(icon.readUInt32BE(16)).toBe(1024);
  expect(icon.readUInt32BE(20)).toBe(1024);
  expect(icon[25]).toBe(2);
});

test("store review versions/builds are required canonical bounded values, not inherited defaults", () => {
  for (const version of [
    "",
    "1.0",
    "1.0.0-beta",
    "v1.0.0",
    "01.0.0",
    "1.00.0",
    "1.0.0 ",
    "1.0.0\n",
    "1000.0.0",
  ])
    expect(() =>
      mobileProfile(baseline, { ...env, THUMBLE_STORE_VERSION: version }),
    ).toThrow("invalid_store_version");
  for (const build of ["", "0", "04", "1.2", "-1", "10000", "4 ", "4\n", "4e0"])
    expect(() =>
      mobileProfile(baseline, { ...env, THUMBLE_STORE_BUILD: build }),
    ).toThrow("invalid_store_build");
  expect(() =>
    mobileProfile(baseline, { THUMBLE_MOBILE_VARIANT: "store" }),
  ).toThrow("invalid_store_version");
  expect(
    mobileProfile(baseline, { ...env, THUMBLE_STORE_BUILD: "9999" }).android
      ?.versionCode,
  ).toBe(9999);
  expect(() => mobileProfile({ ...baseline, plugins: [] }, env)).toThrow(
    "store_required_plugin_missing",
  );
});

test("store Gradle mod removes release debug signing only and fails closed on changed templates", () => {
  const gradle = `android {
    buildTypes {
        debug {
            signingConfig signingConfigs.debug
        }
        release {
            signingConfig signingConfigs.debug
            minifyEnabled false
        }
    }
}`;
  const result = stripStoreDebugSigning(gradle);
  expect(result.split("signingConfig signingConfigs.debug").length).toBe(2);
  expect(
    result
      .slice(result.indexOf("        release {"))
      .includes("signingConfig signingConfigs.debug"),
  ).toBe(false);
  expect(result).toContain(
    "Store release signing must be configured explicitly",
  );
  for (const invalid of [
    gradle.replace("        release {", "        production {"),
    gradle.replace("            signingConfig signingConfigs.debug", ""),
    result,
  ])
    expect(() => stripStoreDebugSigning(invalid)).toThrow(
      "store_signing_template_changed",
    );
});

test("actual Expo offline loader resolves both default and explicit store profiles", () => {
  const cli = resolve(root, "apps/mobile/node_modules/expo/bin/cli");
  const clean: Record<string, string | undefined> = {
    ...process.env,
    EXPO_OFFLINE: "1",
    EXPO_NO_TELEMETRY: "1",
    EXPO_NO_DOTENV: "1",
    CI: "1",
  };
  delete clean.THUMBLE_MOBILE_VARIANT;
  delete clean.THUMBLE_STORE_VERSION;
  delete clean.THUMBLE_STORE_BUILD;
  for (const store of [false, true]) {
    const result = Bun.spawnSync(
      [
        process.env.THUMBLE_REWRITE_NODE ?? "node",
        cli,
        "config",
        "--type",
        "public",
        "--json",
      ],
      {
        cwd: resolve(root, "apps/mobile"),
        env: { ...clean, ...(store ? env : {}) },
        stdout: "pipe",
        stderr: "pipe",
        timeout: 10000,
      },
    );
    expect(result.exitCode).toBe(0);
    expect(result.stderr.length).toBe(0);
    const config = JSON.parse(result.stdout.toString());
    expect(config.ios.bundleIdentifier).toBe(
      store ? "com.codybontecou.PocketPad.iOS" : baseline.ios.bundleIdentifier,
    );
    expect(config.android.package).toBe(
      store ? "com.thumble.android" : baseline.android.package,
    );
    expect(config.ios.supportsTablet).toBe(
      store ? false : baseline.ios.supportsTablet,
    );
  }
});
