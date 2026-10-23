import Foundation
import Network

@MainActor protocol NativeDatagramIO: AnyObject {
  func connect() async throws
  func offer(_ packet: Data) -> Bool
  func close()
}

/// One in-flight datagram and one replaceable full-state slot. No UDP receive surface.
@MainActor final class NativeDatagramClient: NativeDatagramIO {
  private enum State { case idle, opening, ready, closed }
  private var state: State = .idle
  private let connection: NWConnection
  private let queue = DispatchQueue(label: "com.thumble.rewrite.input-udp")
  private var opening: CheckedContinuation<Void, any Error>?
  private var deadline: Task<Void, Never>?
  private var latest: Data?
  private var writing = false
  init(host: String, port: UInt16) throws {
    guard !host.isEmpty, host.utf8.count <= 253, !host.contains("\0"),
      let port = NWEndpoint.Port(rawValue: port), port.rawValue > 0
    else { throw PhoneControlError.rejected }
    connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .udp)
  }
  func connect() async throws {
    guard state == .idle else { throw PhoneControlError.rejected }
    state = .opening
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        opening = continuation
        connection.stateUpdateHandler = { [weak self] state in
          Task { @MainActor in
            guard let self, self.state != .closed else { return }
            switch state {
            case .ready:
              self.state = .ready
              self.deadline?.cancel()
              self.deadline = nil
              let opening = self.opening
              self.opening = nil
              opening?.resume()
            case .failed, .cancelled: self.close()
            default: break
            }
          }
        }
        deadline = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(1)) } catch { return }
          self?.close()
        }
        connection.start(queue: queue)
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.close() }
    }
  }
  func offer(_ packet: Data) -> Bool {
    guard state == .ready, packet.count == 108 else { return false }
    latest = packet
    flush()
    return true
  }
  private func flush() {
    guard state == .ready, !writing, let packet = latest else { return }
    latest = nil
    writing = true
    connection.send(
      content: packet,
      completion: .contentProcessed { [weak self] error in
        Task { @MainActor in
          guard let self, self.state != .closed else { return }
          self.writing = false
          if error != nil { self.close() } else { self.flush() }
        }
      })
  }
  func close() {
    guard state != .closed else { return }
    state = .closed
    latest = nil
    deadline?.cancel()
    deadline = nil
    let pending = opening
    opening = nil
    connection.cancel()
    pending?.resume(throwing: PhoneControlError.rejected)
  }
}
