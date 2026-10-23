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
  private readonly pipe: NativePipe<void, unknown>;
  private wowState = disabledWowSyncStatus();
  private captureState = disabledWowCaptureStatus();
  private readonly wowJobs = new Map<string, WowSyncStatus>();
  private readonly wowIntents = new Map<string, string>();
  private wowRequest = false;
  private cacheWow(sync: WowSyncStatus): void {
    this.wowState = sync;
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
          exact(value, ["version", "ready", "pid"]);
          if (
            value.version !== 1 ||
            value.ready !== "configuration" ||
            value.pid !== pid
          )
            throw new Error("configuration_ready_invalid");
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
  get ready() {
    return this.pipe.ready;
  }
  get child() {
    return this.pipe.child;
  }
  async request(input: ConfigurationCommand): Promise<ConfigurationReply> {
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
      if (this.activeJob !== undefined || this.phoneRead)
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
        });
      return pending;
    }
    if (this.activeJob !== undefined || this.phoneRead)
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
    }
  }
  async readSavedPin(input: SavedPinCommand): Promise<SavedConfigurationPin> {
    const command = decodeSavedPinCommand(input);
    await this.ready;
    if (this.activeJob !== undefined || this.phoneRead)
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
    }
  }
  async readControlsForPhone(
    input: PhoneControlsCommand,
  ): Promise<PhoneControlsResult> {
    const command = decodePhoneControlsCommand(input);
    await this.ready;
    if (
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
    }
  }
  async readPresentationForPhone(
    input: AnyPhonePresentationCommand,
  ): Promise<PhonePresentationResult> {
    const command = decodeAnyPhonePresentationCommand(input);
    await this.ready;
    if (
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
    }
  }
  disconnect(): void {
    this.pipe.disconnect();
  }
}
