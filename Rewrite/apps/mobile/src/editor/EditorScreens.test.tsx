/// <reference types="bun" />
import { afterEach, expect, mock, test } from "bun:test";
import { createElement, type ReactNode } from "react";
import { act, create, type ReactTestRenderer } from "react-test-renderer";
const alerts: Array<{
  title: string;
  buttons: Array<{ text: string; onPress?: () => void }>;
}> = [];
let backs = 0,
  params: { controlId?: string } = { controlId: "control" };
mock.module("expo-modules-core", () => ({
  requireNativeModule: () => {
    throw Error("native_not_requested");
  },
}));
function Screen({
  options,
}: {
  options?: { headerLeft?: () => ReactNode; headerRight?: () => ReactNode };
}) {
  return createElement(
    "Header",
    null,
    options?.headerLeft?.(),
    options?.headerRight?.(),
  );
}
mock.module("expo-router", () => ({
  Stack: Object.assign("Stack", { Screen }),
  useRouter: () => ({
    back: () => {
      backs++;
    },
    push: () => {},
  }),
  useLocalSearchParams: () => params,
  usePreventRemove: () => () => {},
}));
mock.module("react-native-safe-area-context", () => ({
  useSafeAreaInsets: () => ({ top: 0, bottom: 0, left: 0, right: 0 }),
}));
mock.module("react-native", () => ({
  Text: "Text",
  View: "View",
  Button: "Button",
  Pressable: "Pressable",
  ScrollView: "ScrollView",
  TextInput: "TextInput",
  KeyboardAvoidingView: "KeyboardAvoidingView",
  ActivityIndicator: "ActivityIndicator",
  Keyboard: { dismiss: () => {} },
  Platform: { OS: "ios" },
  PlatformColor: (name: string) => name,
  useColorScheme: () => "light",
  Alert: {
    alert: (
      title: string,
      _message?: string,
      buttons: Array<{ text: string; onPress?: () => void }> = [],
    ) => alerts.push({ title, buttons }),
  },
}));
const { EditorProvider } = await import("./EditorProvider");
const { EditorModel } = await import("./editor-model");
const LabelScreen = (await import("../app/editor/label")).default;
import type { NativeEditor, EditorSnapshot } from "./NativeEditorSession";
let renderer: ReactTestRenderer | null = null;
afterEach(async () => {
  if (renderer)
    await act(async () => {
      renderer?.unmount();
    });
  renderer = null;
  alerts.length = 0;
  backs = 0;
});
async function setup(staleNotice = false) {
  let snapshot: EditorSnapshot = {
    profiles: [
      {
        contextId: "ctx",
        profileId: "profile",
        name: "Controller",
        revision: "7",
        sourceSha256: "a".repeat(64),
        controlCount: 1,
      },
    ],
    selection: null,
    queue: [],
  };
  const labels: Array<string | null> = [];
  const bridge: NativeEditor = {
    snapshot: async () => snapshot,
    cachePage: async () => ({
      contextId: "ctx",
      offset: 0,
      nextOffset: null,
      controls: [
        { id: "control", generatedLabel: "Jump", labelOverride: "Leap" },
      ],
    }),
    select: async () => {},
    read: async () => snapshot,
    catalog: async () => ({
      kind: "error",
      error: "phone_catalog_unavailable",
    }),
    enqueue: async (edit) => {
      labels.push(edit.label);
      snapshot = {
        ...snapshot,
        queue: [
          {
            operationId: edit.operationId,
            profileId: "profile",
            controlId: "control",
            expectedRevision: edit.expectedRevision,
            label: edit.label,
            status: "queued",
            conflictRevision: null,
          },
        ],
      };
    },
    submit: async () => "retained",
    reconcile: async () => "retained",
    cancel: async () => {},
    close: async () => {},
  };
  const model = new EditorModel(async () => bridge);
  await model.open();
  await model.openCached("ctx");
  if (staleNotice) {
    await model.enqueue({
      contextId: "ctx",
      expectedRevision: "7",
      sourceSha256: "a".repeat(64),
      controlId: "control",
      operationId: "older-edit",
      label: "Older",
    });
    labels.length = 0;
  }
  await act(async () => {
    renderer = create(
      createElement(EditorProvider, {
        model,
        children: createElement(LabelScreen),
      }),
    );
  });
  return { labels, model };
}
function button(title: string) {
  return renderer!.root
    .findAll((item) => typeof item.props.title === "string")
    .find((item) => item.props.title === title)!;
}
test("blank label requires deliberate native confirmation and queues empty string", async () => {
  const f = await setup();
  await act(async () => {
    button("Use blank label").props.onPress();
  });
  expect(alerts.at(-1)?.title).toBe("Use a blank label?");
  expect(f.labels).toEqual([]);
  await act(async () => {
    alerts.at(-1)!.buttons.find((item) => item.text === "Use blank label")!
      .onPress!();
  });
  await act(async () => {
    button("Queue").props.onPress();
  });
  expect(f.labels).toEqual([""]);
  expect(backs).toBe(1);
  expect(f.model.getSnapshot().notice?.title).toBe("Queued on this phone");
});
test("generated reset queues null while empty custom text is refused", async () => {
  const f = await setup();
  await act(async () => {
    renderer!.root
      .findByProps({ accessibilityLabel: "Control label" })
      .props.onChangeText("");
  });
  await act(async () => {
    button("Queue").props.onPress();
  });
  expect(f.labels).toEqual([]);
  expect(alerts.at(-1)?.title).toBe("Choose a blank label");
  await act(async () => {
    button("Use generated label").props.onPress();
  });
  await act(async () => {
    button("Queue").props.onPress();
  });
  expect(f.labels).toEqual([null]);
});

test("a new draft does not show an earlier queued success as its own result", async () => {
  const f = await setup(true);
  expect(f.model.getSnapshot().notice?.title).toBe("Queued on this phone");
  expect(JSON.stringify(renderer!.toJSON())).not.toContain(
    "Queued on this phone",
  );
  expect(f.labels).toEqual([]);
});
