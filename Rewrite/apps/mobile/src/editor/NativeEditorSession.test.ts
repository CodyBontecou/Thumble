/// <reference types="bun" />
import { expect, mock, test } from "bun:test";
mock.module("expo-modules-core", () => ({
  requireNativeModule: () => {
    throw Error("native_not_requested");
  },
}));
const { decodeEditorSnapshot, decodeEditorCachePage, openEditor } =
  await import("./NativeEditorSession");
const summary = {
  contextId: "native-context",
  profileId: "profile",
  name: "Profile",
  revision: "7",
  sourceSha256: "a".repeat(64),
  controlCount: 128,
};
test("snapshot contains only bounded summaries and immutable queue data", () => {
  const decoded = decodeEditorSnapshot({
    profiles: [summary],
    queue: [],
    selection: null,
  });
  expect(Object.isFrozen(decoded)).toBe(true);
  expect(Object.isFrozen(decoded.profiles[0])).toBe(true);
  expect(decoded.profiles[0]).not.toHaveProperty("controls");
  expect(() =>
    decodeEditorSnapshot({
      profiles: Array(9).fill(summary),
      queue: [],
      selection: null,
    }),
  ).toThrow();
  expect(() =>
    decodeEditorSnapshot({
      profiles: [],
      queue: [],
      selection: null,
      receipt: {},
    }),
  ).toThrow();
  expect(() =>
    decodeEditorCachePage({
      contextId: "ctx",
      offset: 0,
      nextOffset: null,
      controls: Array(9).fill({
        id: "a",
        generatedLabel: "A",
        labelOverride: null,
      }),
    }),
  ).toThrow();
});
test("facade forwards displayed pins through fixed methods and closes locally", async () => {
  const calls: unknown[][] = [];
  const bridge = {
    editorOpen: async () => "native-session",
    editorSnapshot: async () => ({
      profiles: [summary],
      queue: [],
      selection: null,
    }),
    editorCachePage: async () => ({
      contextId: "native-context",
      offset: 0,
      nextOffset: null,
      controls: [],
    }),
    editorRead: async () => ({ profiles: [], queue: [], selection: null }),
    editorCatalog: async () => ({
      kind: "error",
      error: "phone_catalog_unavailable",
    }),
    editorSelect: async () => {},
    editorEnqueue: async (...args: unknown[]) => {
      calls.push(args);
    },
    editorSubmit: async () => "retained",
    editorReconcile: async () => "committed",
    editorCancel: async () => {},
    editorClose: async () => {},
  };
  const editor = await openEditor(bridge);
  await editor.enqueue({
    contextId: summary.contextId,
    expectedRevision: "7",
    sourceSha256: summary.sourceSha256,
    controlId: "control",
    operationId: "op",
    label: null,
  });
  expect(calls).toEqual([
    [
      "native-session",
      "native-context",
      "7",
      "a".repeat(64),
      "control",
      "op",
      null,
    ],
  ]);
  expect(await editor.submit("op")).toBe("retained");
  expect(await editor.reconcile("op")).toBe("committed");
  expect(await editor.catalog()).toEqual({
    kind: "error",
    error: "phone_catalog_unavailable",
  });
  await editor.close();
  await expect(editor.submit("op")).rejects.toThrow("editor_closed");
});
