import { expect, test } from "bun:test";
import { resolve } from "node:path";
import { NativePipe } from "../apps/service/src/native-pipe.ts";
import { ConfigurationOwner } from "../apps/service/src/configuration-owner.ts";
import { PhoneEditorBridge } from "../apps/service/src/phone-editor-bridge.ts";
import { confirmEditorWriterExit } from "../apps/service/src/editor-owner-exit.ts";
const helper = resolve(import.meta.dir, "fixtures/editor-pipe-owner.ts");
function owner() {
  return new ConfigurationOwner("/unused", "/unused", [
    process.execPath,
    helper,
    "owner-silent",
  ]);
}
test("idle captured configuration owner retirement confirms actual exit and never reopens dispatch", async () => {
  const actual = owner();
  try {
    const lifetime = await actual.editorOwnerLifetime();
    expect(lifetime).toBe("11111111-0000-0000-0000-000000000001");
    const retirement = actual.retireEditorOwner();
    expect(actual.retireEditorOwner()).toBe(retirement);
    await expect(actual.editorOwnerLifetime()).rejects.toThrow(
      "editor_owner_unavailable",
    );
    await retirement;
    expect(
      actual.child.exitCode !== null || actual.child.signalCode !== null,
    ).toBe(true);
    expect(actual.retireEditorOwner()).toBe(retirement);
  } finally {
    actual.disconnect();
    await confirmEditorWriterExit(actual.child);
  }
});
test("bridge retirement retains one captured owner and remains pending until actual confirmation", async () => {
  const actual = owner();
  try {
    const bridge = await PhoneEditorBridge.capture(actual);
    const retired = bridge.retireWriter();
    expect(bridge.retireWriter()).toBe(retired);
    expect(() => bridge.enableCommand()).toThrow("editor_bridge_closed");
    await retired;
    expect(
      actual.child.exitCode !== null || actual.child.signalCode !== null,
    ).toBe(true);
    await expect(actual.editorOwnerLifetime()).rejects.toThrow(
      "editor_owner_unavailable",
    );
  } finally {
    actual.disconnect();
    await confirmEditorWriterExit(actual.child);
  }
});
test("idle pairing-style stdout EOF retires the captured writer exactly once before joining native child", async () => {
  const actual = owner();
  const bridge = await PhoneEditorBridge.capture(actual);
  let failures = 0;
  let retirement: Promise<void> | undefined;
  let eofBeforeExit = false;
  const pipe: NativePipe<undefined, Record<string, unknown>> = new NativePipe(
    "node",
    [resolve(import.meta.dir, "fixtures/editor-stdout-close.mjs")],
    {
      ready: () => undefined,
      reply: (v) => v,
      failure: () => {
        failures++;
        eofBeforeExit =
          pipe.child.exitCode === null && pipe.child.signalCode === null;
        retirement = bridge.retireWriter();
      },
    },
    "pairing_host_unavailable",
  );
  // Subscribe before awaiting readiness; a fast child must not race this observer.
  const exited = new Promise<void>((resolve) =>
    pipe.child.once("exit", () => resolve()),
  );
  try {
    await pipe.ready;
    // An owned child closing stdout has no pending request timer to wake cleanup.
    await exited;
    expect(failures).toBe(1);
    expect(eofBeforeExit).toBe(true);
    expect(retirement).toBeDefined();
    await retirement;
    expect(
      actual.child.exitCode !== null || actual.child.signalCode !== null,
    ).toBe(true);
    pipe.disconnect();
    expect(failures).toBe(1);
  } finally {
    pipe.disconnect();
    actual.disconnect();
    await Promise.all([
      confirmEditorWriterExit(pipe.child),
      confirmEditorWriterExit(actual.child),
    ]);
  }
});
