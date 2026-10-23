import { expect, test } from "bun:test";
import { ProbePhaseGate } from "../tooling/probe-phase-gate.ts";
test("pending recording observations finish before phase-changing commands and cannot overlap them", async () => {
  const gate = new ProbePhaseGate(),
    order: string[] = [];
  const observation = Promise.withResolvers<void>(),
    command = Promise.withResolvers<void>();
  expect(
    gate.observe(async () => {
      order.push("observe-start");
      await observation.promise;
      order.push("observe-end");
    }),
  ).toBe(true);
  await Promise.resolve();
  const completion = gate.command(async () => {
    order.push("phase-change");
    await command.promise;
    order.push("phase-done");
  });
  expect(
    gate.observe(async () => {
      order.push("late-stale-observation");
    }),
  ).toBe(false);
  expect(order).toEqual(["observe-start"]);
  observation.resolve();
  await gate.settle();
  await Promise.resolve();
  expect(order).toEqual(["observe-start", "observe-end", "phase-change"]);
  expect(gate.observe(async () => {})).toBe(false);
  command.resolve();
  await completion;
  expect(order).toEqual([
    "observe-start",
    "observe-end",
    "phase-change",
    "phase-done",
  ]);
  expect(
    gate.observe(async () => {
      order.push("new-phase-observation");
    }),
  ).toBe(true);
  await gate.settle();
  expect(order.at(-1)).toBe("new-phase-observation");
});
test("observation failures fail the next command instead of becoming false successful hold evidence", async () => {
  const gate = new ProbePhaseGate();
  gate.observe(async () => {
    throw new Error("probe_continuous_hold_interrupted");
  });
  await gate.settle();
  let commandRan = false;
  await expect(
    gate.command(async () => {
      commandRan = true;
    }),
  ).rejects.toThrow("probe_continuous_hold_interrupted");
  expect(commandRan).toBe(false);
  expect(gate.observe(async () => {})).toBe(false);
});

test("an opaque observation rejection cannot become successful hold evidence", async () => {
  const gate = new ProbePhaseGate();
  gate.observe(async () => {
    throw undefined;
  });
  await gate.settle();
  let commandRan = false,
    rejected = false;
  try {
    await gate.command(async () => {
      commandRan = true;
    });
  } catch {
    rejected = true;
  }
  expect(rejected).toBe(true);
  expect(commandRan).toBe(false);
});
