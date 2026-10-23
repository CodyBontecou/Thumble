import { requireNativeModule } from "expo-modules-core";
import { decodePhoneCatalogNotification } from "@thumble/contracts/phone-catalog";

export type EditorCacheSummary = Readonly<{
  contextId: string;
  profileId: string;
  name: string;
  revision: string;
  sourceSha256: string;
  controlCount: number;
}>;
export type EditorQueueEntry = Readonly<{
  operationId: string;
  profileId: string;
  controlId: string;
  expectedRevision: string;
  label: string | null;
  status: "queued" | "uncertain" | "rejected" | "conflict";
  conflictRevision: string | null;
}>;
export type EditorSnapshot = Readonly<{
  profiles: readonly EditorCacheSummary[];
  queue: readonly EditorQueueEntry[];
  selection: string | null;
}>;
export type EditorCachePage = Readonly<{
  contextId: string;
  offset: number;
  nextOffset: number | null;
  controls: readonly Readonly<{
    id: string;
    generatedLabel: string;
    labelOverride: string | null;
  }>[];
}>;
export type EditorEnqueue = Readonly<{
  contextId: string;
  expectedRevision: string;
  sourceSha256: string;
  controlId: string;
  operationId: string;
  label: string | null;
}>;
/** Deliberately fixed methods. No ACK, authority, phone epoch, vault, or generic RPC API. */
export interface EditorNativeBridge {
  editorOpen(): Promise<string>;
  editorSnapshot(id: string): Promise<unknown>;
  editorCachePage(
    id: string,
    contextId: string,
    offset: number,
  ): Promise<unknown>;
  editorRead(
    id: string,
    profileId: string,
    revision: string,
    hash: string,
  ): Promise<unknown>;
  editorCatalog(
    id: string,
    revision: string | null,
    offset: number,
  ): Promise<unknown>;
  editorSelect(id: string, contextId: string | null): Promise<void>;
  editorEnqueue(
    id: string,
    contextId: string,
    revision: string,
    hash: string,
    controlId: string,
    operationId: string,
    label: string | null,
  ): Promise<void>;
  editorSubmit(id: string, operationId: string): Promise<string>;
  editorReconcile(id: string, operationId: string): Promise<string>;
  editorCancel(id: string): Promise<void>;
  editorClose(id: string): Promise<void>;
}
function object(
  value: unknown,
  keys: readonly string[],
): Record<string, unknown> {
  if (
    !value ||
    typeof value !== "object" ||
    Array.isArray(value) ||
    Object.keys(value).sort().join() !== [...keys].sort().join()
  )
    throw Error("editor_invalid_response");
  return value as Record<string, unknown>;
}
function text(value: unknown, maximum = 1024): string {
  if (typeof value !== "string" || value.length > maximum)
    throw Error("editor_invalid_response");
  return value;
}
function nullable(value: unknown): string | null {
  return value === null ? null : text(value);
}
function integer(value: unknown, maximum: number): number {
  if (
    typeof value !== "number" ||
    !Number.isSafeInteger(value) ||
    value < 0 ||
    value > maximum
  )
    throw Error("editor_invalid_response");
  return value;
}
function array(value: unknown, maximum: number): unknown[] {
  if (!Array.isArray(value) || value.length > maximum)
    throw Error("editor_invalid_response");
  return value;
}
export function decodeEditorSnapshot(value: unknown): EditorSnapshot {
  const v = object(value, ["profiles", "queue", "selection"]);
  const profiles = Object.freeze(
    array(v.profiles, 8).map((item) => {
      const p = object(item, [
        "contextId",
        "profileId",
        "name",
        "revision",
        "sourceSha256",
        "controlCount",
      ]);
      return Object.freeze({
        contextId: text(p.contextId, 36),
        profileId: text(p.profileId, 36),
        name: text(p.name),
        revision: text(p.revision, 20),
        sourceSha256: text(p.sourceSha256, 64),
        controlCount: integer(p.controlCount, 128),
      });
    }),
  );
  const queue = Object.freeze(
    array(v.queue, 128).map((item) => {
      const p = object(item, [
        "operationId",
        "profileId",
        "controlId",
        "expectedRevision",
        "label",
        "status",
        "conflictRevision",
      ]);
      const status = text(p.status);
      if (
        status !== "queued" &&
        status !== "uncertain" &&
        status !== "rejected" &&
        status !== "conflict"
      )
        throw Error("editor_invalid_response");
      return Object.freeze({
        operationId: text(p.operationId),
        profileId: text(p.profileId, 36),
        controlId: text(p.controlId, 36),
        expectedRevision: text(p.expectedRevision, 20),
        label: nullable(p.label),
        status,
        conflictRevision: nullable(p.conflictRevision),
      });
    }),
  );
  return Object.freeze({ profiles, queue, selection: nullable(v.selection) });
}
export function decodeEditorCachePage(value: unknown): EditorCachePage {
  const v = object(value, ["contextId", "offset", "nextOffset", "controls"]);
  const controls = Object.freeze(
    array(v.controls, 8).map((item) => {
      const p = object(item, ["id", "generatedLabel", "labelOverride"]);
      return Object.freeze({
        id: text(p.id, 36),
        generatedLabel: text(p.generatedLabel),
        labelOverride: nullable(p.labelOverride),
      });
    }),
  );
  return Object.freeze({
    contextId: text(v.contextId, 36),
    offset: integer(v.offset, 128),
    nextOffset: v.nextOffset === null ? null : integer(v.nextOffset, 128),
    controls,
  });
}
export async function openEditor(
  bridge: EditorNativeBridge = requireNativeModule<EditorNativeBridge>(
    "ThumbleNativeInput",
  ),
) {
  const id = text(await bridge.editorOpen(), 36);
  let closed = false;
  const check = () => {
    if (closed) throw Error("editor_closed");
  };
  const outcome = (result: string): "committed" | "retained" | "conflict" => {
    if (
      result !== "committed" &&
      result !== "retained" &&
      result !== "conflict"
    )
      throw Error("editor_invalid_response");
    return result;
  };
  return Object.freeze({
    snapshot: async () => {
      check();
      return decodeEditorSnapshot(await bridge.editorSnapshot(id));
    },
    cachePage: async (contextId: string, offset = 0) => {
      check();
      return decodeEditorCachePage(
        await bridge.editorCachePage(id, contextId, offset),
      );
    },
    read: async (profileId: string, revision: string, sourceSha256: string) => {
      check();
      return decodeEditorSnapshot(
        await bridge.editorRead(id, profileId, revision, sourceSha256),
      );
    },
    catalog: async (revision: string | null = null, offset = 0) => {
      check();
      const value = await bridge.editorCatalog(id, revision, offset);
      if (
        value &&
        typeof value === "object" &&
        "kind" in value &&
        value.kind === "conflict"
      ) {
        const conflict = object(value, ["kind", "currentRevision"]);
        return Object.freeze({
          kind: "conflict" as const,
          currentRevision: text(conflict.currentRevision, 20),
        });
      }
      return decodePhoneCatalogNotification(value);
    },
    select: async (contextId: string | null) => {
      check();
      await bridge.editorSelect(id, contextId);
    },
    enqueue: async (edit: EditorEnqueue) => {
      check();
      await bridge.editorEnqueue(
        id,
        edit.contextId,
        edit.expectedRevision,
        edit.sourceSha256,
        edit.controlId,
        edit.operationId,
        edit.label,
      );
    },
    submit: async (operationId: string) => {
      check();
      return outcome(await bridge.editorSubmit(id, operationId));
    },
    reconcile: async (operationId: string) => {
      check();
      return outcome(await bridge.editorReconcile(id, operationId));
    },
    cancel: async () => {
      check();
      await bridge.editorCancel(id);
    },
    close: async () => {
      check();
      closed = true;
      await bridge.editorClose(id);
    },
  });
}
export type NativeEditor = Awaited<ReturnType<typeof openEditor>>;
