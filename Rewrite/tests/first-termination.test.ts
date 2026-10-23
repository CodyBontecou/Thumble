import { expect, test } from "bun:test";
import {
  decodeFirstTermination,
  decodeSavedRearmStatus,
  decodeSavedReadinessStatus,
} from "@thumble/contracts/saved-runtime";
const first = {
  reason: "input_expired",
  generation: "1",
  revision: "2",
} as const;
const snapshot = {
  backend: "recording",
  inputEnabled: false,
  active: false,
  generation: "1",
  revision: "2",
  profileId: null,
  sequence: null,
  reportHex: "0014000000000000000000000000000000000000",
  lastReleaseReason: "native_input_released",
};
test("first termination is strict fixed metadata independent of later cleanup and disabled policy", () => {
  expect(decodeFirstTermination(null)).toBe(null);
  expect(decodeFirstTermination(first)).toEqual(first);
  expect(
    decodeSavedRearmStatus({
      snapshot,
      releasedBinding: null,
      cleanupReady: false,
      firstTermination: first,
    }).firstTermination,
  ).toEqual(first);
  expect(
    decodeSavedReadinessStatus({
      kind: "saved-readiness",
      serviceInstanceId: "service",
      servicePid: 1,
      receiverPid: 2,
      state: "disabled",
      reason: "policy-disabled",
      firstTermination: first,
    }).firstTermination,
  ).toEqual(first);
  for (const value of [
    undefined,
    { ...first, reason: "raw-error-secret" },
    { ...first, generation: "01" },
    { ...first, revision: "0" },
    { ...first, extra: true },
    { ...first, reason: null },
  ]) {
    expect(() => decodeFirstTermination(value)).toThrow();
    expect(() =>
      decodeSavedRearmStatus({
        snapshot,
        releasedBinding: null,
        cleanupReady: false,
        firstTermination: value,
      }),
    ).toThrow();
  }
});
