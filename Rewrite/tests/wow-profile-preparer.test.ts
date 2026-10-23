import { expect, test } from "bun:test";
import {
  mkdtempSync,
  writeFileSync,
  chmodSync,
  rmSync,
  existsSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { starterConfiguration } from "@thumble/domain/starter-configuration";
import { WowLiveObserver } from "@thumble/application/wow-live-observer";
import {
  WowRefreshObservation,
  WowRefreshCancellation,
  type WowProfilePreparationRequest,
} from "@thumble/application/wow-profile-refresh";
import {
  RetainedWowProfilePreparer,
  wowLiveProfileId,
  WOW_PROFILE_HELPER_LIMITS,
} from "@thumble/service/wow-profile-preparer";
import { captured, snapshot, digest } from "./helpers/wow-refresh.ts";
async function fixture(
  run: (
    preparer: RetainedWowProfilePreparer,
    request: WowProfilePreparationRequest,
    ready: string,
  ) => Promise<void>,
) {
  const directory = mkdtempSync(join(tmpdir(), "thumble-wow-helper-")),
    file = join(directory, "helper.ts"),
    ready = join(directory, "ready");
  const observer = new WowLiveObserver();
  WowRefreshObservation.observe(observer, captured(1, 90), 90);
  const observation = WowRefreshObservation.observe(
    observer,
    captured(2, 100),
    100,
  )!;
  const id = wowLiveProfileId(observation.pending);
  const document = starterConfiguration(id, "Generated", "1").set(
    "/profiles/0/wowLive",
    JSON.stringify({
      characterID: observation.pending.character.id,
      flavor: observation.pending.character.flavor,
    }),
  );
  const reply = `{"schemaVersion":2,"document":${document.text()}}`;
  const script = `#!${process.execPath}
const request=JSON.parse(await Bun.stdin.text());const name=JSON.parse(request.snapshotJSON).character.name;let reply=${JSON.stringify(reply)};
 if(name==='wait'){process.on('SIGTERM',()=>{});await Bun.write(${JSON.stringify(ready)},'ready');await new Promise(yes=>setTimeout(yes,15000));}
 if(name==='oversize'){await Bun.write(Bun.stdout,' '.repeat(${WOW_PROFILE_HELPER_LIMITS.replyBytes + 1}));await new Promise(yes=>setTimeout(yes,15000));}
 if(name==='invalidutf8'){await Bun.write(Bun.stdout,new Uint8Array([255]));process.exit(0);}
 if(name==='duplicate')reply=reply.replace('"schemaVersion":2','"schemaVersion":2,"schemaVersion":2');
 if(name==='nestedduplicate')reply=reply.replace('"name":"Generated"','"name":"Generated","name":"Other"');
 await Bun.write(Bun.stdout,reply);
`;
  writeFileSync(file, script);
  chmodSync(file, 0o700);
  const request: WowProfilePreparationRequest = {
    schemaVersion: 2,
    wowProfileCommand: "prepare-owned",
    profileID: id,
    snapshotJSON: JSON.stringify(snapshot()),
    atlasPNGBase64: Buffer.from(observation.frame().atlasPNG()).toString(
      "base64",
    ),
    existingProfileJSON: null,
    existingBindingsJSON: null,
  };
  try {
    await run(new RetainedWowProfilePreparer(file), request, ready);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}
const nativeTest = test.skipIf(process.platform === "win32");
nativeTest(
  "explicit helper returns only one source-correlated controller profile and retained UUIDv5",
  async () =>
    fixture(async (preparer, request) => {
      const result = await preparer.prepare(
        request,
        new WowRefreshCancellation().signal,
      );
      expect(result.schemaVersion).toBe(2);
      expect(result.beforeProfile).toBeNull();
      expect(result.sourceSHA256).toBeNull();
      expect(result.document.get("/profiles/0/id")?.stringValue).toBe(
        request.profileID,
      );
      expect(request.profileID).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-5/);
      expect(() => new RetainedWowProfilePreparer("relative-helper")).toThrow(
        "wow_profile_helper_rejected",
      );
    }),
);
nativeTest(
  "malformed UTF8, duplicate envelope/nested keys, source mismatch and oversized output fail with fixed error",
  async () =>
    fixture(async (preparer, request) => {
      for (const name of [
        "invalidutf8",
        "duplicate",
        "nestedduplicate",
        "oversize",
      ]) {
        const changed = {
          ...request,
          snapshotJSON: JSON.stringify(snapshot(name)),
        };
        await expect(
          preparer.prepare(changed, new WowRefreshCancellation().signal),
        ).rejects.toThrow("wow_profile_helper_failed");
      }
      await expect(
        preparer.prepare(
          { ...request, existingProfileJSON: "{}", existingBindingsJSON: "{}" },
          new WowRefreshCancellation().signal,
        ),
      ).rejects.toThrow("wow_profile_helper_failed");
      const good = await preparer.prepare(
        request,
        new WowRefreshCancellation().signal,
      );
      expect(good.document.get("/profiles/0/id")?.stringValue).toBe(
        request.profileID,
      );
    }),
);
nativeTest(
  "cancellation waits for child termination, rejects overlap and permits a fresh helper only after exit",
  async () =>
    fixture(async (preparer, request, ready) => {
      const abort = new WowRefreshCancellation(),
        waiting = preparer.prepare(
          { ...request, snapshotJSON: JSON.stringify(snapshot("wait")) },
          abort.signal,
        );
      const rejected = waiting.then(
        () => true,
        () => false,
      );
      const end = Date.now() + 1500;
      while (!existsSync(ready) && Date.now() < end)
        await new Promise((yes) => setTimeout(yes, 5));
      expect(existsSync(ready)).toBe(true);
      await expect(
        preparer.prepare(request, new WowRefreshCancellation().signal),
      ).rejects.toThrow("wow_profile_helper_busy");
      abort.abort();
      expect(await rejected).toBe(false);
      expect(
        (await preparer.prepare(request, new WowRefreshCancellation().signal))
          .schemaVersion,
      ).toBe(2);
      const cancelled = new WowRefreshCancellation();
      cancelled.abort();
      await expect(preparer.prepare(request, cancelled.signal)).rejects.toThrow(
        "wow_profile_helper_cancelled",
      );
    }),
);
