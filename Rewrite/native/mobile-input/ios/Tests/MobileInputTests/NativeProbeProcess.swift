#if os(macOS)
  import Foundation

  /// Test-only fixed metadata. Never retain argv, stdout values or stderr payloads.
  private final class ProbeDiagnosticIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func next() -> UInt64 {
      lock.lock()
      defer { lock.unlock() }
      value += 1
      return value
    }
  }

  private final class ProbeDiagnosticState: @unchecked Sendable {
    private static let ids = ProbeDiagnosticIDs()
    private let lock = NSLock()
    private let enabled: Bool
    private let identifier: UInt64
    private let sink: @Sendable (String) -> Void
    private var stage = "startup"
    private var events = 0
    private var firstOutcome: String?
    private var cleaningUp = false
    init(enabled: Bool, sink: (@Sendable (String) -> Void)?) {
      self.enabled = enabled
      identifier = enabled ? Self.ids.next() : 0
      self.sink =
        sink ?? { line in
          try? FileHandle.standardError.write(contentsOf: Data((line + "\n").utf8))
        }
    }
    func command(_ byte: UInt8) {
      lock.lock()
      stage = (97...122).contains(byte) ? "command-" + String(UnicodeScalar(byte)) : "command-other"
      lock.unlock()
    }
    func beginCleanup() {
      lock.lock()
      cleaningUp = true
      lock.unlock()
    }
    func record(_ event: String, outcome: String = "none") {
      guard enabled else { return }
      lock.lock()
      guard !cleaningUp else {
        lock.unlock()
        return
      }
      if outcome != "none" {
        guard firstOutcome == nil else {
          lock.unlock()
          return
        }
        firstOutcome = outcome
      } else if events >= 64 {
        lock.unlock()
        return
      }
      events += 1
      let line =
        "native_probe_stage instance=\(identifier) stage=\(stage) event=\(event) outcome=\(outcome)"
      lock.unlock()
      sink(line)
    }
    func eof() {
      lock.lock()
      let claimed = firstOutcome != nil
      lock.unlock()
      if !claimed { record("failed", outcome: "early-eof") }
    }
  }

  /// Synthetic test process I/O must never block the UI/input sampling actor.
  actor NativeProbeProcess {
    enum Failure: Error { case closed, lineTooLong, alreadyStarted }
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let timeout: Duration
    private let diagnostics: ProbeDiagnosticState
    private var deadline: Task<Void, Never>?
    private var started = false
    init(
      path: String, arguments: [String] = [], timeout: Duration = .seconds(15),
      diagnosticsEnabled: Bool? = nil, diagnosticSink: (@Sendable (String) -> Void)? = nil
    ) {
      process.executableURL = URL(fileURLWithPath: path)
      process.arguments = arguments
      process.standardInput = input
      process.standardOutput = output
      self.timeout = timeout
      diagnostics = ProbeDiagnosticState(
        enabled: diagnosticsEnabled
          ?? (ProcessInfo.processInfo.environment["THUMBLE_REWRITE_PROBE_STAGE_DIAGNOSTICS"] == "1"),
        sink: diagnosticSink)
    }
    func start() throws {
      guard !started else { throw Failure.alreadyStarted }
      do { try process.run() } catch {
        diagnostics.record("failed", outcome: "start-failed")
        throw error
      }
      diagnostics.record("started")
      started = true
      deadline = Task.detached { [process, timeout, diagnostics] in
        do { try await Task.sleep(for: timeout) } catch { return }
        if process.isRunning {
          diagnostics.record("failed", outcome: "owned-watchdog")
          process.terminate()
        }
      }
    }
    func line(maximum: Int = 65536) throws -> Data {
      var data = Data()
      while data.count < maximum {
        guard let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty else {
          diagnostics.eof()
          throw Failure.closed
        }
        if byte[0] == 10 {
          diagnostics.record("received")
          return data
        }
        data.append(byte)
      }
      diagnostics.record("failed", outcome: "line-bounds")
      throw Failure.lineTooLong
    }
    func send(_ value: UInt8) throws {
      diagnostics.command(value)
      do { try input.fileHandleForWriting.write(contentsOf: Data([value])) } catch {
        diagnostics.record("failed", outcome: "write-failed")
        throw error
      }
      diagnostics.record("sent")
    }
    func wait() -> Int32 {
      process.waitUntilExit()
      deadline?.cancel()
      deadline = nil
      if process.terminationStatus != 0 {
        diagnostics.record("failed", outcome: "process-exit")
      }
      return process.terminationStatus
    }
    func stop() {
      guard started else { return }
      diagnostics.beginCleanup()
      if process.isRunning { process.terminate() }
      process.waitUntilExit()
      deadline?.cancel()
      deadline = nil
    }
  }
#endif
