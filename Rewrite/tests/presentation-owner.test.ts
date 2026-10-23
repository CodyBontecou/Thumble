import { withBankPresentation } from "./helpers/bank-presentation-source.ts";
import bankFixture from "../packages/fixtures/saved-controller-presentation-control-v11.json";
import { decodeAnyPhonePresentationEvent } from "@thumble/contracts/phone-presentation";
import { expect, test } from "bun:test";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { once } from "node:events";
import { SqliteConfigurationRepository } from "@thumble/storage";
import { starterConfiguration } from "@thumble/domain/starter-configuration";
import { ConfigurationOwner } from "../apps/service/src/configuration-owner.ts";
import { withPresentation } from "./helpers/presentation-source.ts";
import { PhonePresentationBridge } from "../apps/service/src/phone-presentation-bridge.ts";
import type { PhonePresentationEvent } from "@thumble/contracts/phone-presentation";
const executable = resolve(
    import.meta.dir,
    "../native/receiver/target/debug/thumble-rewrite-receiver" +
      (process.platform === "win32" ? ".exe" : ""),
  ),
  launcher = [
    process.execPath,
    resolve(import.meta.dir, "../apps/cli/src/main.ts"),
  ];
const profileId = "aaaaaaaa-0000-0000-0000-000000000001";
async function close(owner: ConfigurationOwner) {
  const exited =
    owner.child.exitCode !== null || owner.child.signalCode !== null
      ? Promise.resolve()
      : once(owner.child, "exit");
  owner.disconnect();
  const timer = setTimeout(() => owner.child.kill("SIGKILL"), 3000);
  try {
    await exited;
  } finally {
    clearTimeout(timer);
  }
}
test("real configuration child retains the old served input proof across a saved-only rename and verifies scoped icons", async () => {
  const parent = realpathSync(
      mkdtempSync(join(tmpdir(), "thumble-presentation-owner-")),
    ),
    directory = join(parent, "runtime");
  let owner: ConfigurationOwner | undefined;
  try {
    const repository = new SqliteConfigurationRepository(directory, executable);
    repository.commit({
      operationId: "seed",
      payloadHash: "a".repeat(64),
      expectedRevision: "0",
      source: withPresentation(starterConfiguration(profileId, "Initial", "1")),
      affectedEntities: [profileId],
    });
    const initial = repository.current()!;
    repository.close();
    owner = new ConfigurationOwner(executable, directory, launcher);
    await owner.ready;
    const query = {
      authorityInstanceId: "owner-authority",
      expectedConfigurationRevision: "1",
      expectedSourceHash: initial.contentHash,
      profileId,
      generation: "7",
      revision: "2",
      viewportWidth: "874",
      viewportHeight: "393",
    };
    const map = await owner.readControlsForPhone({
      command: "configuration-phone-controls",
      ...query,
    });
    if (map.kind !== "controls") throw Error("initial_map_missing");
    const command = {
      command: "configuration-phone-presentation" as const,
      kind: "metadata" as const,
      ...query,
      configurationSha256: String(map.configurationSha256),
      colorScheme: "light" as const,
    };
    await owner.request({
      command: "configuration-rename-profile",
      operationId: "rename",
      expectedRevision: "1",
      profileId,
      name: "Updated saved name",
    });
    const reply = await owner.readPresentationForPhone(command);
    expect(reply.kind).toBe("presentation");
    if (reply.kind !== "presentation") throw Error("presentation_missing");
    expect(reply.expectedConfigurationRevision).toBe("1");
    expect(reply.presentationRevision).toBe("2");
    expect(reply.profileName).toBe("Updated saved name");
    expect(reply.freshness).toBe("not-evaluated");
    expect(reply.controlCount).toBe(18);
    const icon = await owner.readPresentationForPhone({
      ...command,
      kind: "icon",
      presentationRevision: String(reply.presentationRevision),
      presentationSourceHash: String(reply.presentationSourceHash),
      controlId: "ce000000-0000-0000-0000-00000000000a",
      iconSHA256: String(reply.control9IconSHA256),
    });
    expect(icon.kind).toBe("icon");
    await close(owner);
    owner = new ConfigurationOwner(executable, directory, launcher);
    await owner.ready;
    expect(await owner.readPresentationForPhone(command)).toEqual({
      kind: "error",
      error: "presentation_reactivation_required",
    });
  } finally {
    if (owner) await close(owner);
    rmSync(parent, { recursive: true, force: true });
  }
});
test("presentation bridge abandons a timed-out phone response without starting a second underlying owner read", async () => {
  let resolve!: (value: unknown) => void,
    calls = 0;
  const wait = new Promise<unknown>((yes) => (resolve = yes)),
    bridge = new PhonePresentationBridge(() => {
      calls++;
      return wait;
    });
  const wire = JSON.parse(await Bun.file(resolvePath()).text());
  const {
    version: _,
    command: __,
    connectionId: ___,
    ...request
  } = wire.request;
  const event: PhonePresentationEvent = {
    ...request,
    kind: "metadata",
    authorityInstanceId: wire.reply.authorityInstanceId,
    version: 1,
    event: "phone-presentation",
    eventId: "1",
  };
  const pending = bridge.execute(event);
  await Bun.sleep(0);
  expect(await bridge.execute({ ...event, eventId: "2" })).toEqual({
    error: "presentation_busy",
  });
  expect(await pending).toEqual({ error: "presentation_timeout" });
  expect(await bridge.execute({ ...event, eventId: "3" })).toEqual({
    error: "presentation_busy",
  });
  expect(calls).toBe(1);
  resolve({ kind: "error", error: "presentation_unavailable" });
  await Bun.sleep(0);
  expect(await bridge.execute({ ...event, eventId: "4" })).toEqual({
    result: { kind: "error", error: "presentation_unavailable" },
  });
}, 5000);
function resolvePath() {
  return resolve(
    import.meta.dir,
    "../packages/fixtures/saved-controller-presentation-control-v10.json",
  );
}

test("role11 parent bridge and real configuration child serve all eight states without changing input proof", async () => {
  const parent = realpathSync(
      mkdtempSync(join(tmpdir(), "thumble-banked-owner-")),
    ),
    directory = join(parent, "runtime");
  let owner: ConfigurationOwner | undefined;
  try {
    const repository = new SqliteConfigurationRepository(directory, executable);
    repository.commit({
      operationId: "seed",
      payloadHash: "a".repeat(64),
      expectedRevision: "0",
      source: withBankPresentation(
        starterConfiguration(profileId, "Banks", "1"),
      ),
      affectedEntities: [profileId],
    });
    const initial = repository.current()!;
    repository.close();
    owner = new ConfigurationOwner(executable, directory, launcher);
    await owner.ready;
    const q = {
      authorityInstanceId: "owner-authority",
      expectedConfigurationRevision: "1",
      expectedSourceHash: initial.contentHash,
      profileId,
      generation: "7",
      revision: "2",
      viewportWidth: "874",
      viewportHeight: "393",
    };
    const map = await owner.readControlsForPhone({
      command: "configuration-phone-controls",
      ...q,
    });
    if (map.kind !== "controls") throw Error("missing_map");
    const child = owner,
      bridge = new PhonePresentationBridge((command) =>
        child.readPresentationForPhone(command),
      );
    let id = 0;
    for (const v of bankFixture.variants) {
      const base = {
        ...q,
        configurationSha256: String(map.configurationSha256),
        bank: v.request.bank,
        colorScheme: v.request.colorScheme,
      };
      const meta = await bridge.execute(
        decodeAnyPhonePresentationEvent(
          {
            ...base,
            kind: "metadata",
            version: 2,
            event: "phone-presentation",
            eventId: String(++id),
          },
          q.authorityInstanceId,
        ),
      );
      if (!("result" in meta) || meta.result.kind !== "presentation")
        throw Error("missing_metadata");
      expect(meta.result.bank).toBe(v.request.bank);
      expect(meta.result.control9IconSHA256).toBe(v.iconReply.iconSHA256);
      expect(meta.result.expectedSourceHash).toBe(initial.contentHash);
      const icon = await bridge.execute(
        decodeAnyPhonePresentationEvent(
          {
            ...base,
            kind: "icon",
            presentationRevision: String(meta.result.presentationRevision),
            presentationSourceHash: String(meta.result.presentationSourceHash),
            controlId: "ce000000-0000-0000-0000-00000000000a",
            iconSHA256: String(meta.result.control9IconSHA256),
            version: 2,
            event: "phone-presentation",
            eventId: String(++id),
          },
          q.authorityInstanceId,
        ),
      );
      if (!("result" in icon) || icon.result.kind !== "icon")
        throw Error("missing_icon");
      expect(icon.result.bank).toBe(v.request.bank);
      expect(icon.result.pngBase64).toBe(v.iconReply.pngBase64);
    }
  } finally {
    if (owner) await close(owner);
    rmSync(parent, { recursive: true, force: true });
  }
}, 10000);
