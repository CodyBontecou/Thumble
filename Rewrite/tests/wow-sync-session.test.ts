import { expect, test } from "bun:test";
import { WowSyncSession } from "@thumble/application/wow-sync-session";
import {
  WowRefreshCancellation,
  type WowProfileRefreshOutcome,
} from "@thumble/application/wow-profile-refresh";
import { captured, digest } from "./helpers/wow-refresh.ts";

test("one busy preparation cannot consume or attach a later capture atlas", async () => {
  let now = 90,
    calls = 0,
    release!: () => void;
  const wait = new Promise<void>((yes) => {
    release = yes;
  });
  let atlas = "";
  const session = new WowSyncSession({
    clock: () => now,
    currentCapture: () => true,
    refresh: {
      execute: async (observation, signal, current) => {
        calls++;
        atlas = digest(observation.frame().atlasPNG());
        await wait;
        return { kind: signal.aborted || !current() ? "stale" : "failed" };
      },
    },
  });
  expect((await session.observe(captured(1, 90, 1))).kind).toBe("observing");
  now = 100;
  const completing = captured(2, 100, 7),
    pending = session.observe(completing);
  expect(session.busy).toBe(true);
  expect((await session.observe(captured(3, 100, 9))).kind).toBe("busy");
  expect(calls).toBe(1);
  expect(atlas).toBe(digest(completing.atlasPNG()));
  release();
  expect((await pending).kind).toBe("failed");
  expect(session.busy).toBe(false);
  // Same message returning an old pending receipt must not replace its original atlas.
  now = 110;
  expect((await session.observe(captured(4, 110, 11))).kind).toBe("observing");
  expect(calls).toBe(1);
  expect((await session.retry()).kind).toBe("failed");
  expect(calls).toBe(2);
  expect(atlas).toBe(digest(completing.atlasPNG()));
});
test("stop is terminal and invalidates both cancellation and session guard across helper await", async () => {
  let now = 90,
    release!: () => void,
    calls = 0;
  const wait = new Promise<void>((yes) => {
    release = yes;
  });
  const session = new WowSyncSession({
    clock: () => now,
    currentCapture: () => true,
    refresh: {
      execute: async (_observation, signal, current) => {
        calls++;
        await wait;
        expect(signal.aborted).toBe(true);
        expect(current()).toBe(false);
        return { kind: "stale" };
      },
    },
  });
  await session.observe(captured(1, 90));
  now = 100;
  const pending = session.observe(captured(2, 100));
  session.stop();
  session.stop();
  release();
  expect((await pending).kind).toBe("stale");
  expect((await session.retry()).kind).toBe("stopped");
  expect((await session.observe(captured(3, 100))).kind).toBe("stopped");
  expect(calls).toBe(1);
});
test("expired captures and backwards owner clocks fail before refresh", async () => {
  let now = 2100,
    calls = 0;
  const session = new WowSyncSession({
    clock: () => now,
    currentCapture: () => true,
    refresh: {
      execute: async (): Promise<WowProfileRefreshOutcome> => {
        calls++;
        return { kind: "failed" };
      },
    },
  });
  expect((await session.observe(captured(1, 100))).kind).toBe("stale");
  now = 2099;
  expect((await session.retry()).kind).toBe("stopped");
  expect(calls).toBe(0);
});
test("portable cancellation notifies once, removes listeners and never propagates raw abort exceptions", () => {
  const owner = new WowRefreshCancellation();
  let count = 0;
  const remove = owner.signal.onCancel(() => {
    count++;
  });
  remove();
  owner.signal.onCancel(() => {
    count++;
    throw Error("synthetic");
  });
  owner.signal.onCancel(() => {
    count++;
  });
  owner.abort();
  owner.abort();
  expect(owner.signal.aborted).toBe(true);
  expect(count).toBe(2);
  owner.signal.onCancel(() => {
    count++;
  });
  expect(count).toBe(3);
});
