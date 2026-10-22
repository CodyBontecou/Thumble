import { expect, test } from "bun:test";
import { RuntimeController, type ReceiverPort } from "@thumble/application";
const NEUTRAL_GAMEPAD_STATE = {
  buttons: [],
  leftStickX: 0,
  leftStickY: 0,
  rightStickX: 0,
  rightStickY: 0,
  leftTrigger: 0,
  rightTrigger: 0,
};
import {
  decodeSnapshot,
  type Snapshot,
  type ReceiverCommand,
} from "@thumble/contracts/receiver";
import { NativeReceiver } from "../apps/service/src/native-receiver.ts";

function snapshot(patch: Partial<Snapshot> = {}): Snapshot {
  return decodeSnapshot({
    backend: "recording",
    inputEnabled: false,
    active: true,
    generation: "1",
    revision: "1",
    profileId: "profile",
    sequence: null,
    reportHex: "0014000000000000000000000000000000000000",
    lastReleaseReason: "activation_barrier",
    ...patch,
  });
}

test("receiver status admits explicit physical output only while active", () => {
  expect(
    snapshot({ backend: "macos-hid", inputEnabled: true }).inputEnabled,
  ).toBe(true);
  expect(
    snapshot({ backend: "macos-hid", inputEnabled: false, active: false })
      .inputEnabled,
  ).toBe(false);
  expect(() => snapshot({ inputEnabled: true })).toThrow(
    "invalid_receiver_response",
  );
  expect(() =>
    snapshot({ backend: "macos-hid", inputEnabled: true, active: false }),
  ).toThrow("invalid_receiver_response");
  expect(() => decodeSnapshot({ ...snapshot(), backend: "unknown" })).toThrow(
    "invalid_receiver_response",
  );
});

test("recorded debug samples never enter a physical receiver, including temporarily disabled output", async () => {
  for (const inputEnabled of [false, true]) {
    const commands: ReceiverCommand[] = [];
    const receiver: ReceiverPort = {
      async request(command) {
        commands.push(command);
        if (command.command === "activate")
          return snapshot({ backend: "macos-hid", inputEnabled });
        return snapshot({ backend: "macos-hid", inputEnabled });
      },
    };
    const controller = new RuntimeController(receiver, () => "session");
    await controller.execute({
      command: "activate",
      expectedRevision: "1",
      profileId: "profile",
    });
    await expect(
      controller.execute({
        command: "sample",
        expectedGeneration: "1",
        sequence: "1",
        state: NEUTRAL_GAMEPAD_STATE,
        allowRecordedInput: true,
      }),
    ).rejects.toThrow("recorded_input_requires_recording_backend");
    expect(commands.filter((c) => c.command === "sample")).toHaveLength(0);
  }
});

test("physical receiver launch requires a literal opt-in before child creation", () => {
  const missing = JSON.parse('{"backend":"macos-hid"}');
  expect(
    () =>
      new NativeReceiver("nonexistent-child", "/unused", "/unused", missing),
  ).toThrow("physical_output_explicit_flag_required");
});
