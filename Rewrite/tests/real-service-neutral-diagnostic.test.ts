import { expect, test } from "bun:test";
import { neutralWaitFailure } from "../tooling/real-service-phone-probe.ts";

const neutral = "0014000000000000000000000000000000000000";
test("neutral wait failures preserve only fixed native state categories", () => {
  expect(
    neutralWaitFailure("fresh", {
      active: false,
      reportHex: neutral,
      lastReleaseReason: "input_expired",
    }),
  ).toBe("probe_fresh_timeout_inactive_neutral_input_expired");
  expect(
    neutralWaitFailure("packet_zero", {
      active: true,
      reportHex: neutral,
      lastReleaseReason: "lease_expired",
    }),
  ).toBe("probe_packet_zero_timeout_active_neutral_lease_expired");
  expect(neutralWaitFailure("fresh", undefined)).toBe(
    "probe_fresh_timeout_inactive_changed_other",
  );
  for (const lastReleaseReason of [
    "private secret token",
    "input_expired\n",
    "path/to/private",
    "",
  ]) {
    const result = neutralWaitFailure("fresh", {
      active: false,
      reportHex: "private packet bytes",
      lastReleaseReason,
    });
    expect(result).toBe("probe_fresh_timeout_inactive_changed_other");
    expect(result).not.toContain("private");
  }
});
