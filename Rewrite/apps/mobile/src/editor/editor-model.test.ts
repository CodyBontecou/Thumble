/// <reference types="bun" />
import { expect, mock, test } from "bun:test";
mock.module("expo-modules-core", () => ({
  requireNativeModule: () => {
    throw Error("native_not_requested");
  },
}));
const { EditorModel } = await import("./editor-model");
import type {
  EditorEnqueue,
  EditorSnapshot,
  NativeEditor,
} from "./NativeEditorSession";
const hash = "a".repeat(64);
const profile = {
  contextId: "cached-context",
  profileId: "profile",
  name: "My controller",
  revision: "7",
  sourceSha256: hash,
  controlCount: 18,
};
const control = { id: "control", generatedLabel: "Jump", labelOverride: null };
function fake() {
  const calls: Array<[string, ...unknown[]]> = [];
  let snapshot: EditorSnapshot = {
    profiles: [profile],
    queue: [],
    selection: null,
  };
  let outcome = "retained";
  let failEnqueue = false,
    failCatalog = false,
    ambiguous = false;
  const bridge: NativeEditor = {
    snapshot: async () => snapshot,
    cachePage: async (id, offset = 0) => {
      calls.push(["cachePage", id, offset]);
      return {
        contextId: id,
        offset,
        nextOffset: offset === 0 ? 8 : null,
        controls:
          offset === 0
            ? [
                control,
                ...Array.from({ length: 7 }, (_, index) => ({
                  ...control,
                  id: `page-one-${index}`,
                })),
              ]
            : [{ ...control, id: "other" }],
      };
    },
    select: async (id) => {
      calls.push(["select", id]);
      snapshot = { ...snapshot, selection: id };
    },
    read: async (id, revision, sourceHash) => {
      calls.push(["read", id, revision, sourceHash]);
      snapshot = {
        ...snapshot,
        profiles: [
          {
            ...profile,
            contextId: "current-context",
            revision,
            sourceSha256: sourceHash,
          },
          ...(ambiguous
            ? [
                {
                  ...profile,
                  contextId: "ambiguous",
                  revision,
                  sourceSha256: sourceHash,
                },
              ]
            : []),
        ],
      };
      return snapshot;
    },
    catalog: async () => {
      calls.push(["catalog"]);
      if (failCatalog) throw Error("offline");
      return {
        kind: "catalog",
        revision: "8",
        contentHash: "b".repeat(64),
        activeProfileId: "profile",
        defaultProfileId: "profile",
        profileCount: 1,
        profile0Id: "profile",
        profile0Name: "My controller",
        profile0UpdatedAt: "1",
        nextOffset: null,
      };
    },
    enqueue: async (edit) => {
      calls.push(["enqueue", edit]);
      if (failEnqueue) throw Error("disk_failed");
      snapshot = {
        ...snapshot,
        queue: [
          ...snapshot.queue,
          {
            operationId: edit.operationId,
            profileId: "profile",
            controlId: edit.controlId,
            expectedRevision: edit.expectedRevision,
            label: edit.label,
            status: "queued",
            conflictRevision: null,
          },
        ],
      };
    },
    submit: async (operation) => {
      calls.push(["submit", operation]);
      snapshot = {
        ...snapshot,
        queue:
          outcome === "committed"
            ? snapshot.queue.filter((item) => item.operationId !== operation)
            : snapshot.queue.map((item) =>
                item.operationId === operation
                  ? {
                      ...item,
                      status: outcome === "conflict" ? "conflict" : "uncertain",
                      conflictRevision: outcome === "conflict" ? "8" : null,
                    }
                  : item,
              ),
      };
      return outcome as "retained" | "committed" | "conflict";
    },
    reconcile: async (operation) => {
      calls.push(["reconcile", operation]);
      if (outcome === "committed")
        snapshot = {
          ...snapshot,
          queue: snapshot.queue.filter(
            (item) => item.operationId !== operation,
          ),
        };
      return outcome as "retained" | "committed" | "conflict";
    },
    cancel: async () => {
      calls.push(["cancel"]);
    },
    close: async () => {
      calls.push(["close"]);
    },
  };
  const model = new EditorModel(async () => bridge);
  return {
    model,
    calls,
    bridge,
    setOutcome: (value: string) => {
      outcome = value;
    },
    failEnqueue: () => {
      failEnqueue = true;
    },
    failCatalog: () => {
      failCatalog = true;
    },
    ambiguous: () => {
      ambiguous = true;
    },
  };
}
function edit(
  label: string | null = "Leap",
  operationId = "original-operation",
): EditorEnqueue {
  return {
    contextId: profile.contextId,
    expectedRevision: "7",
    sourceSha256: hash,
    controlId: control.id,
    operationId,
    label,
  };
}
test("opening is offline and bounded cache uses original context without reading a new base", async () => {
  const f = fake();
  await f.model.open();
  expect(f.calls).toEqual([]);
  expect(await f.model.openCached(profile.contextId)).toBe(true);
  expect(f.calls).toEqual([
    ["cachePage", "cached-context", 0],
    ["select", "cached-context"],
  ]);
  expect(f.model.getSnapshot().current?.revision).toBe("7");
  await f.model.moreControls();
  expect(f.calls.at(-1)).toEqual(["cachePage", "cached-context", 8]);
  expect(f.model.getSnapshot().controls).toHaveLength(9);
  expect(f.model.getSnapshot().controls.at(-1)?.id).toBe("other");
  expect(f.model.getSnapshot().nextControlOffset).toBeNull();
  await f.model.dispose();
  expect(f.calls.at(-1)).toEqual(["close"]);
});
test("blank and generated intents keep distinct native labels and displayed pins", async () => {
  const f = fake();
  await f.model.open();
  expect(await f.model.enqueue(edit("", "blank-operation"))).toBe(true);
  expect(await f.model.enqueue(edit(null, "generated-operation"))).toBe(true);
  expect(f.calls.filter(([name]) => name === "enqueue")).toEqual([
    ["enqueue", edit("", "blank-operation")],
    ["enqueue", edit(null, "generated-operation")],
  ]);
  expect(f.model.getSnapshot().notice?.title).toBe("Queued on this phone");
});
test("failed durable enqueue never reports queued or saved", async () => {
  const f = fake();
  await f.model.open();
  f.failEnqueue();
  expect(await f.model.enqueue(edit())).toBe(false);
  expect(f.model.getSnapshot().snapshot.queue).toEqual([]);
  expect(f.model.getSnapshot().notice?.title).toBe(
    "Couldn’t confirm this change",
  );
});
test("uncertain entries only reconcile original operation; exact commit alone reports saved", async () => {
  const f = fake();
  await f.model.open();
  await f.model.enqueue(edit());
  await f.model.dispatch("original-operation", false);
  expect(f.model.getSnapshot().snapshot.queue[0]?.status).toBe("uncertain");
  expect(f.model.getSnapshot().notice?.title).toBe("Waiting for confirmation");
  await f.model.dispatch("original-operation", false);
  expect(f.calls.filter(([name]) => name === "submit")).toHaveLength(1);
  f.setOutcome("committed");
  f.failCatalog();
  await f.model.dispatch("original-operation", true);
  expect(f.calls.filter(([name]) => name === "reconcile")).toEqual([
    ["reconcile", "original-operation"],
  ]);
  expect(f.model.getSnapshot().snapshot.queue).toHaveLength(0);
  expect(f.model.getSnapshot().notice?.title).toBe("Saved on your Mac");
});
test("conflict keeps original queued intent and never rebases or creates a replacement", async () => {
  const f = fake();
  await f.model.open();
  await f.model.enqueue(edit());
  f.setOutcome("conflict");
  await f.model.dispatch("original-operation", false);
  const pending = f.model.getSnapshot().snapshot.queue[0]!;
  expect(pending.expectedRevision).toBe("7");
  expect(pending.operationId).toBe("original-operation");
  expect(pending.status).toBe("conflict");
  expect(f.calls.filter(([name]) => name === "enqueue")).toHaveLength(1);
  expect(f.model.getSnapshot().notice?.title).not.toBe("Saved on your Mac");
});
test("ambiguous matching cached origins fail closed when opening a current profile", async () => {
  const f = fake();
  await f.model.open();
  await f.model.refreshCatalog();
  f.ambiguous();
  expect(await f.model.openCurrent("profile")).toBe(false);
  expect(f.calls.filter(([name]) => name === "select")).toHaveLength(0);
  expect(f.model.getSnapshot().current).toBe(null);
});
