import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
const peer = fileURLToPath(new URL("./peer.mjs", import.meta.url));
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const EXPECTED = "configuration_response_invalid";
export async function runCase(spec, matcher) {
  const started = performance.now(),
    events = [];
  let late = 0,
    lateReplies = 0,
    eof = false,
    bytes = 0,
    lines = 0,
    stdout = "",
    stderr = "",
    pending,
    closed = false;
  const event = (code, count = 0) => {
    if (events.length >= 96) throw Error("diagnostic_log_bound");
    events.push({ code, ms: Math.floor(performance.now() - started), count });
  };
  let exited,
    send,
    end,
    kill,
    streamState = () => ({});
  function fail(code) {
    if (pending) {
      const p = pending;
      pending = undefined;
      clearTimeout(p.timer);
      p.reject(Error(code));
    }
  }
  function chunk(data) {
    bytes += data.length;
    event(eof ? "stdout-after-eof" : "stdout-chunk", data.length);
    if (bytes > 8192) {
      fail("stdout_bound");
      return;
    }
    stdout += Buffer.from(data).toString("utf8");
    for (let newline; (newline = stdout.indexOf("\n")) >= 0; ) {
      const text = stdout.slice(0, newline);
      stdout = stdout.slice(newline + 1);
      lines++;
      if (eof) {
        late++;
        try {
          const value = JSON.parse(text);
          if (
            value.requestId === "00000000-0000-0000-0000-000000000001" ||
            value.requestId === "00000000-0000-0000-0000-000000000002"
          )
            lateReplies++;
        } catch {}
        continue;
      }
      let value;
      try {
        value = JSON.parse(text);
      } catch {
        fail("invalid_json");
        continue;
      }
      if (!pending) {
        event("unsolicited-line");
        continue;
      }
      const p = pending;
      pending = undefined;
      clearTimeout(p.timer);
      try {
        if (p.kind === 0) {
          if (
            Object.keys(value).sort().join(",") !== "pid,ready,version" ||
            value.version !== 1 ||
            value.ready !== "configuration" ||
            !Number.isSafeInteger(value.pid) ||
            value.pid <= 0
          )
            throw Error("invalid_ready");
          p.resolve(value);
        } else {
          const expected = {
            version: 1,
            requestId: `00000000-0000-0000-0000-${String(p.kind).padStart(12, "0")}`,
            ok: true,
            result:
              p.kind === 1
                ? { version: 1, kind: "catalog", revision: "1", profiles: [] }
                : { version: 1, kind: "catalog", revision: "999" },
          };
          if (JSON.stringify(value) !== JSON.stringify(expected))
            throw Error("invalid_envelope");
          event("reply-validated", p.kind);
          if (p.kind === 2) p.reject(Error(EXPECTED));
          else p.resolve(value);
        }
      } catch (error) {
        p.reject(error);
      }
    }
  }
  function phases(data) {
    stderr += Buffer.from(data).toString("utf8");
    if (stderr.length > 4096) {
      fail("stderr_bound");
      return;
    }
    for (let newline; (newline = stderr.indexOf("\n")) >= 0; ) {
      const line = stderr.slice(0, newline);
      stderr = stderr.slice(newline + 1);
      try {
        const code = JSON.parse(line).phase;
        if (
          [
            "write-resolved",
            "write-callback",
            "request-received",
            "stdin-eof",
            "complete",
            "watchdog",
          ].includes(code)
        )
          event("child-" + code);
      } catch {
        event("child-error-text");
      }
    }
  }
  function expect(kind, budget) {
    return new Promise((resolve, reject) => {
      if (pending) throw Error("overlap");
      pending = {
        kind,
        resolve,
        reject,
        timer: setTimeout(() => {
          event("reply-timeout", kind);
          fail("reply_timeout");
        }, budget),
      };
    });
  }
  const ready = expect(0, 2000); // Attached before spawn/readers; child cannot outrun admission.
  const runtime = spec.child === "node" ? spec.node : spec.bun;
  if (spec.parent === "node-spawn") {
    const child = spawn(runtime, [peer, spec.writer], {
      stdio: ["pipe", "pipe", "pipe"],
    });
    child.stdout.on("data", chunk);
    child.stderr.on("data", phases);
    child.stdout.on("end", () => event("stdout-ended"));
    child.stderr.on("end", () => event("stderr-ended"));
    child.on("exit", (code) => event("child-exit", code ?? -1));
    child.on("error", () => fail("spawn_error"));
    exited = new Promise((resolve) =>
      child.once("close", (code) => {
        closed = true;
        event("child-closed", code ?? -1);
        resolve(code);
      }),
    );
    streamState = () => ({
      flowing: child.stdout.readableFlowing === true,
      readableBytes: child.stdout.readableLength,
    });
    send = (text) =>
      new Promise((resolve, reject) =>
        child.stdin.write(text, (error) => {
          event("stdin-callback");
          error ? reject(Error("stdin_write_failed")) : resolve();
        }),
      );
    child.stdin.on("error", () => fail("stdin_error"));
    end = () => child.stdin.end(() => event("stdin-finished"));
    kill = () => child.kill("SIGKILL");
  } else {
    const child = Bun.spawn([runtime, peer, spec.writer], {
      stdin: "pipe",
      stdout: "pipe",
      stderr: "pipe",
    });
    const processExit = child.exited.then((code) => {
      closed = true;
      event("child-exit", code);
      return code;
    });
    async function pump(stream, consume) {
      try {
        for await (const data of stream) consume(data);
      } catch {
        fail("stream_error");
      }
    }
    exited = Promise.all([
      processExit,
      pump(child.stdout, chunk),
      pump(child.stderr, phases),
    ]).then(([code]) => {
      event("child-closed", code);
      return code;
    });
    send = async (text) => {
      child.stdin.write(text);
      await child.stdin.flush();
      event("stdin-flushed");
    };
    end = () => child.stdin.end(() => event("stdin-finished"));
    kill = () => child.kill("SIGKILL");
  }
  const sampler = setInterval(() => {
    const state = streamState();
    event("parent-pending", pending?.kind ?? -1);
    if (state.flowing !== undefined)
      event(
        state.flowing ? "parent-flowing" : "parent-not-flowing",
        state.readableBytes ?? 0,
      );
  }, 1000);
  let failure = null,
    matched = false,
    code;
  try {
    await ready;
    event("ready");
    const first = expect(1, 4000);
    await Promise.all([
      send(
        JSON.stringify({
          version: 1,
          requestId: "00000000-0000-0000-0000-000000000001",
          body: { command: "configuration-list" },
        }) + "\n",
      ),
      first,
    ]);
    const second = expect(2, 4000);
    // NativePipe writes before returning its promise to expect(...).rejects.
    // Bun's matcher can synchronously pump until settlement, so start the write
    // first; do not accidentally diagnose a peer that was never sent request2.
    void second.catch(() => {});
    const sent = send(
      JSON.stringify({
        version: 1,
        requestId: "00000000-0000-0000-0000-000000000002",
        body: { command: "configuration-list" },
      }) + "\n",
    );
    const observed = matcher
      ? matcher(second)
      : second.then(
          () => {
            throw Error("expected_rejection_missing");
          },
          (error) => {
            if (error.message !== EXPECTED) throw error;
          },
        );
    await Promise.all([sent, observed]);
    matched = true;
    event("typed-rejection-matched");
    if (closed) throw Error("early_child_exit");
  } catch (error) {
    failure = [
      "reply_timeout",
      "invalid_json",
      "invalid_ready",
      "invalid_envelope",
      "stdout_bound",
      "stderr_bound",
      "spawn_error",
      "stream_error",
      "stdin_error",
      "stdin_write_failed",
      "early_child_exit",
      "expected_rejection_missing",
    ].includes(error?.message)
      ? error.message
      : "matcher_or_transport_failure";
    event("case-failed");
  } finally {
    clearInterval(sampler);
    eof = true;
    event("parent-send-eof");
    try {
      end();
    } catch {
      event("eof-failed");
    }
    code = await Promise.race([exited, wait(1000).then(() => null)]);
    if (code === null) {
      event("forced-kill");
      kill();
      code = await Promise.race([exited, wait(1000).then(() => null)]);
    }
    fail("cleanup");
  }
  if (code !== 0 && !failure) failure = "peer_exit_failed";
  if (
    !failure &&
    (!events.some((e) => e.code === "child-stdin-eof") ||
      !events.some((e) => e.code === "child-complete"))
  )
    failure = "missing_peer_eof_confirmation";
  return {
    version: 1,
    id: spec.id,
    parent: spec.parent,
    child: spec.child,
    writer: spec.writer,
    context: spec.context,
    passed: matched && !failure && late === 0,
    failure,
    replyOnlyAfterEof: lateReplies > 0 && !matched,
    lateLines: late,
    lateReplies,
    stdoutBytes: bytes,
    lines,
    events,
  };
}
if (process.argv[2] === "--row") {
  const result = await runCase(JSON.parse(process.env.THUMBLE_STDIO_CASE));
  process.stdout.write("STDIO_RESULT " + JSON.stringify(result) + "\n");
  process.exitCode = result.passed ? 0 : 1;
}
