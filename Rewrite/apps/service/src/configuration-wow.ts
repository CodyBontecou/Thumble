import { createHash, randomUUID } from "node:crypto";
import type { ConfigurationRepository } from "@thumble/application/configuration-store";
import {
  WowProfileRefresh,
  type WowProfilePreparer,
} from "@thumble/application/wow-profile-refresh";
import { WowSyncSession } from "@thumble/application/wow-sync-session";
import {
  decodeWowSyncCommand,
  disabledWowSyncStatus,
  type WowSyncCommand,
  type WowSyncStatus,
} from "@thumble/contracts/wow-sync-control";
import type {
  WowCaptureCommand,
  WowCaptureControlStatus,
} from "@thumble/contracts/wow-capture-control";
import { disabledWowCaptureStatus } from "@thumble/contracts/wow-capture-control";
import { configurationSourceHash } from "@thumble/storage";
import { WowCaptureSession } from "./wow-capture-session.ts";
import { wowLiveProfileId } from "./wow-profile-preparer.ts";
const digest = (text: string | Uint8Array) =>
  createHash("sha256").update(text).digest("hex");
/** This owner is composed only inside the sole configuration process. Pixels and
 * decoded source never cross its private status boundary. No runtime/input port. */
export class ConfigurationWowOperations {
  private state: WowSyncStatus;
  private readonly jobs = new Map<
    string,
    { fingerprint: string; status: WowSyncStatus }
  >();
  private token = 0;
  private session: WowSyncSession | undefined;
  private inflight: Promise<void> | undefined;
  private active = false;
  private fenced = false;
  private readonly clock: () => number;
  constructor(
    private readonly ports: Readonly<{
      repository: ConfigurationRepository;
      capture?: WowCaptureSession;
      preparer?: WowProfilePreparer;
      readAsset: (hash: string) => Uint8Array;
      publish: (capture: WowCaptureControlStatus, sync: WowSyncStatus) => void;
      clock?: () => number;
      pause?: (ms: number) => Promise<void>;
    }>,
  ) {
    this.clock = ports.clock ?? (() => Math.floor(performance.now()));
    this.state = disabledWowSyncStatus(
      Boolean(ports.capture && ports.preparer),
    );
  }
  get busy(): boolean {
    return this.active;
  }
  captureStatus(): WowCaptureControlStatus {
    return this.ports.capture?.status() ?? disabledWowCaptureStatus();
  }
  status(): WowSyncStatus {
    return this.state;
  }
  private update(patch: Partial<WowSyncStatus> = {}): void {
    this.state = Object.freeze({ ...this.state, ...patch, busy: this.active });
    if (this.state.operationId) {
      const job = this.jobs.get(this.state.operationId);
      if (job) job.status = this.state;
    }
    this.ports.publish(this.captureStatus(), this.state);
  }
  async capture(command: WowCaptureCommand): Promise<WowCaptureControlStatus> {
    if (!this.ports.capture) {
      if (command.command !== "wow-capture-status")
        throw new Error("wow_capture_not_enabled");
      return disabledWowCaptureStatus();
    }
    if (command.command === "wow-capture-status") return this.captureStatus();
    if (this.active || this.fenced) throw new Error("configuration_owner_busy");
    const result = await this.ports.capture.execute(command);
    this.update();
    return result;
  }
  execute(input: WowSyncCommand): WowSyncStatus {
    const command = decodeWowSyncCommand(input);
    if (command.command === "wow-sync-status") {
      if (command.operationId === null) return this.state;
      const job = this.jobs.get(command.operationId);
      if (!job) throw new Error("wow_sync_unknown");
      return job.status;
    }
    if (command.command === "wow-sync-stop") {
      if (command.operationId !== this.state.operationId)
        throw new Error("wow_sync_unknown");
      if (!this.active || this.state.state === "stopping") return this.state;
      ++this.token;
      this.session?.stop();
      this.update({ state: "stopping" });
      const pipeline = this.inflight;
      void Promise.all([
        pipeline,
        this.ports.capture!.execute({ command: "wow-capture-stop" }),
      ])
        .then(() => {
          if (this.captureStatus().state !== "stopped") {
            this.fenced = true;
            this.update({
              state: "failed",
              error: "wow_sync_cleanup_unconfirmed",
            });
          } else this.update({ state: "stopped" });
          this.active = false;
          this.update();
        })
        .catch(() => {
          this.fenced = true;
          this.active = false;
          this.update({
            state: "failed",
            error: "wow_sync_cleanup_unconfirmed",
          });
        });
      return this.state;
    }
    if (!this.state.enabled) throw new Error("wow_sync_not_enabled");
    const fingerprint = JSON.stringify([
      command.command,
      command.expectedRevision,
      command.expectedSourceHash,
    ]);
    const old = this.jobs.get(command.operationId);
    if (old) {
      if (old.fingerprint !== fingerprint)
        throw new Error("operation_id_reused");
      return old.status;
    }
    if (this.active || this.fenced) throw new Error("configuration_owner_busy");
    const current = this.ports.repository.current();
    if (
      (current?.revision ?? "0") !== command.expectedRevision ||
      (current?.contentHash ?? null) !== command.expectedSourceHash
    )
      throw new Error("configuration_revision_conflict");
    if (this.jobs.size >= 32) this.jobs.delete(this.jobs.keys().next().value!);
    this.active = true;
    const token = ++this.token;
    this.state = Object.freeze({
      ...disabledWowSyncStatus(true),
      state: command.command === "wow-refresh" ? "refreshing" : "running",
      operationId: command.operationId,
      mode: command.command === "wow-refresh" ? "manual" : "live",
    });
    this.jobs.set(command.operationId, { fingerprint, status: this.state });
    this.update();
    this.inflight = this.run(
      token,
      command.expectedRevision,
      command.expectedSourceHash,
    );
    return this.state;
  }
  private async run(
    token: number,
    revision: string,
    hash: string | null,
  ): Promise<void> {
    const capture = this.ports.capture!,
      deadline = this.clock() + 30_000;
    let operation: string = randomUUID();
    const refresh = new WowProfileRefresh(this.ports.repository, {
      clock: this.clock,
      currentCapture: (frame) => capture.isCurrent(frame),
      readAsset: this.ports.readAsset,
      resourceHash: (bytes) => digest(bytes),
      digest,
      sourceHash: configurationSourceHash,
      profileId: wowLiveProfileId,
      operationId: () => operation,
      preparer: this.ports.preparer!,
    });
    const makeSession = () =>
      new WowSyncSession({
        clock: this.clock,
        currentCapture: (frame) => capture.isCurrent(frame),
        refresh,
      });
    this.session = makeSession();
    try {
      await capture.execute({ command: "wow-capture-stop" });
      if (token !== this.token) return;
      if (capture.status().state !== "stopped")
        throw new Error("wow_sync_cleanup_unconfirmed");
      await capture.execute({
        command: "wow-capture-start",
        source: "world-of-warcraft",
      });
      let previous: string | undefined;
      while (token === this.token) {
        const status = capture.status();
        this.update();
        if (status.state === "unavailable") throw new Error("wow_sync_failed");
        if (status.receipt && status.receipt.receipt !== previous) {
          previous = status.receipt.receipt;
          const frame = capture.frame();
          if (frame) {
            const current = this.ports.repository.current();
            if (
              (current?.revision ?? "0") !== revision ||
              (current?.contentHash ?? null) !== hash
            ) {
              this.update({
                state: "conflict",
                lastOutcome: "conflict",
                error: "wow_sync_conflict",
              });
              break;
            }
            operation = digest(
              JSON.stringify([
                this.state.operationId,
                frame.source,
                frame.generation,
                frame.receipt,
              ]),
            );
            const outcome = await this.session.observe(frame);
            if (token !== this.token) return;
            if (outcome.kind === "committed") {
              revision = outcome.receipt.resultingRevision;
              hash = outcome.receipt.contentHash;
              if (this.state.commitCount === Number.MAX_SAFE_INTEGER)
                throw new Error("wow_sync_failed");
              this.update({
                lastOutcome: "committed",
                profileId: outcome.profileID,
                revision,
                contentHash: hash,
                acknowledged: outcome.acknowledged,
                commitCount: this.state.commitCount + 1,
              });
              if (this.state.mode === "manual") {
                this.update({ state: "ready" });
                break;
              }
            } else if (
              outcome.kind === "failed" ||
              outcome.kind === "conflict" ||
              outcome.kind === "stopped"
            ) {
              this.update({
                state: outcome.kind === "conflict" ? "conflict" : "failed",
                lastOutcome:
                  outcome.kind === "conflict" ? "conflict" : "failed",
                error:
                  outcome.kind === "conflict"
                    ? "wow_sync_conflict"
                    : "wow_sync_failed",
              });
              break;
            } else
              this.update({
                lastOutcome: outcome.kind === "stale" ? "stale" : "observing",
              });
          } else {
            // A status is not a game frame. Its new capture receipt already
            // invalidates the old frame fence; preserve the observer's ACK identity.
            this.update({ lastOutcome: "observing" });
          }
          await (this.ports.pause?.(100) ??
            new Promise<void>((r) => setTimeout(r, 100)));
          if (token === this.token)
            await capture.execute({ command: "wow-capture-request" });
        }
        if (this.state.mode === "manual" && this.clock() >= deadline)
          throw new Error("wow_sync_timeout");
        await (this.ports.pause?.(25) ??
          new Promise<void>((r) => setTimeout(r, 25)));
      }
    } catch (error) {
      if (token === this.token)
        this.update({
          state: "failed",
          lastOutcome: "failed",
          error:
            error instanceof Error && error.message === "wow_sync_timeout"
              ? "wow_sync_timeout"
              : error instanceof Error &&
                  error.message === "wow_sync_cleanup_unconfirmed"
                ? "wow_sync_cleanup_unconfirmed"
                : "wow_sync_failed",
        });
    } finally {
      if (token === this.token) {
        this.session?.stop();
        let retired = false;
        try {
          await capture.execute({ command: "wow-capture-stop" });
          retired = capture.status().state === "stopped";
        } catch {
          /* An unconfirmed provider must not be replaced. */
        }
        if (!retired) {
          this.fenced = true;
          this.update({
            state: "failed",
            error: "wow_sync_cleanup_unconfirmed",
          });
        }
        this.active = false;
        this.update();
      }
    }
  }
  async close(): Promise<void> {
    ++this.token;
    this.session?.stop();
    await Promise.all([
      this.inflight,
      this.ports.capture?.execute({ command: "wow-capture-stop" }),
    ]);
    this.active = false;
  }
}
