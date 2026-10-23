#if os(macOS)
  import Foundation
  import Testing

  @Test @MainActor private func syntheticProbeReadsAndExitWaitDoNotStarveNativeSamplingActor()
    async throws
  {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "thumble-probe-barrier-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let readGate = directory.appendingPathComponent("read")
    let exitGate = directory.appendingPathComponent("exit")
    // The child cannot produce output/exit until a task on the input actor
    // opens each gate. This tests progress, without machine-speed thresholds.
    let probe = NativeProbeProcess(
      path: "/bin/sh",
      arguments: [
        "-c",
        "while [ ! -f \"$1\" ]; do sleep 0.01; done; printf 'ready\\n'; while [ ! -f \"$2\" ]; do sleep 0.01; done",
        "thumble-probe-barrier", readGate.path, exitGate.path,
      ])
    var sampledDuringRead = false
    var sampledDuringExit = false
    do {
      try await probe.start()
      let readSample = Task { @MainActor in
        await Task.yield()
        sampledDuringRead = true
        try Data().write(to: readGate)
      }
      #expect(try await probe.line() == Data("ready".utf8))
      try await readSample.value
      #expect(sampledDuringRead)
      let exitSample = Task { @MainActor in
        await Task.yield()
        sampledDuringExit = true
        try Data().write(to: exitGate)
      }
      #expect(await probe.wait() == 0)
      try await exitSample.value
      #expect(sampledDuringExit)
      await probe.stop()
    } catch {
      await probe.stop()
      throw error
    }
  }

#endif

#if os(macOS)
  @Test @MainActor
  private func syntheticProbeDeadlineUnblocksReaderWithoutRunningAnActorIsolatedTimerOffActor()
    async throws
  {
    let probe = NativeProbeProcess(
      path: "/bin/sleep", arguments: ["3"], timeout: .milliseconds(100))
    let started = ContinuousClock.now
    do {
      try await probe.start()
      await #expect(throws: NativeProbeProcess.Failure.self) { try await probe.line() }
      await probe.stop()
      #expect(started.duration(to: .now) < .seconds(2))
    } catch {
      await probe.stop()
      throw error
    }
  }
  @Test @MainActor private func syntheticProbeBoundsLinesAndCleansUpFailedStartup() async throws {
    let missing = NativeProbeProcess(path: "/thumble-synthetic-probe-that-does-not-exist")
    await #expect(throws: (any Error).self) { try await missing.start() }
    await missing.stop()
    let probe = NativeProbeProcess(path: "/usr/bin/printf", arguments: ["synthetic\\n"])
    do {
      try await probe.start()
      await #expect(throws: NativeProbeProcess.Failure.self) { try await probe.start() }
      await #expect(throws: NativeProbeProcess.Failure.self) { try await probe.line(maximum: 3) }
      await probe.stop()
    } catch {
      await probe.stop()
      throw error
    }
  }
#endif

#if os(macOS)
  private final class ProbeDiagnosticLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) {
      lock.lock()
      defer { lock.unlock() }
      lines.append(line)
    }
    func snapshot() -> [String] {
      lock.lock()
      defer { lock.unlock() }
      return lines
    }
  }
  @Test private func syntheticProbeDiagnosticsDistinguishEarlyEOFAndOwnedWatchdogBeforeCleanup()
    async throws
  {
    for watchdog in [false, true] {
      let lines = ProbeDiagnosticLines()
      let probe = NativeProbeProcess(
        path: watchdog ? "/bin/sleep" : "/bin/sh", arguments: watchdog ? ["3"] : ["-c", "exit 7"],
        timeout: .milliseconds(100), diagnosticsEnabled: true, diagnosticSink: { lines.append($0) })
      try await probe.start()
      await #expect(throws: NativeProbeProcess.Failure.self) { try await probe.line() }
      let beforeCleanup = lines.snapshot()
      #expect(beforeCleanup.filter { $0.contains("outcome=none") == false }.count == 1)
      #expect(
        beforeCleanup.contains {
          $0.hasSuffix("outcome=" + (watchdog ? "owned-watchdog" : "early-eof"))
        })
      await probe.stop()
      #expect(lines.snapshot() == beforeCleanup)
    }
  }
  @Test private func syntheticProbeDiagnosticsAreOptInAndDoNotReflectCommandPayloads() async throws
  {
    for enabled in [false, true] {
      let lines = ProbeDiagnosticLines()
      let probe = NativeProbeProcess(
        path: "/bin/cat", diagnosticsEnabled: enabled, diagnosticSink: { lines.append($0) })
      try await probe.start()
      try await probe.send(113)
      try await probe.send(10)
      #expect(try await probe.line() == Data([113]))
      await probe.stop()
      let captured = lines.snapshot()
      if enabled {
        #expect(captured.contains { $0.contains("stage=command-q event=sent outcome=none") })
        #expect(
          captured.contains { $0.contains("stage=command-other event=received outcome=none") })
        #expect(captured.allSatisfy { $0.utf8.count < 160 && !$0.contains("/bin/cat") })
      } else {
        #expect(captured.isEmpty)
      }
    }
  }
#endif

#if os(macOS)
  @Test private func syntheticProbeCleanupDoesNotBecomeFirstFailure() async throws {
    let lines = ProbeDiagnosticLines()
    let probe = NativeProbeProcess(
      path: "/bin/sleep", arguments: ["3"], diagnosticsEnabled: true,
      diagnosticSink: { lines.append($0) })
    try await probe.start()
    await probe.stop()
    await #expect(throws: NativeProbeProcess.Failure.self) { try await probe.line() }
    #expect(await probe.wait() != 0)
    #expect(lines.snapshot().allSatisfy { $0.hasSuffix("outcome=none") })
  }
#endif
