import { expect, test } from "bun:test";
import { LosslessJson } from "@thumble/contracts/json";
import { starterConfiguration } from "@thumble/domain/starter-configuration";
import { OwnedAuthorityDocument } from "@thumble/domain/owned-authority";
import { WowLiveObserver } from "@thumble/application/wow-live-observer";
import {
  WowProfileRefresh,
  WowRefreshObservation,
  WowRefreshCancellation,
  type WowProfilePreparationRequest,
  type WowProfilePreparationReply,
} from "@thumble/application/wow-profile-refresh";
import {
  ConfigurationRevisionConflict,
  type ConfigurationRepository,
  type ConfigurationSource,
  type ConfigurationCommit,
} from "@thumble/application/configuration-store";
import { wowLiveProfileId } from "@thumble/service/wow-profile-preparer";
import { captured, digest } from "./helpers/wow-refresh.ts";

function setup(
  existing = false,
  customize?: (source: LosslessJson) => LosslessJson,
) {
  let now = 100,
    currentCapture = true,
    commits = 0,
    source: ConfigurationSource | undefined;
  const observer = new WowLiveObserver();
  WowRefreshObservation.observe(observer, captured(1, 90), 90);
  const observation = WowRefreshObservation.observe(
    observer,
    captured(2, 100, 7),
    100,
  )!;
  const id = wowLiveProfileId(observation.pending),
    other = "bbbbbbbb-0000-0000-0000-000000000002";
  const assets = new Map<string, Uint8Array>();
  let baseline = starterConfiguration(
    existing ? id : other,
    "Manual retained name",
    "1",
  ).set("/opaque", '{"v":1e+03}');
  if (existing)
    baseline = baseline
      .set(
        "/profiles/0/wowLive",
        JSON.stringify({
          characterID: observation.pending.character.id,
          flavor: observation.pending.character.flavor,
        }),
      )
      .set("/profiles/0/manualMetadata", '{"v":1e+03}')
      .set("/profileOutputBindings", `{"${id}":{}}`)
      .set("/outputBindings", "{}");
  if (customize) baseline = customize(baseline);
  source = {
    revision: "1",
    contentHash: digest(baseline.text()),
    source: baseline,
  };
  const repository: ConfigurationRepository = {
    current: () => source,
    receipt: () => undefined,
    commit: (command: ConfigurationCommit) => {
      if (command.expectedRevision !== source?.revision)
        throw new ConfigurationRevisionConflict(source?.revision ?? "0");
      commits++;
      for (const asset of command.assets ?? [])
        assets.set(digest(asset), asset.slice());
      source = {
        revision: String(BigInt(source?.revision ?? "0") + 1n),
        contentHash: digest(command.source.text()),
        source: command.source,
      };
      return {
        receipt: {
          version: 1,
          operationId: command.operationId,
          resultingRevision: source.revision,
          contentHash: source.contentHash,
          affectedEntities: command.affectedEntities,
        },
        replayed: false,
      };
    },
  };
  let prepare = async (
    request: WowProfilePreparationRequest,
  ): Promise<WowProfilePreparationReply> => {
    expect(request.atlasPNGBase64).toBe(
      Buffer.from(observation.frame().atlasPNG()).toString("base64"),
    );
    let document = starterConfiguration(request.profileID, "Generated", "1");
    let profile = request.existingProfileJSON
      ? LosslessJson.parse(request.existingProfileJSON)
      : document.get("/profiles/0")!;
    const before = request.existingProfileJSON
      ? profile.get("/manualMetadata")
        ? profile.remove("/manualMetadata")
        : profile
      : null;
    profile = (before ?? profile).set(
      "/wowLive",
      JSON.stringify({
        characterID: observation.pending.character.id,
        flavor: observation.pending.character.flavor,
        version: 2,
      }),
    );
    document = document.set("/profiles", `[${profile.text()}]`);
    if (existing)
      expect(request.existingBindingsJSON).toContain('"outputBindings":{}');
    return {
      schemaVersion: 2,
      sourceSHA256: request.existingProfileJSON
        ? digest(request.existingProfileJSON)
        : null,
      beforeProfile: before,
      document,
    };
  };
  const refresh = new WowProfileRefresh(repository, {
    clock: () => now,
    currentCapture: () => currentCapture,
    readAsset: (hash) => {
      const value = assets.get(hash);
      if (!value) throw Error("asset_missing");
      return value;
    },
    resourceHash: digest,
    digest,
    sourceHash: (value) => digest(value.text()),
    profileId: wowLiveProfileId,
    operationId: () => "aaaaaaaa-0000-4000-8000-000000000001",
    preparer: { prepare: (request) => prepare(request) },
  });
  return {
    refresh,
    observation,
    observer,
    id,
    baseline,
    get source() {
      return source!;
    },
    get commits() {
      return commits;
    },
    setNow: (value: number) => {
      now = value;
    },
    invalidate: () => {
      currentCapture = false;
    },
    setPrepare: (value: typeof prepare) => {
      prepare = value;
    },
    getPrepare: () => prepare,
    race: () => {
      source = { ...source!, revision: "2" };
    },
    repository,
  };
}
test("refresh creates one correlated controller profile, preserves exact opaque source and selects with mirrors only after durable CAS", async () => {
  const f = setup(),
    result = await f.refresh.execute(
      f.observation,
      new WowRefreshCancellation().signal,
      () => true,
    );
  expect(result.kind).toBe("committed");
  if (result.kind !== "committed") throw Error("expected_commit");
  expect(result.acknowledged).toBe(true);
  expect(result.receipt.resultingRevision).toBe("2");
  expect(f.commits).toBe(1);
  const document = OwnedAuthorityDocument.read(f.source.source).materialize(
    () => {
      throw Error("unexpected_asset");
    },
    digest,
  );
  expect(document.catalog.profiles.length).toBe(2);
  expect(document.catalog.activeProfileID).toBe(f.id);
  expect(document.source.get("/opaque")?.text()).toBe('{"v":1e+03}');
  expect(document.catalog.defaultProfileID).toBe(
    "bbbbbbbb-0000-0000-0000-000000000002",
  );
  expect(f.observer.pending(100)).toBeUndefined();
});
test("existing explicit empty overrides, manual profile name and opaque metadata survive refresh", async () => {
  const f = setup(true),
    result = await f.refresh.execute(
      f.observation,
      new WowRefreshCancellation().signal,
      () => true,
    );
  expect(result.kind).toBe("committed");
  const document = OwnedAuthorityDocument.read(f.source.source).materialize(
    () => {
      throw Error("unexpected_asset");
    },
    digest,
  ).source;
  expect(document.get("/profileOutputBindings/" + f.id)?.text()).toBe("{}");
  expect(document.get("/outputBindings")?.text()).toBe("{}");
  expect(document.get("/profiles/0/name")?.stringValue).toBe(
    "Manual retained name",
  );
  expect(document.get("/profiles/0/manualMetadata")?.text()).toBe(
    '{"v":1e+03}',
  );
});
test("capture invalidation, expiry and cancellation across awaited helper prevent any CAS", async () => {
  for (const mode of ["capture", "expiry", "cancel", "session"]) {
    const f = setup(),
      abort = new WowRefreshCancellation();
    let session = true;
    const original = f.getPrepare();
    let release!: () => void;
    const waiting = new Promise<void>((yes) => {
      release = yes;
    });
    f.setPrepare(async (request) => {
      await waiting;
      return original(request);
    });
    const pending = f.refresh.execute(
      f.observation,
      abort.signal,
      () => session,
    );
    if (mode === "capture") f.invalidate();
    if (mode === "expiry") f.setNow(2100);
    if (mode === "cancel") abort.abort();
    if (mode === "session") session = false;
    release();
    expect((await pending).kind).toBe("stale");
    expect(f.commits).toBe(0);
  }
});
test("revision race fails CAS without ACK; a postcommit freshness failure still returns the durable receipt", async () => {
  const raced = setup(),
    original = raced.getPrepare();
  raced.setPrepare(async (request) => {
    const reply = await original(request);
    raced.race();
    return reply;
  });
  expect(
    (
      await raced.refresh.execute(
        raced.observation,
        new WowRefreshCancellation().signal,
        () => true,
      )
    ).kind,
  ).toBe("conflict");
  expect(raced.commits).toBe(0);
  expect(raced.observer.pending(100)?.receipt).toBe(
    raced.observation.pending.receipt,
  );
  const f = setup();
  const commit = f.repository.commit;
  f.repository.commit = (command) => {
    const result = commit(command);
    f.setNow(3000);
    return result;
  };
  const result = await f.refresh.execute(
    f.observation,
    new WowRefreshCancellation().signal,
    () => true,
  );
  expect(result.kind).toBe("committed");
  if (result.kind === "committed") {
    expect(result.acknowledged).toBe(false);
    expect(result.receipt.resultingRevision).toBe("2");
  }
  expect(f.commits).toBe(1);
});
test("uncorrelated helper source and a forged observation never produce a commit", async () => {
  const f = setup(),
    original = f.getPrepare();
  f.setPrepare(async (request) => ({
    ...(await original(request)),
    sourceSHA256: "0".repeat(64),
  }));
  expect(
    (
      await f.refresh.execute(
        f.observation,
        new WowRefreshCancellation().signal,
        () => true,
      )
    ).kind,
  ).toBe("failed");
  expect(f.commits).toBe(0);
});

test("same intent cannot retry against newer authority and runtime construction cannot forge an atlas binding", async () => {
  const f = setup(),
    original = f.getPrepare();
  let calls = 0;
  f.setPrepare(async (request) => {
    calls++;
    const value = await original(request);
    f.race();
    return value;
  });
  expect(
    (
      await f.refresh.execute(
        f.observation,
        new WowRefreshCancellation().signal,
        () => true,
      )
    ).kind,
  ).toBe("conflict");
  expect(
    (
      await f.refresh.execute(
        f.observation,
        new WowRefreshCancellation().signal,
        () => true,
      )
    ).kind,
  ).toBe("conflict");
  expect(calls).toBe(1);
  expect(f.commits).toBe(0);
  expect(() =>
    Reflect.construct(WowRefreshObservation, [
      Symbol(),
      f.observation.frame(),
      f.observer,
      f.observation.pending,
    ]),
  ).toThrow("invalid_wow_profile_preparation");
  const committed = setup();
  expect(
    (
      await committed.refresh.execute(
        committed.observation,
        new WowRefreshCancellation().signal,
        () => true,
      )
    ).kind,
  ).toBe("committed");
  const next = WowRefreshObservation.observe(
    committed.observer,
    captured(3, 110, 0, "Updated"),
    110,
  );
  expect(next?.pending.select).toBe(false);
});

test("existing user geometry is preserved rather than normalized to the new-profile starter", async () => {
  const f = setup(true, (source) =>
    source
      .set(
        "/profiles/0/customization/elements/2/layout/shape",
        '"rounded_rectangle"',
      )
      .set(
        "/profiles/0/customization/elements/2/layout/hitInsets",
        '{"top":10,"leading":10,"bottom":10,"trailing":10}',
      ),
  );
  const outcome = await f.refresh.execute(
    f.observation,
    new WowRefreshCancellation().signal,
    () => true,
  );
  expect(outcome.kind).toBe("committed");
  const saved = OwnedAuthorityDocument.read(f.source.source).materialize(() => {
    throw Error("unexpected_asset");
  }, digest).source;
  expect(
    saved.get("/profiles/0/customization/elements/2/layout/shape")?.text(),
  ).toBe('"rounded_rectangle"');
  expect(
    saved.get("/profiles/0/customization/elements/2/layout/hitInsets")?.text(),
  ).toBe('{"top":10,"leading":10,"bottom":10,"trailing":10}');
  expect(saved.get("/profileOutputBindings/" + f.id)?.text()).toBe("{}");
  expect(saved.get("/profiles/0/manualMetadata")?.text()).toBe('{"v":1e+03}');
});
