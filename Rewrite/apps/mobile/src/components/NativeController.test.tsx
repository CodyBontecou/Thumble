/// <reference types="bun" />
import { afterEach, beforeAll, expect, mock, test } from "bun:test";
import { createElement } from "react";
import { act, create, type ReactTestRenderer } from "react-test-renderer";

let systemScheme: "light" | "dark" | null = "light";
let systemPlatform: "ios" | "android" = "ios";
// Substitute only platform host components; real hooks, contracts and TSX run.
mock.module("react-native", () => ({
  View: "View",
  Text: "Text",
  Image: "Image",
  useColorScheme: () => systemScheme,
  Pressable: "Pressable",
  ScrollView: "ScrollView",
  useWindowDimensions: () => ({ width: 874, height: 393 }),
  Platform: {
    get OS() {
      return systemPlatform;
    },
  },
  PlatformColor: (name: string) => name,
}));
let orientationRequests: Array<{ resolve: (token: string) => void }> = [];
let orientationRestores: string[] = [];
mock.module("expo-modules-core", () => ({
  requireNativeModule: () => ({
    requestControllerLandscape: () =>
      new Promise<string>((resolve) => orientationRequests.push({ resolve })),
    restoreControllerOrientation: async (token: string) => {
      orientationRestores.push(token);
      return true;
    },
  }),
  requireNativeViewManager: (name: string) => name,
}));
let navigationBacks = 0;
let navigation: unknown[] = [];
let routeMode: unknown;
mock.module("expo-router", () => ({
  useLocalSearchParams: () => ({ outputMode: routeMode }),
  useRouter: () => ({
    navigate: (value: unknown) => navigation.push(value),
    replace: (value: unknown) => navigation.push(value),
    back: () => {
      navigationBacks++;
    },
  }),
}));
mock.module("expo-status-bar", () => ({ StatusBar: "StatusBar" }));
mock.module("react-native-safe-area-context", () => ({
  SafeAreaView: "SafeAreaView",
  useSafeAreaInsets: () => ({ top: 12, right: 7, bottom: 18, left: 9 }),
}));
const { NativeController } = await import("./NativeController.tsx");
const { ControllerScreen } = await import("../app/practice.tsx");
const { default: Home } = await import("../app/index.tsx");
const { default: Connect } = await import("../app/connect.tsx");
let renderer: ReactTestRenderer | undefined;
beforeAll(() => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
});
afterEach(async () => {
  systemScheme = "light";
  systemPlatform = "ios";
  await act(() => renderer?.unmount());
  renderer = undefined;
  routeMode = undefined;
  navigation = [];
  orientationRequests = [];
  orientationRestores = [];
});
async function mount(connected = true) {
  await act(() => {
    renderer = create(createElement(NativeController, { connected }));
  });
}
function native() {
  if (!renderer) throw new Error("renderer_missing");
  return renderer.root.findByProps({ testID: "controller-surface" });
}
async function admission(status: string, generation = "1") {
  const value =
    status === "ready"
      ? {
          version: 1,
          status,
          generation,
          revision: "0",
          practice: false,
          connected: true,
        }
      : { version: 1, status };
  await act(() =>
    native().props.onAdmission({ nativeEvent: { admission: value } }),
  );
}
async function catalog(value: unknown) {
  await act(() =>
    native().props.onCatalog({ nativeEvent: { catalog: value } }),
  );
}
function summary() {
  return (
    renderer?.root.findAllByProps({ testID: "saved-profile-summary" }) ?? []
  );
}
function page(count: number, nextOffset: number | null = null) {
  return Object.assign(
    {
      kind: "catalog",
      revision: count ? "1" : "0",
      contentHash: count ? "a".repeat(64) : null,
      activeProfileId: count ? "aaaaaaaa-0000-0000-0000-000000000001" : null,
      defaultProfileId: null,
      nextOffset,
      profileCount: count,
    },
    ...Array.from({ length: count }, (_, index) => ({
      [`profile${index}Id`]: `aaaaaaaa-0000-0000-0000-${String(index + 1).padStart(12, "0")}`,
      [`profile${index}Name`]: "Synthetic profile 日本語 🕹️ ".repeat(2),
      [`profile${index}UpdatedAt`]: "0",
    })),
  );
}

test("actual controller renders native metadata only after connected admission", async () => {
  await mount();
  expect(summary()).toHaveLength(0);
  expect(native().props.pointerEvents).toBe("none");
  await catalog(page(2));
  expect(summary()).toHaveLength(0);
  await admission("ready");
  expect(native().props.pointerEvents).toBe("auto");
  expect(summary()[0]?.props.children).toBe("2 saved profiles");
  expect(JSON.stringify(summary()[0]?.props)).not.toContain(
    "Synthetic profile",
  );
});

test("actual controller renders empty, singular and paginated count summaries", async () => {
  await mount();
  await admission("ready");
  for (const [value, text] of [
    [page(0), "No saved profiles"],
    [page(1), "1 saved profile"],
    [page(16, 16), "16 saved profiles · More available"],
  ] as const) {
    await catalog(value);
    expect(summary()[0]?.props.children).toBe(text);
    expect(summary()[0]?.props.numberOfLines).toBe(2);
    expect(summary()[0]?.props.pointerEvents).toBe("none");
  }
});

test("actual controller rejects malformed and native error notifications without disabling input", async () => {
  await mount();
  await admission("ready");
  for (const value of [
    { kind: "error", error: "phone_catalog_timeout" },
    { ...page(1), secret: "never render" },
    null,
    { kind: "catalog", profileCount: 1e9 },
  ]) {
    await catalog(value);
    expect(summary()[0]?.props.children).toBe("Saved profiles unavailable");
    expect(native().props.pointerEvents).toBe("auto");
  }
});

test("actual controller hides metadata on disconnect and clears it on remount", async () => {
  await mount();
  await admission("ready");
  await catalog(page(2));
  await admission("disconnected");
  expect(summary()).toHaveLength(0);
  expect(native().props.pointerEvents).toBe("none");
  await act(() => renderer?.unmount());
  await mount();
  await admission("ready");
  expect(summary()).toHaveLength(0);
});

test("practice controller never exposes saved metadata", async () => {
  await mount(false);
  await catalog(page(2));
  expect(summary()).toHaveLength(0);
});

test("same mounted reconnect never restores prior count or error while fetching", async () => {
  await mount();
  await admission("ready");
  for (const prior of [
    page(2),
    { kind: "error", error: "phone_catalog_timeout" },
  ]) {
    await catalog(prior);
    expect(summary()).toHaveLength(1);
    await admission("disconnected");
    await admission("connecting");
    await admission("ready");
    expect(summary()).toHaveLength(0);
    expect(native().props.pointerEvents).toBe("auto");
  }
  await admission("connecting");
  await catalog(page(1));
  await admission("ready");
  expect(summary()[0]?.props.children).toBe("1 saved profile");
});

test("new admission identity clears stale metadata while ordinary ready events preserve it", async () => {
  await mount();
  await admission("ready");
  await catalog(page(2));
  await admission("ready");
  expect(summary()[0]?.props.children).toBe("2 saved profiles");
  await admission("ready", "2");
  expect(summary()).toHaveLength(0);
  await catalog(page(1));
  await act(() =>
    renderer?.update(createElement(NativeController, { connected: true })),
  );
  expect(summary()[0]?.props.children).toBe("1 saved profile");
});

const deliveredMap = {
  version: 1,
  generation: "1",
  revision: "0",
  controls: [
    {
      id: "saved-only-east",
      action: "east",
      x: 0.1,
      y: 0.2,
      width: 0.3,
      height: 0.4,
    },
  ],
};
async function layout(value: unknown) {
  await act(() => native().props.onControlMap({ nativeEvent: { map: value } }));
}
function controllerLabels() {
  return (
    renderer?.root
      .findAll((node) => String(node.type) === "Text")
      .map((node) => node.props.children) ?? []
  );
}

test("connected controller renders only native-installed epoch-matched map without standard template", async () => {
  await mount();
  expect(native().props.connect).toBe(true);
  expect(native().props.connectionMap).toBeUndefined();
  expect(native().props.practiceMap).toBeUndefined();
  expect(controllerLabels()).not.toContain("B");
  await layout(deliveredMap);
  expect(controllerLabels()).not.toContain("B");
  await admission("ready");
  expect(controllerLabels()).toContain("B");
  expect(controllerLabels()).not.toContain("A");
  const button = renderer?.root.findAll(
    (node) => node.props.style?.left === "10%",
  )[0];
  expect(button?.props.style.width).toBe("30%");
  await admission("ready");
  expect(controllerLabels()).toContain("B");
  await admission("ready", "2");
  expect(controllerLabels()).not.toContain("B");
});

test("malformed or stale delivered maps never render fallback controls and disconnect clears map", async () => {
  await mount();
  await admission("ready");
  for (const value of [
    null,
    { ...deliveredMap, generation: "2" },
    { ...deliveredMap, secret: "invalid" },
  ]) {
    await layout(value);
    expect(controllerLabels()).not.toContain("B");
    expect(controllerLabels()).not.toContain("A");
    expect(native().props.pointerEvents).toBe("auto");
  }
  await layout(deliveredMap);
  expect(controllerLabels()).toContain("B");
  await admission("disconnected");
  await admission("ready");
  expect(controllerLabels()).not.toContain("B");
});

test("actual connected screen reserves navigation outside native saved-map viewport", async () => {
  navigationBacks = 0;
  await act(() => {
    renderer = create(createElement(ControllerScreen, { connected: true }));
  });
  const header = renderer?.root.findByProps({ testID: "connection-header" });
  const done = renderer?.root.findByProps({ testID: "connection-done" });
  expect(header?.props.style.minHeight).toBe(44);
  expect(header?.findAllByProps({ testID: "controller-surface" })).toHaveLength(
    0,
  );
  expect(header?.findByProps({ testID: "connection-done" })).toBe(done);
  expect(done?.props.style({ pressed: false }).position).toBeUndefined();
  await layout(deliveredMap);
  await admission("ready");
  await act(() => done?.props.onPress());
  expect(navigationBacks).toBe(1);
});

test("actual practice screen retains existing navigation and standard map", async () => {
  await act(() => {
    renderer = create(createElement(ControllerScreen, { connected: false }));
  });
  expect(
    renderer?.root.findAllByProps({ testID: "connection-header" }),
  ).toHaveLength(0);
  expect(
    renderer?.root.findByProps({ testID: "practice-screen" }).props.style
      .paddingTop,
  ).toBe(12);
  expect(
    renderer?.root.findByProps({ testID: "practice-screen" }).props.style
      .paddingLeft,
  ).toBe(9);
  const done = renderer?.root.findByProps({ testID: "practice-done" });
  expect(done?.props.style({ pressed: false }).position).toBe("absolute");
  expect(native().props.practiceMap.controls.length).toBeGreaterThan(1);
  expect(native().props.connect).toBeUndefined();
});

test("saved analog controls display familiar labels and pad visuals after native installation", async () => {
  await mount();
  const actions = [
    "leftStandardStick",
    "rightStandardStick",
    "leftVerticalTrigger",
    "rightVerticalTrigger",
    "leftHorizontalTrigger",
    "rightHorizontalTrigger",
  ];
  const controls = actions.map((action, index) => ({
    id: `analog-${index}`,
    action,
    x: index * 0.15,
    y: 0.2,
    width: 0.1,
    height: 0.2,
  }));
  await layout({ ...deliveredMap, controls });
  await admission("ready");
  expect(
    controllerLabels().filter((label) =>
      ["L", "R", "LT", "RT"].includes(String(label)),
    ),
  ).toEqual(["L", "R", "LT", "RT", "LT", "RT"]);
  expect(
    controllerLabels().some((label) => actions.includes(String(label))),
  ).toBe(false);
  const outlines =
    renderer?.root.findAll(
      (node) =>
        String(node.type) === "View" && node.props.style?.borderWidth === 1,
    ) ?? [];
  expect(outlines.map((node) => node.props.style.borderRadius)).toEqual([
    999, 999, 12, 12, 12, 12,
  ]);
  expect(outlines.map((node) => node.props.style.width)).toEqual(
    Array(6).fill("10%"),
  );
  expect(native().props.pointerEvents).toBe("auto");
});

test("Home explicitly distinguishes Mac input, diagnostic connection and practice", async () => {
  await act(() => {
    renderer = create(createElement(Home));
  });
  for (const id of ["home-connect-mac", "home-connect", "home-practice"]) {
    await act(() => renderer?.root.findByProps({ testID: id }).props.onPress());
  }
  expect(navigation).toEqual([
    { pathname: "/connect", params: { outputMode: "macos-hid" } },
    { pathname: "/connect", params: { outputMode: "recording" } },
    "/practice",
  ]);
});

test("intent changes remount native ownership and clear the preceding map and catalog", async () => {
  await act(() => {
    renderer = create(
      createElement(ControllerScreen, {
        connected: true,
        outputMode: "macos-hid",
      }),
    );
  });
  expect(native().props.outputMode).toBe("macos-hid");
  expect(
    renderer?.root.findByProps({ testID: "connection-mode" }).props.children,
  ).toBe("Mac input");
  await layout(deliveredMap);
  await admission("ready");
  await catalog(page(2));
  expect(controllerLabels()).toContain("B");
  await act(() =>
    renderer?.update(
      createElement(ControllerScreen, {
        connected: true,
        outputMode: "recording",
      }),
    ),
  );
  expect(native().props.outputMode).toBe("recording");
  expect(controllerLabels()).not.toContain("B");
  expect(summary()).toHaveLength(0);
  expect(
    renderer?.root.findByProps({ testID: "connection-mode" }).props.children,
  ).toBe("Test mode");
});

test("malformed route intents never construct a native owner and legacy route is honest Test mode", async () => {
  for (const mode of ["unknown", "", ["macos-hid", "recording"]]) {
    routeMode = mode;
    await act(() => {
      renderer = create(createElement(Connect));
    });
    expect(
      renderer?.root.findAllByProps({ testID: "controller-surface" }),
    ).toHaveLength(0);
    expect(
      renderer?.root.findByProps({ testID: "connection-invalid-intent" }),
    ).toBeDefined();
    await act(() => renderer?.unmount());
    renderer = undefined;
  }
  routeMode = undefined;
  await act(() => {
    renderer = create(createElement(Connect));
  });
  expect(native().props.outputMode).toBe("recording");
  expect(
    renderer?.root.findByProps({ testID: "connection-mode" }).props.children,
  ).toBe("Test mode");
});

test("controller route restores only its resolved native orientation token on exit", async () => {
  await act(() => {
    renderer = create(createElement(ControllerScreen));
  });
  expect(orientationRequests).toHaveLength(1);
  await act(async () => {
    orientationRequests[0]!.resolve("route-a");
  });
  await act(() => renderer?.unmount());
  renderer = undefined;
  expect(orientationRestores).toEqual(["route-a"]);
});

test("late orientation completion after unmount releases its token without mounting controls", async () => {
  await act(() => {
    renderer = create(createElement(ControllerScreen));
  });
  const request = orientationRequests[0]!;
  await act(() => renderer?.unmount());
  renderer = undefined;
  await act(async () => {
    request.resolve("late-route");
  });
  expect(orientationRestores).toEqual(["late-route"]);
});

const presentationPin = {
  generation: "1",
  revision: "0",
  configurationSha256: "c".repeat(64),
  expectedConfigurationRevision: "1",
  expectedSourceHash: "a".repeat(64),
  profileId: "aaaaaaaa-0000-0000-0000-000000000001",
};
const presentationVersion = {
  presentationRevision: "2",
  presentationSourceHash: "b".repeat(64),
  colorScheme: "light",
  bank: "base",
};
function metadata(extra: Record<string, unknown> = {}) {
  return {
    kind: "presentation",
    ...presentationPin,
    ...presentationVersion,
    profileName: "Mage",
    freshness: "observed",
    controls: [{ id: "saved-only-east", label: "Fireball" }],
    ...extra,
  };
}
async function present(value: unknown) {
  await act(() =>
    native().props.onPresentation({ nativeEvent: { presentation: value } }),
  );
}
async function pinnedMap() {
  await act(() =>
    native().props.onControlMap({
      nativeEvent: {
        map: deliveredMap,
        configurationSha256: presentationPin.configurationSha256,
      },
    }),
  );
}
function presentationStatus() {
  return renderer?.root.findAllByProps({ testID: "presentation-status" })[0]
    ?.props.children;
}

test("live labels require installed native map hash, current admission and exact control IDs", async () => {
  await mount();
  await admission("ready");
  await layout(deliveredMap);
  await present(metadata());
  expect(controllerLabels()).not.toContain("Fireball");
  await pinnedMap();
  await present(metadata({ controls: [{ id: "foreign", label: "Foreign" }] }));
  expect(controllerLabels()).not.toContain("Foreign");
  await present(metadata());
  expect(controllerLabels()).toContain("Fireball");
  expect(presentationStatus()).toBe("Game data live");
  expect(native().props.pointerEvents).toBe("auto");
  expect(native().props.connectionMap).toBeUndefined();
});

test("stale, foreign, rollback and changed-source callbacks never replace current presentation or affect input", async () => {
  await mount();
  await admission("ready");
  await pinnedMap();
  await present(metadata());
  for (const extra of [
    { generation: "2" },
    { configurationSha256: "d".repeat(64) },
    { colorScheme: "dark" },
    { expectedSourceHash: "d".repeat(64) },
    { profileId: "aaaaaaaa-0000-0000-0000-000000000002" },
    { presentationRevision: "1" },
    { presentationSourceHash: "d".repeat(64) },
  ]) {
    await present(
      metadata({
        ...extra,
        controls: [{ id: "saved-only-east", label: "Wrong" }],
      }),
    );
    expect(controllerLabels()).toContain("Fireball");
    expect(controllerLabels()).not.toContain("Wrong");
    expect(native().props.pointerEvents).toBe("auto");
  }
  await present(
    metadata({
      presentationRevision: "3",
      presentationSourceHash: "d".repeat(64),
      freshness: "stale",
      controls: [{ id: "saved-only-east", label: "Frostbolt" }],
    }),
  );
  expect(controllerLabels()).toContain("Frostbolt");
  expect(presentationStatus()).toBe("Game data stale");
  await present({
    kind: "error",
    error: "presentation_timeout",
    generation: "1",
    revision: "0",
    configurationSha256: presentationPin.configurationSha256,
  });
  expect(controllerLabels()).toContain("Frostbolt");
  expect(native().props.pointerEvents).toBe("auto");
  await admission("disconnected");
  await admission("ready");
  await present(metadata());
  expect(controllerLabels()).not.toContain("Fireball");
  expect(controllerLabels()).not.toContain("Frostbolt");
  expect(presentationStatus()).toBeUndefined();
});

test("verified icon notifications need exact metadata revision, source and control hash and stay cosmetic", async () => {
  await mount();
  await admission("ready");
  await pinnedMap();
  const png =
    "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAL0lEQVR4nO3OIQEAAAgDMKIQhWg0hxg3E/Ornr2kEhAQEBAQEBAQEBAQEBAQSAcenxt8avMpgHIAAAAASUVORK5CYII=";
  const control = {
    id: "saved-only-east",
    label: "Fireball",
    iconSHA256: "e".repeat(64),
    iconByteCount: 104,
    iconName: "spell",
  };
  const icon = {
    kind: "icon",
    ...presentationPin,
    ...presentationVersion,
    controlId: control.id,
    iconSHA256: control.iconSHA256,
    pngBase64: png,
  };
  const images = () =>
    renderer?.root.findAllByProps({
      testID: "presentation-icon-saved-only-east",
    }) ?? [];
  await present(icon);
  expect(images()).toHaveLength(0);
  await present(metadata({ controls: [control] }));
  await present({ ...icon, presentationRevision: "1" });
  expect(images()).toHaveLength(0);
  await present({ ...icon, iconSHA256: "f".repeat(64) });
  expect(images()).toHaveLength(0);
  await present(icon);
  expect(images()).toHaveLength(1);
  expect(images()[0]?.props.source.uri).toBe(`data:image/png;base64,${png}`);
  await present(metadata({ controls: [control] }));
  expect(images()).toHaveLength(1);
  await present(
    metadata({
      controls: [{ id: control.id, label: "Changed" }],
      presentationRevision: "3",
    }),
  );
  expect(images()).toHaveLength(0);
  expect(controllerLabels()).toContain("Changed");
  await present(icon);
  expect(images()).toHaveLength(0);
  await present({ ...metadata(), credential: "not-allowed" });
  expect(presentationStatus()).toBe("Game data stale");
  expect(native().props.pointerEvents).toBe("auto");
});

test("replacement map installed before ready admission retains its native presentation pin", async () => {
  await mount();
  await admission("ready");
  await pinnedMap();
  await present(metadata());
  const replacement = { ...deliveredMap, generation: "2" };
  await act(() =>
    native().props.onControlMap({
      nativeEvent: { map: replacement, configurationSha256: "d".repeat(64) },
    }),
  );
  await admission("ready", "2");
  await present(
    metadata({
      generation: "2",
      configurationSha256: "d".repeat(64),
      controls: [{ id: "saved-only-east", label: "Replacement" }],
    }),
  );
  expect(controllerLabels()).toContain("Replacement");
  expect(controllerLabels()).not.toContain("Fireball");
  expect(native().props.pointerEvents).toBe("auto");
});

test("Android semantic palette follows system appearance without remounting native input", async () => {
  systemPlatform = "android";
  systemScheme = "light";
  await act(() => {
    renderer = create(createElement(ControllerScreen, { connected: true }));
  });
  const screen = () =>
    renderer!.root.findByProps({ testID: "connection-screen" });
  const mode = () => renderer!.root.findByProps({ testID: "connection-mode" });
  const before = native();
  expect(screen().props.style.backgroundColor).toBe("#FAFAFA");
  expect(mode().props.style.color).toBe("#1C1B1F");
  systemScheme = "dark";
  await act(() =>
    renderer!.update(createElement(ControllerScreen, { connected: true })),
  );
  expect(screen().props.style.backgroundColor).toBe("#303030");
  expect(mode().props.style.color).toBe("#E6E1E5");
  expect(native()).toBe(before);
  expect(native().props.connect).toBe(true);
  expect(native().props.outputMode).toBe("recording");
  systemScheme = null;
  await act(() =>
    renderer!.update(createElement(ControllerScreen, { connected: true })),
  );
  expect(screen().props.style.backgroundColor).toBe("#FAFAFA");
  expect(native()).toBe(before);
});
