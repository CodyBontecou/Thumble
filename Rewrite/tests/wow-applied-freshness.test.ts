import { expect, test } from "bun:test";
import { WowLiveObserver } from "@thumble/application/wow-live-observer";
import { captured } from "./helpers/wow-refresh.ts";
function stage() {
  const observer = new WowLiveObserver();
  observer.observe(42, "1", captured(1, 90).frame(), 90);
  const pending = observer.observe(42, "1", captured(2, 100).frame(), 100)!;
  expect(observer.acknowledge(pending, { kind: "committed" }, 100)).toBe(true);
  return { observer, pending };
}
test("applied observation correlation survives advancing identical payloads but rejects changed message or source", () => {
  const { observer, pending } = stage();
  expect(observer.matchesAppliedMessage(pending, 100)).toBe(true);
  observer.observe(42, "1", captured(3, 200).frame(), 200);
  expect(observer.matchesAppliedMessage(pending, 200)).toBe(true);
  observer.observe(42, "1", captured(4, 210, 0, "Different name").frame(), 210);
  expect(observer.matchesAppliedMessage(pending, 210)).toBe(false);
  const second = stage();
  second.observer.observe(43, "2", captured(3, 200).frame(), 200);
  expect(second.observer.matchesAppliedMessage(second.pending, 200)).toBe(
    false,
  );
});
test("frozen transport repeats cannot freshen applied presentation or recover through query clock rollback", () => {
  const { observer, pending } = stage();
  observer.observe(42, "1", captured(2, 1000).frame(), 1000);
  expect(observer.matchesAppliedMessage(pending, 2100)).toBe(false);
  expect(observer.matchesAppliedMessage(pending, 200)).toBe(false);
});
