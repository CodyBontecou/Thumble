#if os(macOS)
  import Foundation
  import Testing

  @Test @MainActor private func syntheticProbeReadsAndExitWaitDoNotStarveNativeSamplingActor()
    async throws
  {
    let probe = NativeProbeProcess(
      path: "/bin/sh", arguments: ["-c", "sleep 0.5; printf 'ready\\n'; sleep 0.5"])
    var ticks = 0
    let sampling = Task { @MainActor in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
        ticks += 1
      }
    }
    defer { sampling.cancel() }
    do {
      try await probe.start()
      #expect(try await probe.line() == Data("ready".utf8))
      #expect(ticks >= 10)
      #expect(await probe.wait() == 0)
      #expect(ticks >= 30)
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
