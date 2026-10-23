import { expect, test } from "bun:test";
import {
  RuntimeController,
  type ReceiverPort,
  type SavedReadyPolicy,
} from "@thumble/application";
import type { ReceiverCommand, Snapshot } from "@thumble/contracts/receiver";
import {
  decodeSavedRearmStatus,
  decodeSavedReadinessStatus,
  type SavedConfigurationPin,
  type SavedRuntimeBinding,
} from "@thumble/contracts/saved-runtime";
const pin: SavedConfigurationPin = {
  configurationRevision: "1",
  sourceHash: "a".repeat(64),
  profileId: "11111111-1111-1111-1111-111111111111",
};
function fixture(enabled = true) {
  let state: Snapshot = {
    backend: "macos-hid",
    inputEnabled: false,
    active: false,
    generation: "0",
    revision: "0",
    profileId: null,
    sequence: null,
    reportHex: "0014000000000000000000000000000000000000",
    lastReleaseReason: "startup",
  };
  let released: SavedRuntimeBinding | null = null,
    clean = true,
    reads = 0,
    failRead = false;
  let readGate: Promise<void> | undefined;
  const commands: ReceiverCommand[] = [];
  const port: ReceiverPort = {
    async request(command) {
      commands.push(command);
      if (command.command === "activateSaved")
        state = {
          ...state,
          active: true,
          inputEnabled: true,
          generation: command.generation,
          revision: command.revision,
          profileId: command.profileId,
          lastReleaseReason: "activation_barrier",
        };
      if (command.command === "release" || command.command === "shutdown")
        state = {
          ...state,
          active: false,
          inputEnabled: false,
          lastReleaseReason: "explicit_release",
        };
      return state;
    },
  };
  const policy: SavedReadyPolicy = {
    async readPin() {
      reads++;
      await readGate;
      if (failRead) throw Error("revision_conflict");
      return pin;
    },
    async rearmStatus() {
      return {
        snapshot: state,
        releasedBinding: released,
        cleanupReady: clean,
        firstTermination: null,
      };
    },
  };
  const controller = new RuntimeController(
    port,
    () => "owner",
    750,
    350,
    enabled ? policy : undefined,
  );
  const activate = () =>
    controller.activateSaved(
      {
        command: "activate-saved",
        expectedReceiverRevision: state.revision,
        expectedConfigurationRevision: pin.configurationRevision,
        expectedSourceHash: pin.sourceHash,
        profileId: pin.profileId,
      },
      pin,
    );
  const release = (reason = "native_input_released") => {
    released = {
      ...pin,
      generation: state.generation,
      revision: state.revision,
    };
    state = {
      ...state,
      active: false,
      inputEnabled: false,
      lastReleaseReason: reason,
    };
  };
  return {
    controller,
    pauseRead() {
      let resume!: () => void;
      readGate = new Promise<void>((resolve) => {
        resume = resolve;
      });
      return resume;
    },
    activate,
    release,
    commands,
    get state() {
      return state;
    },
    get reads() {
      return reads;
    },
    set clean(v: boolean) {
      clean = v;
    },
    set failRead(v: boolean) {
      failRead = v;
    },
    set released(v: SavedRuntimeBinding | null) {
      released = v;
    },
  };
}
test("explicit local policy re-arms exact saved neutral controller once per clean release; owner heartbeat keeps ordinary lifetime", async () => {
  const f = fixture();
  expect(f.controller.readiness().state).toBe(
    "waiting-for-explicit-activation",
  );
  await f.activate();
  expect(f.controller.readiness().state).toBe("armed");
  f.release();
  await Promise.all([f.controller.renew(), f.controller.renew()]);
  expect(f.state.active).toBe(true);
  expect(f.state.generation).toBe("2");
  expect(f.reads).toBe(1);
  expect(f.commands.filter((c) => c.command === "activateSaved")).toHaveLength(
    2,
  );
  expect(f.commands.some((c) => c.command === "sample")).toBe(false);
  f.release();
  await f.controller.renew();
  expect(f.state.generation).toBe("3");
});
test("default, owner expiry, explicit operator release, and unknown cleanup never auto-activate", async () => {
  for (const reason of [
    "lease_expired",
    "input_expired",
    "output_failed",
    "explicit_release",
  ]) {
    const f = fixture();
    await f.activate();
    f.release(reason);
    await f.controller.renew();
    expect(f.state.active).toBe(false);
    expect(f.reads).toBe(0);
  }
  const off = fixture(false);
  await off.activate();
  off.release();
  await off.controller.renew();
  expect(off.state.active).toBe(false);
  const f = fixture();
  await f.activate();
  await f.controller.execute({ command: "release" });
  f.release();
  await f.controller.renew();
  expect(f.reads).toBe(0);
});
test("stale catalog, mismatched retired pin and uncertain cleanup latch; only explicit saved activation recovers", async () => {
  for (const failure of ["catalog", "cleanup", "pin"]) {
    const f = fixture();
    await f.activate();
    f.release();
    if (failure === "catalog") f.failRead = true;
    if (failure === "cleanup") f.clean = false;
    if (failure === "pin")
      f.released = {
        ...pin,
        sourceHash: "b".repeat(64),
        generation: "1",
        revision: "1",
      };
    await f.controller.renew();
    f.failRead = false;
    f.clean = true;
    await f.controller.renew();
    expect(f.state.active).toBe(false);
    expect(f.reads).toBe(1);
    expect(f.controller.readiness().state).toBe("latched");
    expect(f.controller.readiness().reason).toBe(
      failure === "catalog"
        ? "catalog-recheck-failed"
        : failure === "cleanup"
          ? "retirement-unconfirmed"
          : "binding-changed",
    );
    await f.activate();
    f.release();
    await f.controller.renew();
    expect(f.state.active).toBe(true);
  }
});
test("strict local native cleanup proof cannot be inferred from release reason or recording backend", () => {
  const f = fixture();
  const snapshot = {
    ...f.state,
    generation: "1",
    revision: "1",
    lastReleaseReason: "native_input_released",
    profileId: pin.profileId,
  };
  const releasedBinding = { ...pin, generation: "1", revision: "1" };
  expect(
    decodeSavedRearmStatus({
      snapshot,
      releasedBinding,
      cleanupReady: true,
      firstTermination: null,
    }).cleanupReady,
  ).toBe(true);
  for (const mutation of [
    { snapshot: { ...snapshot, backend: "recording" } },
    { snapshot: { ...snapshot, active: true } },
    { releasedBinding: null },
    { releasedBinding: { ...releasedBinding, generation: "2" } },
    { cleanupReady: "true" },
  ]) {
    let error: unknown;
    try {
      decodeSavedRearmStatus({
        snapshot,
        releasedBinding,
        cleanupReady: true,
        firstTermination: null,
        ...mutation,
      });
    } catch (e) {
      error = e;
    }
    expect(error).toBeInstanceOf(Error);
  }
});

test("native change during catalog wait cannot be overridden and operator release remains serialized", async () => {
  const f = fixture();
  await f.activate();
  f.release();
  const resume = f.pauseRead();
  const pending = f.controller.renew();
  while (f.reads === 0) await Promise.resolve();
  expect(f.controller.readiness().state).toBe("rearming");
  // Change the native proof while the sole-authority read is in flight.
  f.released = { ...pin, generation: "2", revision: "2" };
  resume();
  await pending;
  expect(f.commands.filter((c) => c.command === "activateSaved")).toHaveLength(
    1,
  );
  await f.activate();
  f.release();
  await Promise.all([
    f.controller.renew(),
    f.controller.execute({ command: "release" }),
  ]);
  expect(f.state.active).toBe(false);
  expect(f.controller.readiness()).toEqual({
    state: "waiting-for-explicit-activation",
    reason: "operator-release",
  });
  await f.controller.renew();
  expect(f.state.active).toBe(false);
});

test("actual recording native owner serves strict read-only rearm status without activation", async () => {
  const { mkdtempSync, rmSync } = await import("node:fs");
  const { join, resolve } = await import("node:path");
  const { tmpdir } = await import("node:os");
  const { NativeReceiver } = await import(
    "../apps/service/src/native-receiver.ts"
  );
  const { secureDirectory } = await import("../apps/service/src/service.ts");
  const executable = resolve(
    import.meta.dir,
    "../native/receiver/target/debug/thumble-rewrite-receiver" +
      (process.platform === "win32" ? ".exe" : ""),
  );
  const directory = secureDirectory(
    executable,
    mkdtempSync(join(tmpdir(), "thumble-ready-")),
  );
  const native = new NativeReceiver(
    executable,
    directory,
    join(directory, "recording.jsonl"),
  );
  try {
    await native.ready;
    const proof = await native.rearmStatus();
    expect(proof.cleanupReady).toBe(false);
    expect(proof.releasedBinding).toBe(null);
    expect(proof.snapshot.active).toBe(false);
    expect((await native.savedStatus()).savedBinding).toBe(null);
    await native.request({ command: "shutdown" });
  } finally {
    native.disconnect();
    if (native.child.exitCode === null)
      await new Promise<void>((resolve) => {
        const timer = setTimeout(() => {
          native.child.kill("SIGKILL");
          resolve();
        }, 1000);
        native.child.once("exit", () => {
          clearTimeout(timer);
          resolve();
        });
      });
    rmSync(directory, { recursive: true, force: true });
  }
});

test("operator release eagerly disarms maintenance blocked on catalog before any new factory activation", async () => {
  const f = fixture();
  await f.activate();
  f.release();
  const resume = f.pauseRead();
  const maintenance = f.controller.renew();
  while (f.reads === 0) await Promise.resolve();
  const release = f.controller.execute({ command: "release" });
  expect(f.controller.readiness()).toEqual({
    state: "waiting-for-explicit-activation",
    reason: "operator-release",
  });
  resume();
  await Promise.all([maintenance, release]);
  expect(f.commands.filter((c) => c.command === "activateSaved")).toHaveLength(
    1,
  );
  expect(f.state.active).toBe(false);
});

test("readiness policy requires explicit physical launch and inspection replies are strictly bounded", () => {
  const cli = new URL("../apps/cli/src/main.ts", import.meta.url).pathname;
  const child = Bun.spawnSync(
    [
      process.execPath,
      cli,
      "service",
      "start",
      "--keep-saved-controller-ready",
      "--json",
    ],
    { stdout: "pipe", stderr: "pipe" },
  );
  expect(child.exitCode).toBe(1);
  expect(JSON.parse(child.stdout.toString()).error).toBe(
    "saved_controller_ready_requires_physical_output",
  );
  expect(child.stderr.toString()).toBe("");
  const status = {
    kind: "saved-readiness",
    firstTermination: null,
    serviceInstanceId: "service",
    servicePid: 1,
    receiverPid: 2,
    state: "disabled",
    reason: "policy-disabled",
  };
  expect(decodeSavedReadinessStatus(status).state).toBe("disabled");
  for (const patch of [
    { state: "unknown" },
    { reason: "raw-error-secret" },
    { extra: true },
    { receiverPid: 0 },
  ]) {
    let error: unknown;
    try {
      decodeSavedReadinessStatus({ ...status, ...patch });
    } catch (e) {
      error = e;
    }
    expect(error).toBeInstanceOf(Error);
  }
});
