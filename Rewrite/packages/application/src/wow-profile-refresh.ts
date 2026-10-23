import { LosslessJson } from "@thumble/contracts/json";
import type { ConfigurationReceipt } from "@thumble/contracts/configuration";
import { OwnedAuthorityDocument } from "@thumble/domain/owned-authority";
import {
  OwnedConfigurationDocument,
  type ResourceDigest,
} from "@thumble/domain/owned-configuration";
import { ConfigurationCatalog } from "@thumble/domain/configuration-catalog";
import { starterConfiguration } from "@thumble/domain/starter-configuration";
import { encodeResourceBase64 } from "@thumble/domain/owned-resources";
import { WowCapturedFrame } from "@thumble/domain/wow-capture-receipt";
import { mergeOwnedProjection } from "@thumble/domain/owned-projection-merge";
import {
  WowLiveObserver,
  type PendingWowObservation,
} from "./wow-live-observer.ts";
import {
  ConfigurationRevisionConflict,
  type ConfigurationRepository,
} from "./configuration-store.ts";

const segment = (key: string) =>
  "/" + key.replaceAll("~", "~0").replaceAll("/", "~1");
function invalid(): never {
  throw new Error("invalid_wow_profile_preparation");
}
const uuid = (value: string) =>
  /^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(
    value,
  );
function entry(
  map: LosslessJson | undefined,
  id: string,
): LosslessJson | undefined {
  if (!map) return;
  if (map.kind !== "object") invalid();
  const keys = map.keys.filter((key) => key.toLowerCase() === id);
  if (keys.length > 1) invalid();
  return keys[0] === undefined ? undefined : map.get(segment(keys[0]));
}
const observationKey = Symbol("wow-refresh-observation");
/** Constructible only from the frame that actually completes a NEW observer intent.
 * Its atlas is never supplied separately, nor recovered from diagnostic hashes. */
export class WowRefreshObservation {
  readonly #frame: WowCapturedFrame;
  readonly #observer: WowLiveObserver;
  readonly pending: PendingWowObservation;
  #storagePin:
    | Readonly<{ revision: string; sourceHash: string | null }>
    | undefined;
  private constructor(
    key: symbol,
    frame: WowCapturedFrame,
    observer: WowLiveObserver,
    pending: PendingWowObservation,
  ) {
    if (key !== observationKey) invalid();
    this.#frame = frame;
    this.#observer = observer;
    this.pending = pending;
    Object.freeze(this);
  }
  static observe(
    observer: WowLiveObserver,
    frame: WowCapturedFrame,
    nowMs: number,
  ): WowRefreshObservation | undefined {
    if (!(frame instanceof WowCapturedFrame)) invalid();
    const previous = observer.pending(nowMs)?.receipt;
    const pending = observer.observe(
      frame.source,
      frame.generation,
      frame.frame(),
      nowMs,
    );
    return pending && pending.receipt !== previous
      ? new WowRefreshObservation(observationKey, frame, observer, pending)
      : undefined;
  }
  pinStorage(
    key: symbol,
    revision: string,
    sourceHash: string | null,
  ): boolean {
    if (key !== observationKey) invalid();
    if (!this.#storagePin) {
      this.#storagePin = Object.freeze({ revision, sourceHash });
      return true;
    }
    return (
      this.#storagePin.revision === revision &&
      this.#storagePin.sourceHash === sourceHash
    );
  }
  frame(): WowCapturedFrame {
    return this.#frame;
  }
  isCurrent(nowMs: number): boolean {
    const value = this.#observer.pending(nowMs);
    return (
      value?.receipt === this.pending.receipt &&
      value.source === this.pending.source &&
      value.generation === this.pending.generation
    );
  }
  acknowledge(nowMs: number): boolean {
    return this.#observer.acknowledge(
      this.pending,
      { kind: "committed" },
      nowMs,
    );
  }
}
Object.freeze(WowRefreshObservation.prototype);
/** Portable cancellation only; no DOM globals or raw platform abort reasons. */
export interface WowCancellationSignal {
  readonly aborted: boolean;
  onCancel(listener: () => void): () => void;
}
export class WowRefreshCancellation {
  #aborted = false;
  readonly #listeners = new Set<() => void>();
  readonly signal: WowCancellationSignal;
  constructor() {
    const owner = this;
    this.signal = Object.freeze({
      get aborted() {
        return owner.#aborted;
      },
      onCancel(listener: () => void) {
        if (typeof listener !== "function" || owner.#listeners.size >= 16)
          throw new Error("invalid_wow_cancellation_listener");
        if (owner.#aborted) {
          listener();
          return () => {};
        }
        owner.#listeners.add(listener);
        return () => {
          owner.#listeners.delete(listener);
        };
      },
    });
  }
  abort(): void {
    if (this.#aborted) return;
    this.#aborted = true;
    const listeners = [...this.#listeners];
    this.#listeners.clear();
    for (const listener of listeners)
      try {
        listener();
      } catch {}
  }
}

export interface WowProfilePreparationRequest {
  readonly schemaVersion: 2;
  readonly wowProfileCommand: "prepare-owned";
  readonly profileID: string;
  readonly snapshotJSON: string;
  readonly atlasPNGBase64: string;
  readonly existingProfileJSON: string | null;
  readonly existingBindingsJSON: string | null;
}
export interface WowProfilePreparationReply {
  readonly schemaVersion: 2;
  readonly sourceSHA256: string | null;
  readonly beforeProfile: LosslessJson | null;
  readonly document: LosslessJson;
}
export interface WowProfilePreparer {
  prepare(
    request: WowProfilePreparationRequest,
    signal: WowCancellationSignal,
  ): Promise<WowProfilePreparationReply>;
}
export type WowProfileRefreshOutcome =
  | Readonly<{
      kind: "committed";
      receipt: ConfigurationReceipt;
      acknowledged: boolean;
      profileID: string;
    }>
  | Readonly<{ kind: "stale" | "conflict" | "failed" }>;

/** Storage-only refresh in the existing configuration owner. No runtime activation,
 * input lease, capture or desktop GUI port exists on this use case. */
export class WowProfileRefresh {
  constructor(
    private readonly repository: ConfigurationRepository,
    private readonly ports: Readonly<{
      clock: () => number;
      currentCapture: (frame: WowCapturedFrame) => boolean;
      readAsset: (sha256: string) => Uint8Array;
      resourceHash: ResourceDigest;
      digest: (text: string) => string;
      sourceHash: (source: LosslessJson) => string;
      /** Trusted deterministic retained UUIDv5 derivation, not a helper-supplied ID. */
      profileId: (observation: PendingWowObservation) => string;
      operationId: () => string;
      preparer: WowProfilePreparer;
    }>,
  ) {}
  async execute(
    observation: WowRefreshObservation,
    signal: WowCancellationSignal,
    sessionCurrent: () => boolean,
  ): Promise<WowProfileRefreshOutcome> {
    if (!(observation instanceof WowRefreshObservation)) invalid();
    const current = () =>
      !signal.aborted &&
      sessionCurrent() &&
      this.ports.currentCapture(observation.frame()) &&
      observation.isCurrent(this.ports.clock());
    try {
      if (!current()) return Object.freeze({ kind: "stale" });
      const stored = this.repository.current(),
        revision = stored?.revision ?? "0";
      if (
        !observation.pinStorage(
          observationKey,
          revision,
          stored?.contentHash ?? null,
        )
      )
        return Object.freeze({ kind: "conflict" });
      if (stored && this.ports.sourceHash(stored.source) !== stored.contentHash)
        invalid();
      const owned = stored
        ? OwnedAuthorityDocument.isAuthority(stored.source)
          ? OwnedAuthorityDocument.read(stored.source).materialize(
              this.ports.readAsset,
              this.ports.resourceHash,
            )
          : OwnedConfigurationDocument.read(
              stored.source,
              this.ports.resourceHash,
            )
        : undefined;
      const id = this.ports.profileId(observation.pending);
      if (!uuid(id)) invalid();
      const index =
        owned?.catalog.profiles.findIndex((profile) => profile.id === id) ?? -1;
      const existing =
        index < 0 ? undefined : owned!.source.get(`/profiles/${index}`)!;
      if (
        existing &&
        (existing.get("/outputMode")?.stringValue !== "controller" ||
          existing.get("/wowLive/characterID")?.stringValue !==
            observation.pending.character.id ||
          existing.get("/wowLive/flavor")?.stringValue !==
            observation.pending.character.flavor)
      )
        invalid();
      const name = `${observation.pending.snapshot.character.name} · ${observation.pending.snapshot.character.realm} · ${observation.pending.character.flavor === "forever" ? "WoW Forever" : "ConsolePort"}`;
      // A new profile starts from the explicit production controller, never the
      // retained helper's older implicit hit geometry/digital-trigger defaults.
      // This is a virtual preparation baseline, not a prior authority write.
      const seed = existing ? undefined : starterConfiguration(id, name, "0");
      const helperSource =
        existing ??
        seed!.get("/profiles/0")!.set(
          "/wowLive",
          JSON.stringify({
            characterID: observation.pending.character.id,
            flavor: observation.pending.character.flavor,
          }),
        );
      let bindings = existing
        ? LosslessJson.parse("{}")
        : LosslessJson.parse("{}")
            .set("/keyBindings", seed!.get("/keyBindings")!.text())
            .set("/outputBindings", seed!.get("/outputBindings")!.text());
      if (existing)
        for (const [source, target] of [
          ["profileKeyBindings", "keyBindings"],
          ["profileOutputBindings", "outputBindings"],
        ] as const) {
          const value = entry(owned!.source.get("/" + source), id);
          if (value) bindings = bindings.set("/" + target, value.text());
        }
      const request: WowProfilePreparationRequest = Object.freeze({
        schemaVersion: 2,
        wowProfileCommand: "prepare-owned",
        profileID: id,
        snapshotJSON: JSON.stringify(observation.pending.snapshot),
        atlasPNGBase64: encodeResourceBase64(observation.frame().atlasPNG()),
        existingProfileJSON: helperSource.text(),
        existingBindingsJSON: bindings.text(),
      });
      const reply = await this.ports.preparer.prepare(request, signal);
      if (!current()) return Object.freeze({ kind: "stale" });
      if (
        reply.schemaVersion !== 2 ||
        reply.sourceSHA256 !== this.ports.digest(helperSource.text()) ||
        reply.beforeProfile === null ||
        !(reply.document instanceof LosslessJson) ||
        (reply.beforeProfile !== null &&
          !(reply.beforeProfile instanceof LosslessJson))
      )
        invalid();
      let document = reply.document;
      if (!document.get("/schema"))
        document = document
          .set(
            "/schema",
            JSON.stringify("com.codybontecou.pocketpad.keypad-configuration"),
          )
          .set("/version", "5");
      const prepared = OwnedConfigurationDocument.read(
        document,
        this.ports.resourceHash,
      );
      const profile = document.get("/profiles/0")!;
      if (
        prepared.profiles.length !== 1 ||
        prepared.catalog.activeProfileID !== id ||
        prepared.catalog.defaultProfileID !== id ||
        prepared.catalog.profiles[0]!.id !== id ||
        profile.get("/outputMode")?.stringValue !== "controller" ||
        profile.get("/wowLive/characterID")?.stringValue !==
          observation.pending.character.id ||
        profile.get("/wowLive/flavor")?.stringValue !==
          observation.pending.character.flavor
      )
        invalid();
      let result: LosslessJson;
      if (existing) {
        const merged = mergeOwnedProjection(
          existing,
          reply.beforeProfile!,
          profile,
        );
        const candidate = owned!.source.set(
          `/profiles/${index}`,
          merged.text(),
        );
        result = mergeOwnedProjection(owned!.source, owned!.source, candidate);
      } else {
        // New profiles must not import keyboard actions from optical observations.
        const keys = entry(seed!.get("/profileKeyBindings"), id),
          outputs = entry(seed!.get("/profileOutputBindings"), id);
        if (
          !keys ||
          keys.kind !== "object" ||
          keys.keys.length ||
          !outputs ||
          outputs.kind !== "object"
        )
          invalid();
        const helperOutputs = entry(document.get("/profileOutputBindings"), id);
        if (!helperOutputs || helperOutputs.kind !== "object") invalid();
        for (const key of helperOutputs.keys) {
          const output = helperOutputs.get(segment(key))!;
          if (
            output.get("/keyboard")?.kind !== undefined &&
            output.get("/keyboard")?.kind !== "null"
          )
            invalid();
        }
        for (const element of prepared.profiles[0]!.elements) {
          const all = [
            element.output,
            element.defaultOutput,
            ...element.partOutputs.map((part) => part.output),
            ...Object.values(element.joystickMapping ?? {}),
          ];
          if (
            all.some(
              (output) =>
                output?.keyboard !== null && output?.keyboard !== undefined,
            )
          )
            invalid();
        }
        const named = mergeOwnedProjection(
          helperSource,
          reply.beforeProfile!,
          profile,
        ).set("/name", JSON.stringify(name));
        if (!owned) result = seed!.set("/profiles", `[${named.text()}]`);
        else {
          const profiles = owned.source.get("/profiles")!;
          let candidate = owned.source.set(
            "/profiles",
            "[" +
              [
                ...Array.from({ length: profiles.length! }, (_, i) =>
                  profiles.get("/" + i)!.text(),
                ),
                named.text(),
              ].join(",") +
              "]",
          );
          for (const [field, value] of [
            ["profileKeyBindings", keys],
            ["profileOutputBindings", outputs],
          ] as const) {
            const map = candidate.get("/" + field) ?? LosslessJson.parse("{}");
            candidate = candidate.set(
              "/" + field,
              map.set(segment(id), value.text()).text(),
            );
          }
          result = mergeOwnedProjection(owned.source, owned.source, candidate);
        }
      }
      if (observation.pending.select) {
        const catalog = ConfigurationCatalog.read(result);
        result = catalog.selectProfiles(id, catalog.defaultProfileID).source;
      }
      const pool = OwnedAuthorityDocument.prepare(
        result,
        this.ports.resourceHash,
      );
      const payloadHash = this.ports.digest(
        JSON.stringify([
          "thumble-wow-refresh-v1",
          revision,
          stored?.contentHash ?? null,
          observation.pending.source,
          observation.pending.generation,
          observation.pending.receipt,
          this.ports.sourceHash(pool.document.source),
        ]),
      );
      const assets = pool.assets(),
        operationId = this.ports.operationId();
      // No await or deferred asset extraction between the final guard and CAS.
      if (!current()) return Object.freeze({ kind: "stale" });
      const committed = this.repository.commit({
        operationId,
        payloadHash,
        expectedRevision: revision,
        source: pool.document.source,
        affectedEntities: [id],
        assets,
      });
      let acknowledged = false;
      // A postcommit observation/clock failure cannot erase a durable receipt.
      try {
        acknowledged = current() && observation.acknowledge(this.ports.clock());
      } catch {}
      return Object.freeze({
        kind: "committed",
        receipt: committed.receipt,
        acknowledged,
        profileID: id,
      });
    } catch (error) {
      if (error instanceof ConfigurationRevisionConflict)
        return Object.freeze({ kind: "conflict" });
      return Object.freeze({ kind: signal.aborted ? "stale" : "failed" });
    }
  }
}
