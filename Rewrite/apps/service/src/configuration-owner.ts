import {
  decodeEditorLabelCommit,
  decodeEditorReadEnvelope,
  decodeEditorOwnerReadResponse,
  type EditorReadEnvelope,
  type EditorOwnerReadResponse,
  decodeEditorOwnerResponse,
  editorLifetimeId,
  type EditorLabelCommit,
  type EditorOwnerResponse,
} from "./editor-owner-envelope.ts";
import { confirmEditorWriterExit } from "./editor-owner-exit.ts";
import {
  decodeAnyPhonePresentationCommand,
  decodeAnyPhonePresentationResult,
  type AnyPhonePresentationCommand,
  type PhonePresentationResult,
} from "@thumble/contracts/phone-presentation";
import {
  decodeWowSyncCommand,
  decodeWowSyncStatus,
  disabledWowSyncStatus,
  type WowSyncCommand,
  type WowSyncStatus,
} from "@thumble/contracts/wow-sync-control";
import {
  decodeWowCaptureCommand,
  decodeWowCaptureControlStatus,
  disabledWowCaptureStatus,
  type WowCaptureCommand,
  type WowCaptureControlStatus,
} from "@thumble/contracts/wow-capture-control";
import {
  decodePhoneControlsCommand,
  decodePhoneControlsResult,
  type PhoneControlsCommand,
  type PhoneControlsResult,
} from "@thumble/contracts/phone-controls";
import {
  decodeSavedPinCommand,
  decodeSavedConfigurationPin,
  type SavedPinCommand,
  type SavedConfigurationPin,
} from "@thumble/contracts/saved-runtime";
import { configurationExportIntent } from "@thumble/application/configuration-export";
import { configurationImportIntent } from "@thumble/application/configuration-import";
import { NativePipe } from "./native-pipe.ts";
import { exact } from "@thumble/contracts/receiver";
import {
  decodeConfigurationCommand,
  decodeConfigurationReply,
  type ConfigurationCommand,
  type ConfigurationReply,
} from "@thumble/contracts/configuration";

/** Private child owner. Database decoding/fsync never runs on input heartbeat IO. */
export class ConfigurationOwner {
  private readonly pipe: NativePipe<string | undefined, unknown>;
  private editorDispatchClosed = false;
  private editorRetirement: Promise<void> | undefined;
  private editorWrite = false;
  private editorTurnChanged: (() => void) | undefined;
  private wowState = disabledWowSyncStatus();
  private captureState = disabledWowCaptureStatus();
  private readonly wowJobs = new Map<string, WowSyncStatus>();
  private readonly wowIntents = new Map<string, string>();
  private wowRequest = false;
  private cacheWow(sync: WowSyncStatus): void {
    this.wowState = sync;
    this.notifyEditorTurn();
    if (sync.operationId) this.wowJobs.set(sync.operationId, sync);
    while (this.wowJobs.size > 32) {
      const id = this.wowJobs.keys().next().value!;
      this.wowJobs.delete(id);
      this.wowIntents.delete(id);
    }
  }
  private readonly jobs = new Map<
    string,
    { fingerprint: string; reply: ConfigurationReply }
  >();
  private phoneRead = false;
  private ordinaryReads = 0;
  private activeJob: string | undefined;
  constructor(
    executable: string,
    directory: string,
    launcher: readonly string[],
    helpers?: Readonly<{ capture?: string; profile?: string }>,
  ) {
    this.wowState = disabledWowSyncStatus(
      Boolean(helpers?.capture && helpers?.profile),
    );
    if (helpers?.capture)
      this.captureState = {
        ...disabledWowCaptureStatus(),
        enabled: true,
        state: "stopped",
      };
    if (launcher.length === 0)
      throw new Error("configuration_launcher_invalid");
    this.pipe = new NativePipe(
      launcher[0]!,
      [
        ...launcher.slice(1),
        "__configuration",
        "run",
        "--runtime-dir",
        directory,
        "--receiver",
        executable,
        ...(helpers?.capture ? ["--capture-helper", helpers.capture] : []),
        ...(helpers?.profile ? ["--wow-profile-helper", helpers.profile] : []),
      ],
      {
        ready(value, pid) {
          const hasLifetime = Object.hasOwn(value, "ownerLifetimeId");
          exact(
            value,
            hasLifetime
              ? ["version", "ready", "pid", "ownerLifetimeId"]
              : ["version", "ready", "pid"],
          );
          if (
            value.version !== 1 ||
            value.ready !== "configuration" ||
            value.pid !== pid
          )
            throw new Error("configuration_ready_invalid");
          return hasLifetime
            ? editorLifetimeId(value.ownerLifetimeId)
            : undefined;
        },
        event: (value) => {
          exact(value, ["version", "event", "capture", "sync"]);
          if (value.version !== 1 || value.event !== "wow-state")
            throw new Error("configuration_event_invalid");
          this.captureState = decodeWowCaptureControlStatus(value.capture);
          this.cacheWow(decodeWowSyncStatus(value.sync));
        },
        reply(value) {
          exact(value, ["version", "requestId", "ok", "result"]);
          return value.result;
        },
      },
      "configuration_owner_unavailable",
    );
  }
  get ready(): Promise<void> {
    return this.pipe.ready.then(() => {});
  }
  get child() {
    return this.pipe.child;
  }
  /** No caller-selected/replacement lifetime. Legacy readonly test owners lack it. */
  async editorOwnerLifetime(): Promise<string> {
    const lifetime = await this.pipe.ready;
    if (this.editorDispatchClosed || !lifetime)
      throw new Error("editor_owner_unavailable");
    return lifetime;
  }
  closeEditorDispatch(): void {
    this.editorDispatchClosed = true;
    this.notifyEditorTurn();
  }
  /** Retire this exact captured child, including idle writers holding SQLite.
   * Idempotence shares actual exit confirmation with an in-flight write loss. */
  retireEditorOwner(): Promise<void> {
    this.closeEditorDispatch();
    if (!this.editorRetirement) {
      this.pipe.disconnect();
      this.editorRetirement = confirmEditorWriterExit(this.child);
    }
    return this.editorRetirement;
  }
  /** Private label seam. Native must retain its independent ticket until
   * this definitive result; pending/timeout is never a no-op acknowledgement. */
  async commitEditorLabel(
    input: EditorLabelCommit,
  ): Promise<
    | { kind: "not-dispatched"; error: string }
    | { kind: "owner-response"; response: EditorOwnerResponse }
    | { kind: "owner-error"; error: string }
    | { kind: "writer-exited"; disposition: "unknown" }
  > {
    const envelope = decodeEditorLabelCommit(input);
    let lifetime: string;
    try {
      lifetime = await this.editorOwnerLifetime();
    } catch {
      return { kind: "not-dispatched", error: "editor_owner_unavailable" };
    }
    if (this.editorDispatchClosed || lifetime !== envelope.ownerLifetimeId)
      return {
        kind: "not-dispatched",
        error: "editor_owner_lifetime_mismatch",
      };
    if (this.editorWrite)
      return { kind: "not-dispatched", error: "configuration_owner_busy" };
    // Reserve the only write before awaiting preexisting work. New operations
    // cannot overtake this exact pinned intent, and no replacement child is used.
    this.editorWrite = true;
    const deadline = performance.now() + 30000;
    try {
      await this.waitForEditorTurn();
      if (this.editorDispatchClosed)
        throw new Error("editor_owner_unavailable");
      const remaining = Math.floor(deadline - performance.now());
      if (remaining < 1) throw new Error("editor_owner_unavailable");
      const result = await this.pipe.requestParsed(envelope, remaining);
      if (result.kind === "not-dispatched") {
        this.editorWrite = false;
        return result;
      }
      if (!result.ok) {
        this.editorWrite = false;
        return { kind: "owner-error", error: result.error };
      }
      const response = decodeEditorOwnerResponse(result.result, envelope);
      this.editorWrite = false;
      return { kind: "owner-response", response };
    } catch {
      // Close admission BEFORE disconnect/await; no future queue may target this child.
      await this.retireEditorOwner();
      this.editorWrite = false;
      return { kind: "writer-exited", disposition: "unknown" };
    }
  }
  private editorTurnAvailable(): boolean {
    return !(
      this.activeJob !== undefined ||
      this.phoneRead ||
      this.ordinaryReads ||
      this.wowRequest
    );
  }
  private notifyEditorTurn(): void {
    if (this.editorDispatchClosed || this.editorTurnAvailable())
      this.editorTurnChanged?.();
  }
  /** One reserved editor operation waits on the captured owner's existing
   * work. A health timeout retires that child; it never proves a no-op. */
  private waitForEditorTurn(): Promise<void> {
    if (this.editorDispatchClosed)
      return Promise.reject(new Error("editor_owner_unavailable"));
    if (this.editorTurnAvailable()) return Promise.resolve();
    return new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.editorTurnChanged = undefined;
        reject(new Error("editor_owner_unavailable"));
      }, 30000);
      this.editorTurnChanged = () => {
        clearTimeout(timer);
        this.editorTurnChanged = undefined;
        if (this.editorDispatchClosed)
          reject(new Error("editor_owner_unavailable"));
        else resolve();
      };
    });
  }
  /** Captured owner only; readonly replies cannot settle a write ticket. */
  async readEditor(
    input: EditorReadEnvelope,
  ): Promise<EditorOwnerReadResponse> {
    const envelope = decodeEditorReadEnvelope(input);
    const lifetime = await this.editorOwnerLifetime();
    if (this.editorDispatchClosed || lifetime !== envelope.ownerLifetimeId)
      throw new Error("editor_owner_lifetime_mismatch");
    if (
      this.editorWrite ||
      this.activeJob !== undefined ||
      this.phoneRead ||
      this.ordinaryReads ||
      this.wowRequest ||
      this.wowState.busy
    )
      throw new Error("configuration_owner_busy");
    this.phoneRead = true;
    try {
      const result = await this.pipe.requestParsed(envelope);
      if (result.kind !== "owner-response" || !result.ok)
        throw new Error(
          result.kind === "owner-response"
            ? result.error
            : "editor_owner_unavailable",
        );
      return decodeEditorOwnerReadResponse(result.result, envelope);
    } finally {
      this.phoneRead = false;
      this.notifyEditorTurn();
    }
  }
  async request(input: ConfigurationCommand): Promise<ConfigurationReply> {
    if (this.editorWrite) throw new Error("configuration_owner_busy");
    const command = decodeConfigurationCommand(input);
    if (
      (this.wowState.busy || this.wowRequest) &&
      command.command !== "configuration-list" &&
      command.command !== "configuration-import-status" &&
      command.command !== "configuration-export-status"
    )
      throw new Error("configuration_owner_busy");
    if (
      command.command === "configuration-import-status" ||
      command.command === "configuration-export-status"
    ) {
      const job = this.jobs.get(command.operationId);
      if (!job)
        throw new Error(
          command.command === "configuration-import-status"
            ? "configuration_import_unknown"
            : "configuration_export_unknown",
        );
      if (
        job.fingerprint !==
        (command.command === "configuration-import-status"
          ? configurationImportIntent(command)
          : configurationExportIntent(command))
      )
        throw new Error("operation_id_reused");
      return decodeConfigurationReply(job.reply, command);
    }
    await this.ready;
    if (
      command.command === "configuration-import-file" ||
      command.command === "configuration-export-file"
    ) {
      const importing = command.command === "configuration-import-file";
      const fingerprint =
        command.command === "configuration-import-file"
          ? configurationImportIntent(command)
          : configurationExportIntent(command);
      const previous = this.jobs.get(command.operationId);
      if (previous && previous.fingerprint !== fingerprint)
        throw new Error("operation_id_reused");
      if (
        previous &&
        previous.reply.kind !== "import-failed" &&
        previous.reply.kind !== "export-failed" &&
        previous.reply.kind !== "exported"
      ) {
        const reply =
          previous.reply.kind === "import-committed"
            ? { ...previous.reply, replayed: true }
            : previous.reply;
        return decodeConfigurationReply(reply, command);
      }
      if (this.editorWrite || this.activeJob !== undefined || this.phoneRead)
        throw new Error("configuration_owner_busy");
      if (this.jobs.size >= 32 && !previous) {
        const oldest = this.jobs.keys().next().value;
        if (oldest !== undefined) this.jobs.delete(oldest);
      }
      const pending = Object.freeze({
        version: 1,
        kind: importing ? "import-pending" : "export-pending",
        operationId: command.operationId,
      } as const);
      this.jobs.set(command.operationId, { fingerprint, reply: pending });
      this.activeJob = command.operationId;
      // A slow child holds only this bounded background promise. Polling and the
      // parent's input heartbeat never wait for its synchronous file/fsync work.
      void this.pipe
        .request(command, 30000)
        .then((value) => {
          let reply: ConfigurationReply;
          try {
            reply = decodeConfigurationReply(value, command);
            if (
              reply.kind !== (importing ? "import-committed" : "exported") &&
              reply.kind !== "conflict"
            )
              throw new Error("configuration_response_invalid");
          } catch {
            throw new Error("configuration_response_invalid");
          }
          this.jobs.set(command.operationId, { fingerprint, reply });
        })
        .catch((error) => {
          const code =
            error instanceof Error && /^[a-z_]{1,80}$/.test(error.message)
              ? error.message
              : importing
                ? "configuration_import_failed"
                : "configuration_export_failed";
          this.jobs.set(command.operationId, {
            fingerprint,
            reply: Object.freeze({
              version: 1,
              kind: importing ? "import-failed" : "export-failed",
              operationId: command.operationId,
              error: code,
            }),
          });
          if (
            code === "configuration_owner_unavailable" ||
            code === "configuration_response_invalid"
          ) {
            this.pipe.disconnect();
            this.child.kill("SIGKILL");
          }
        })
        .finally(() => {
          this.activeJob = undefined;
          this.notifyEditorTurn();
        });
      return pending;
    }
    if (this.editorWrite || this.activeJob !== undefined || this.phoneRead)
      throw new Error("configuration_owner_busy");
    this.ordinaryReads++;
    try {
      const value = await this.pipe.request(command);
      try {
        return decodeConfigurationReply(value, command);
      } catch {
        this.pipe.disconnect();
        throw new Error("configuration_response_invalid");
      }
    } finally {
      this.ordinaryReads--;
      this.notifyEditorTurn();
    }
  }
  /** The phone abandons after 2s; this single underlying read retains its 30s owner health budget. */
  async readCatalogForPhone(
    input: Extract<ConfigurationCommand, { command: "configuration-list" }>,
  ): Promise<ConfigurationReply> {
    const command = decodeConfigurationCommand(input);
    if (command.command !== "configuration-list")
      throw new Error("invalid_phone_catalog_command");
    await this.ready;
    if (
      this.editorWrite ||
      this.phoneRead ||
      this.activeJob !== undefined ||
      this.ordinaryReads !== 0
    )
      throw new Error("configuration_owner_busy");
    this.phoneRead = true;
    try {
      const value = await this.pipe.request(command, 30000);
      try {
        const reply = decodeConfigurationReply(value, command);
        if (reply.kind !== "catalog" && reply.kind !== "conflict")
          throw new Error("configuration_response_invalid");
        return reply;
      } catch {
        this.pipe.disconnect();
        this.child.kill("SIGKILL");
        throw new Error("configuration_response_invalid");
      }
    } catch (error) {
      if (
        error instanceof Error &&
        error.message === "configuration_owner_unavailable"
      ) {
        this.pipe.disconnect();
        this.child.kill("SIGKILL");
      }
      throw error;
    } finally {
      this.phoneRead = false;
      this.notifyEditorTurn();
    }
  }
  async requestWowCapture(
    input: WowCaptureCommand,
  ): Promise<WowCaptureControlStatus> {
    const command = decodeWowCaptureCommand(input);
    await this.ready;
    if (command.command === "wow-capture-status") return this.captureState;
    if (!this.captureState.enabled) throw new Error("wow_capture_not_enabled");
    if (
      this.editorWrite ||
      this.activeJob !== undefined ||
      this.phoneRead ||
      this.ordinaryReads ||
      this.wowState.busy ||
      this.wowRequest
    )
      throw new Error("configuration_owner_busy");
    this.wowRequest = true;
    try {
      this.captureState = decodeWowCaptureControlStatus(
        await this.pipe.request(command),
      );
      return this.captureState;
    } finally {
      this.wowRequest = false;
      this.notifyEditorTurn();
    }
  }
  async requestWowSync(input: WowSyncCommand): Promise<WowSyncStatus> {
    const command = decodeWowSyncCommand(input);
    await this.ready;
    if (command.command === "wow-sync-status") {
      if (command.operationId === null) return this.wowState;
      const previous = this.wowJobs.get(command.operationId);
      if (!previous) throw new Error("wow_sync_unknown");
      return previous;
    }
    if (
      this.editorWrite ||
      this.activeJob !== undefined ||
      this.phoneRead ||
      this.ordinaryReads ||
      this.wowRequest
    )
      throw new Error("configuration_owner_busy");
    if (command.command !== "wow-sync-stop") {
      const fingerprint = JSON.stringify([
        command.command,
        command.expectedRevision,
        command.expectedSourceHash,
      ]);
      const old = this.wowIntents.get(command.operationId);
      if (old && old !== fingerprint) throw new Error("operation_id_reused");
      if (old) return this.wowJobs.get(command.operationId)!;
      if (this.wowState.busy) throw new Error("configuration_owner_busy");
      this.wowIntents.set(command.operationId, fingerprint);
    }
    this.wowRequest = true;
    try {
      const result = decodeWowSyncStatus(await this.pipe.request(command));
      this.cacheWow(result);
      return result;
    } catch (error) {
      if (
        command.command !== "wow-sync-stop" &&
        !this.wowJobs.has(command.operationId)
      )
        this.wowIntents.delete(command.operationId);
      throw error;
    } finally {
      this.wowRequest = false;
      this.notifyEditorTurn();
    }
  }
  async readSavedPin(input: SavedPinCommand): Promise<SavedConfigurationPin> {
    const command = decodeSavedPinCommand(input);
    await this.ready;
    if (this.editorWrite || this.activeJob !== undefined || this.phoneRead)
      throw new Error("configuration_owner_busy");
    this.ordinaryReads++;
    try {
      const value = await this.pipe.request(command);
      try {
        const pin = decodeSavedConfigurationPin(value);
        if (
          pin.configurationRevision !== command.expectedRevision ||
          pin.sourceHash !== command.expectedSourceHash ||
          pin.profileId !== command.profileId
        )
          throw new Error("configuration_response_invalid");
        return pin;
      } catch {
        this.pipe.disconnect();
        this.child.kill("SIGKILL");
        throw new Error("configuration_response_invalid");
      }
    } finally {
      this.ordinaryReads--;
      this.notifyEditorTurn();
    }
  }
  async readControlsForPhone(
    input: PhoneControlsCommand,
  ): Promise<PhoneControlsResult> {
    const command = decodePhoneControlsCommand(input);
    await this.ready;
    if (
      this.editorWrite ||
      this.phoneRead ||
      this.activeJob !== undefined ||
      this.ordinaryReads !== 0
    )
      throw new Error("configuration_owner_busy");
    this.phoneRead = true;
    try {
      const value = await this.pipe.request(command, 30000);
      try {
        return decodePhoneControlsResult(value, command);
      } catch {
        this.pipe.disconnect();
        this.child.kill("SIGKILL");
        throw new Error("configuration_response_invalid");
      }
    } catch (error) {
      if (
        error instanceof Error &&
        error.message === "configuration_owner_unavailable"
      ) {
        this.pipe.disconnect();
        this.child.kill("SIGKILL");
      }
      throw error;
    } finally {
      this.phoneRead = false;
      this.notifyEditorTurn();
    }
  }
  async readPresentationForPhone(
    input: AnyPhonePresentationCommand,
  ): Promise<PhonePresentationResult> {
    const command = decodeAnyPhonePresentationCommand(input);
    await this.ready;
    if (
      this.editorWrite ||
      this.phoneRead ||
      this.activeJob !== undefined ||
      this.ordinaryReads !== 0
    )
      throw new Error("configuration_owner_busy");
    this.phoneRead = true;
    try {
      const value = await this.pipe.request(command, 30000);
      try {
        return decodeAnyPhonePresentationResult(value, command);
      } catch {
        this.pipe.disconnect();
        this.child.kill("SIGKILL");
        throw new Error("configuration_response_invalid");
      }
    } catch (error) {
      if (
        error instanceof Error &&
        error.message === "configuration_owner_unavailable"
      ) {
        this.pipe.disconnect();
        this.child.kill("SIGKILL");
      }
      throw error;
    } finally {
      this.phoneRead = false;
      this.notifyEditorTurn();
    }
  }
  disconnect(): void {
    this.closeEditorDispatch();
    this.pipe.disconnect();
  }
}
