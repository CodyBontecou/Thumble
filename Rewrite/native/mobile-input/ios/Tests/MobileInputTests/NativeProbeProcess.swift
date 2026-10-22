#if os(macOS)
  import Foundation

  /// Synthetic test process I/O must never block the UI/input sampling actor.
  actor NativeProbeProcess {
    enum Failure: Error { case closed, lineTooLong, alreadyStarted }
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let timeout: Duration
    private var deadline: Task<Void, Never>?
    private var started = false
    init(path: String, arguments: [String] = [], timeout: Duration = .seconds(15)) {
      process.executableURL = URL(fileURLWithPath: path)
      process.arguments = arguments
      process.standardInput = input
      process.standardOutput = output
      self.timeout = timeout
    }
    func start() throws {
      guard !started else { throw Failure.alreadyStarted }
      try process.run()
      started = true
      deadline = Task.detached { [process, timeout] in
        do { try await Task.sleep(for: timeout) } catch { return }
        if process.isRunning { process.terminate() }
      }
    }
    func line(maximum: Int = 65536) throws -> Data {
      var data = Data()
      while data.count < maximum {
        guard let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty else {
          throw Failure.closed
        }
        if byte[0] == 10 { return data }
        data.append(byte)
      }
      throw Failure.lineTooLong
    }
    func send(_ value: UInt8) throws {
      try input.fileHandleForWriting.write(contentsOf: Data([value]))
    }
    func wait() -> Int32 {
      process.waitUntilExit()
      deadline?.cancel()
      deadline = nil
      return process.terminationStatus
    }
    func stop() {
      guard started else { return }
      if process.isRunning { process.terminate() }
      process.waitUntilExit()
      deadline?.cancel()
      deadline = nil
    }
  }
#endif
