import {
  openEditor,
  type NativeEditor,
  type EditorCacheSummary,
  type EditorEnqueue,
  type EditorSnapshot,
} from "./NativeEditorSession";

export type EditorControl = Readonly<{
  id: string;
  generatedLabel: string;
  labelOverride: string | null;
}>;
export type CatalogProfile = Readonly<{ id: string; name: string }>;
export type Catalog = Readonly<{
  revision: string;
  sourceHash: string | null;
  profiles: readonly CatalogProfile[];
  nextOffset: number | null;
}>;
export type EditorState = Readonly<{
  phase: "opening" | "ready" | "unavailable";
  busy: string | null;
  snapshot: EditorSnapshot;
  catalog: Catalog | null;
  current: EditorCacheSummary | null;
  controls: readonly EditorControl[];
  nextControlOffset: number | null;
  notice: Readonly<{ title: string; detail: string; error?: boolean }> | null;
}>;
const emptySnapshot: EditorSnapshot = Object.freeze({
  profiles: [],
  queue: [],
  selection: null,
});
const initial: EditorState = Object.freeze({
  phase: "opening",
  busy: null,
  snapshot: emptySnapshot,
  catalog: null,
  current: null,
  controls: [],
  nextControlOffset: null,
  notice: null,
});
export function editorRecovery(error: unknown): string {
  const code =
    error && typeof error === "object" && "code" in error
      ? String(error.code)
      : "";
  const message = error instanceof Error ? error.message : "";
  if (
    code === "origin-reconciliation-required" ||
    message.includes("origin-reconciliation-required")
  ) {
    return "Your Mac has changed since this edit was queued. The original change is still kept on this phone. Ask your agent to help recover it; sending it to a different copy is not safe.";
  }
  return "Your change stays on this phone. Connect to the same Mac and check its status again. If this keeps happening, ask your agent to review the connection.";
}
function catalogPage(
  value: Awaited<ReturnType<NativeEditor["catalog"]>>,
): Catalog {
  if (value.kind !== "catalog") throw Error("catalog_unavailable");
  const revision = value.revision;
  const hash = value.contentHash;
  if (
    typeof revision !== "string" ||
    (typeof hash !== "string" && hash !== null)
  )
    throw Error("catalog_unavailable");
  const profiles = Array.from({ length: value.profileCount }, (_, index) => {
    const id = value[`profile${index}Id`],
      name = value[`profile${index}Name`];
    if (typeof id !== "string" || typeof name !== "string")
      throw Error("catalog_unavailable");
    return Object.freeze({ id, name });
  });
  return Object.freeze({
    revision,
    sourceHash: hash,
    profiles: Object.freeze(profiles),
    nextOffset: value.nextOffset,
  });
}
/** One native flow owner. UI never reconstructs an intent from a new catalog revision. */
export class EditorModel {
  private value: EditorState = initial;
  private listeners = new Set<() => void>();
  private native: NativeEditor | null = null;
  private disposed = false;
  private opening: Promise<void> | null = null;
  constructor(
    private readonly create: () => Promise<NativeEditor> = openEditor,
  ) {}
  readonly getSnapshot = () => this.value;
  readonly subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };
  private update(change: Partial<EditorState>) {
    if (this.disposed) return;
    this.value = Object.freeze({ ...this.value, ...change });
    for (const listener of this.listeners) listener();
  }
  open(): Promise<void> {
    if (this.opening) return this.opening;
    if (this.native || this.disposed) return Promise.resolve();
    this.update({ phase: "opening", notice: null });
    this.opening = (async () => {
      try {
        const native = await this.create();
        if (this.disposed) {
          await native.close();
          return;
        }
        this.native = native;
        const snapshot = await native.snapshot();
        this.update({ phase: "ready", snapshot });
      } catch {
        const failed = this.native;
        this.native = null;
        if (failed) {
          try {
            await failed.close();
          } catch {}
        }
        this.update({
          phase: "unavailable",
          notice: {
            title: "Editor isn’t ready",
            detail:
              "Connect to your Mac once from Home, then open the editor again. If you already paired, your saved edits are kept; ask your agent to check the connection.",
          },
        });
      } finally {
        this.opening = null;
      }
    })();
    return this.opening;
  }
  private owner(): NativeEditor {
    if (!this.native || this.disposed) throw Error("editor_closed");
    return this.native;
  }
  private async run<T>(
    label: string,
    action: (native: NativeEditor) => Promise<T>,
  ): Promise<T> {
    if (this.value.busy) throw Error("editor_busy");
    this.update({ busy: label, notice: null });
    try {
      return await action(this.owner());
    } finally {
      this.update({ busy: null });
    }
  }
  clearNotice() {
    this.update({ notice: null });
  }
  async refreshCatalog(): Promise<void> {
    try {
      await this.run("Refreshing profiles…", async (native) => {
        const result = await native.catalog();
        if (result.kind === "conflict") throw Error("catalog_changed");
        this.update({ catalog: catalogPage(result) });
      });
    } catch {
      this.update({
        notice: {
          title: "Mac is unavailable",
          detail:
            "You can still edit profiles saved on this phone. Connect to your Mac and refresh profiles when you’re ready.",
          error: true,
        },
      });
    }
  }
  async moreCatalog(): Promise<void> {
    const previous = this.value.catalog;
    if (!previous || previous.nextOffset === null) return;
    try {
      await this.run("Loading profiles…", async (native) => {
        const page = catalogPage(
          await native.catalog(previous.revision, previous.nextOffset!),
        );
        if (
          page.revision !== previous.revision ||
          page.sourceHash !== previous.sourceHash ||
          page.profiles.some((item) =>
            previous.profiles.some((old) => old.id === item.id),
          )
        )
          throw Error("catalog_changed");
        this.update({
          catalog: Object.freeze({
            ...page,
            profiles: Object.freeze([...previous.profiles, ...page.profiles]),
          }),
        });
      });
    } catch {
      this.update({
        notice: {
          title: "Profiles changed",
          detail:
            "Refresh the list before opening another Mac profile. Your queued changes are untouched.",
          error: true,
        },
      });
    }
  }
  private async install(
    native: NativeEditor,
    context: EditorCacheSummary,
  ): Promise<void> {
    const page = await native.cachePage(context.contextId, 0);
    await native.select(context.contextId);
    this.update({
      current: context,
      controls: page.controls,
      nextControlOffset: page.nextOffset,
    });
  }
  async openCached(contextId: string): Promise<boolean> {
    try {
      return await this.run("Opening profile…", async (native) => {
        const snapshot = await native.snapshot();
        const profile = snapshot.profiles.find(
          (item) => item.contextId === contextId,
        );
        if (!profile) throw Error("cache_changed");
        this.update({ snapshot });
        await this.install(native, profile);
        return true;
      });
    } catch {
      this.update({
        notice: {
          title: "Saved copy changed",
          detail:
            "Open the profile again from the current list. Your queued changes are kept separately.",
          error: true,
        },
      });
      return false;
    }
  }
  private uniqueCurrent(
    snapshot: EditorSnapshot,
    id: string,
    catalog: Catalog,
  ): EditorCacheSummary {
    const matches = snapshot.profiles.filter(
      (item) =>
        item.profileId === id &&
        item.revision === catalog.revision &&
        item.sourceSha256 === catalog.sourceHash,
    );
    if (matches.length !== 1) throw Error("ambiguous_saved_copy");
    return matches[0]!;
  }
  async openCurrent(id: string): Promise<boolean> {
    const catalog = this.value.catalog;
    if (!catalog?.sourceHash) {
      this.update({
        notice: {
          title: "Profile needs an update",
          detail:
            "Ask your agent to update this profile before editing labels here.",
          error: true,
        },
      });
      return false;
    }
    try {
      return await this.run("Reading profile…", async (native) => {
        const snapshot = await native.read(
          id,
          catalog.revision,
          catalog.sourceHash!,
        );
        this.update({ snapshot });
        await this.install(native, this.uniqueCurrent(snapshot, id, catalog));
        return true;
      });
    } catch {
      this.update({
        notice: {
          title: "Couldn’t open this profile",
          detail:
            "Refresh profiles and try again. If several saved copies match, ask your agent to review them. Queued changes are kept separately.",
          error: true,
        },
      });
      return false;
    }
  }
  async moreControls(): Promise<void> {
    const profile = this.value.current,
      offset = this.value.nextControlOffset;
    if (!profile || offset === null) return;
    try {
      await this.run("Loading controls…", async (native) => {
        const page = await native.cachePage(profile.contextId, offset);
        if (
          this.value.current?.contextId !== profile.contextId ||
          page.offset !== this.value.controls.length
        )
          throw Error("cache_changed");
        this.update({
          controls: Object.freeze([...this.value.controls, ...page.controls]),
          nextControlOffset: page.nextOffset,
        });
      });
    } catch {
      this.update({
        notice: {
          title: "Saved copy changed",
          detail:
            "Go back and open the profile again. Your queued changes are untouched.",
          error: true,
        },
      });
    }
  }
  async enqueue(edit: EditorEnqueue): Promise<boolean> {
    try {
      return await this.run("Keeping your change…", async (native) => {
        await native.enqueue(edit);
        const snapshot = await native.snapshot();
        if (
          !snapshot.queue.some(
            (entry) => entry.operationId === edit.operationId,
          )
        )
          throw Error("queue_unconfirmed");
        this.update({
          snapshot,
          notice: {
            title: "Queued on this phone",
            detail:
              "Send it when you’re connected. It is not saved on your Mac yet.",
          },
        });
        return true;
      });
    } catch {
      this.update({
        notice: {
          title: "Couldn’t confirm this change",
          detail:
            "Keep this screen open and try again with the same change. Your previous queued changes are still kept.",
          error: true,
        },
      });
      return false;
    }
  }
  async dispatch(operationId: string, reconcile: boolean): Promise<void> {
    try {
      await this.run(
        reconcile ? "Checking change…" : "Sending change…",
        async (native) => {
          const before = this.value.snapshot.queue.find(
            (entry) => entry.operationId === operationId,
          );
          if (!before || (!reconcile && before.status !== "queued"))
            throw Error("check_status_first");
          const outcome = reconcile
            ? await native.reconcile(operationId)
            : await native.submit(operationId);
          this.update({ snapshot: await native.snapshot() });
          if (outcome !== "committed") {
            this.update({
              notice:
                outcome === "conflict"
                  ? {
                      title: "This profile changed on your Mac",
                      detail:
                        "The original edit is kept on this phone. Check again or ask your agent to resolve the change; it won’t be applied to a newer copy automatically.",
                      error: true,
                    }
                  : {
                      title: "Waiting for confirmation",
                      detail:
                        "Your edit is kept on this phone. Check its status before trying to send anything again.",
                    },
            });
            return;
          }
          const selectedId = this.value.current?.profileId;
          try {
            const catalog = catalogPage(await native.catalog());
            this.update({ catalog });
            if (!catalog.sourceHash) throw Error("profile_refresh_unavailable");
            // The queue can reopen without a selected profile after app restart.
            // Refresh the committed profile, while preserving any other open copy.
            const snapshot = await native.read(
              before.profileId,
              catalog.revision,
              catalog.sourceHash,
            );
            const refreshed = this.uniqueCurrent(
              snapshot,
              before.profileId,
              catalog,
            );
            this.update({ snapshot });
            if (selectedId === before.profileId)
              await this.install(native, refreshed);
            this.update({
              notice: {
                title: "Saved on your Mac",
                detail:
                  "Your Mac confirmed this exact change. The profile has been refreshed.",
              },
            });
          } catch {
            this.update({
              notice: {
                title: "Saved on your Mac",
                detail:
                  "Your Mac confirmed this exact change. Refresh profiles to see the latest labels.",
              },
            });
          }
        },
      );
    } catch (error) {
      try {
        this.update({ snapshot: await this.owner().snapshot() });
      } catch {
        /* Preserve prior queue view when storage cannot be read. */
      }
      this.update({
        notice: {
          title: "Change is still on this phone",
          detail: editorRecovery(error),
          error: true,
        },
      });
    }
  }
  async cancel(): Promise<void> {
    try {
      await this.native?.cancel();
    } catch {}
  }
  async dispose(): Promise<void> {
    this.disposed = true;
    this.listeners.clear();
    const native = this.native;
    this.native = null;
    if (native) {
      try {
        await native.close();
      } catch {}
    }
  }
}
let operationSequence = 0;
export function newEditorOperationId(): string {
  operationSequence += 1;
  return `phone-label-${Date.now().toString(36)}-${operationSequence.toString(36)}-${Math.random().toString(36).slice(2, 14)}`;
}
export function controlLabel(control: EditorControl): string {
  return control.labelOverride === ""
    ? "Blank label"
    : (control.labelOverride ?? control.generatedLabel);
}
