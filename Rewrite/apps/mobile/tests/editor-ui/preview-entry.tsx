/** Synthetic UI evidence entry, never the app's published entry point. No native endpoint or vault. */
import { registerRootComponent } from "expo";
import { ExpoRoot } from "expo-router";
import type { RequireContext } from "expo-router/build/types";
declare const require: {
  context(path: string, recursive: boolean, filter: RegExp): RequireContext;
};
import { useRef } from "react";
import EditorLayout from "../../src/app/editor/_layout";
import { EditorModel } from "../../src/editor/editor-model";
import type {
  NativeEditor,
  EditorSnapshot,
  EditorQueueEntry,
} from "../../src/editor/NativeEditorSession";
const id = "aaaaaaaa-0000-0000-0000-000000000001";
const names = [
  "Jump",
  "Interact",
  "Sprint",
  "Map",
  "Inventory",
  "Menu",
  "Left trigger",
  "Right trigger",
  "Target",
  "Camera",
  "Move",
  "Use item",
  "Quest log",
  "Chat",
  "Zoom",
  "Ready check",
  "Very long control label to check wrapping at a larger text size",
  "Additional action",
];
const controls = names.map((generatedLabel, index) => ({
  id: `control-${index}`,
  generatedLabel,
  labelOverride: null as string | null,
}));
let revision = 7,
  contextID = "qa-context-7";
let queue: readonly EditorQueueEntry[] = [
  {
    operationId: "qa-queued",
    profileId: id,
    controlId: "control-1",
    expectedRevision: "7",
    label: "Speak",
    status: "queued",
    conflictRevision: null,
  },
  {
    operationId: "qa-uncertain",
    profileId: id,
    controlId: "control-2",
    expectedRevision: "7",
    label: "",
    status: "uncertain",
    conflictRevision: null,
  },
  {
    operationId: "qa-conflict",
    profileId: id,
    controlId: "control-3",
    expectedRevision: "6",
    label: null,
    status: "conflict",
    conflictRevision: "7",
  },
  {
    operationId: "qa-origin",
    profileId: id,
    controlId: "control-4",
    expectedRevision: "5",
    label: "Inspect",
    status: "uncertain",
    conflictRevision: null,
  },
];
function hash() {
  return revision.toString(16).padStart(64, "0");
}
function snapshot(): EditorSnapshot {
  return {
    profiles: [
      {
        contextId: contextID,
        profileId: id,
        name: "My controller",
        revision: String(revision),
        sourceSha256: hash(),
        controlCount: controls.length,
      },
    ],
    queue,
    selection: contextID,
  };
}
function fixtureNative(): NativeEditor {
  return {
    snapshot: async () => snapshot(),
    cachePage: async (contextId, offset = 0) => {
      if (contextId !== contextID) throw Error("cache_changed");
      const end = Math.min(offset + 8, controls.length);
      return {
        contextId,
        offset,
        nextOffset: end < controls.length ? end : null,
        controls: controls.slice(offset, end),
      };
    },
    select: async () => {},
    read: async (_id, expected, source) => {
      if (expected !== String(revision) || source !== hash())
        throw Error("profile_changed");
      return snapshot();
    },
    catalog: async () => ({
      kind: "catalog",
      revision: String(revision),
      contentHash: hash(),
      activeProfileId: id,
      defaultProfileId: id,
      nextOffset: null,
      profileCount: 1,
      profile0Id: id,
      profile0Name: "My controller",
      profile0UpdatedAt: "1",
    }),
    enqueue: async (edit) => {
      if (
        edit.contextId !== contextID ||
        edit.expectedRevision !== String(revision) ||
        edit.sourceSha256 !== hash()
      )
        throw Error("cache_changed");
      if (!queue.some((item) => item.operationId === edit.operationId))
        queue = [
          ...queue,
          {
            operationId: edit.operationId,
            profileId: id,
            controlId: edit.controlId,
            expectedRevision: edit.expectedRevision,
            label: edit.label,
            status: "queued",
            conflictRevision: null,
          },
        ];
    },
    submit: async (operation) => {
      queue = queue.map((item) =>
        item.operationId === operation
          ? { ...item, status: "uncertain" }
          : item,
      );
      return "retained";
    },
    reconcile: async (operation) => {
      if (operation === "qa-origin")
        throw Object.assign(Error("origin-reconciliation-required"), {
          code: "origin-reconciliation-required",
        });
      const entry = queue.find((item) => item.operationId === operation);
      if (!entry || entry.status === "conflict") return "conflict";
      if (entry.expectedRevision !== String(revision)) {
        queue = queue.map((item) =>
          item.operationId === operation
            ? {
                ...item,
                status: "conflict",
                conflictRevision: String(revision),
              }
            : item,
        );
        return "conflict";
      }
      const control = controls.find((item) => item.id === entry.controlId);
      if (control) control.labelOverride = entry.label;
      queue = queue.filter((item) => item.operationId !== operation);
      revision++;
      contextID = `qa-context-${revision}`;
      return "committed";
    },
    cancel: async () => {},
    close: async () => {},
  };
}
function PreviewEditorLayout() {
  const model = useRef<EditorModel | null>(null);
  if (!model.current)
    model.current = new EditorModel(async () => fixtureNative());
  return <EditorLayout model={model.current} />;
}
const original = require.context("../../src/app", true, /\.[jt]sx?$/);
const context = ((path: string) =>
  path === "./editor/_layout.tsx"
    ? { default: PreviewEditorLayout }
    : original(path)) as typeof original;
context.keys = original.keys;
context.resolve = original.resolve;
context.id = original.id;
registerRootComponent(() => <ExpoRoot context={context} />);
