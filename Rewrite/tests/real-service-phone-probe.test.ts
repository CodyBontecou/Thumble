import { expect, test } from "bun:test";
import { existsSync } from "node:fs";
import { RealServicePhoneProbe } from "../tooling/real-service-phone-probe.ts";
test("real CLI phone probe seeds saved authority, activates recording receiver and stops owned service", async () => {
  const probe = new RealServicePhoneProbe();
  try {
    const offer = await probe.start();
    expect(offer.backend).toBe("real-bun-service");
    expect(offer.profileCount).toBe(2);
    const active = await probe.command("a");
    expect(active.generation).toBe("1");
    expect(active.revision).toBe("1");
    expect(active.inputEnabled).toBe(false);
    const complete = await probe.command("f");
    expect(complete.completed).toBe(true);
    expect(existsSync(probe.parent)).toBe(false);
  } finally {
    await probe.close();
  }
}, 20000);
