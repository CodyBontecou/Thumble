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
