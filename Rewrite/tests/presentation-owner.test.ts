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
