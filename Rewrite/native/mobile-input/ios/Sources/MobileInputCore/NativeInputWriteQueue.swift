import Foundation

/// Main-actor routing metadata, never packet authentication. Array storage remains COW and bounded.
@MainActor final class NativeInputWriteQueue {
  private struct Queued {
    let frame: ControlTLSFrame
    let offered: ContinuousClock.Instant?
  }
  private var controls: [Queued] = []
  private var latest: Queued?
  private var scope: Data?
  private var written: UInt64?
  private var acknowledged: UInt64?
  private var pending: [UInt64] = []
  private var clock: (() -> ContinuousClock.Instant)?
  private var barrier = false
  private var closed = false

  func enable(now: @escaping () -> ContinuousClock.Instant) throws {
    guard !closed, clock == nil, controls.isEmpty, latest == nil else {
      throw ControlTLSError.rejected
    }
    clock = now
  }
  func offer(_ frame: ControlTLSFrame) throws {
    guard !closed else { throw ControlTLSError.rejected }
    let queued = Queued(frame: frame, offered: frame.kind == .input ? clock?() : nil)
    if frame.kind == .control || frame.startsInputGrant {
      guard controls.count < 8 else { throw ControlTLSError.rejected }
      if frame.kind == .control && clock != nil { barrier = true }
      if frame.startsInputGrant { latest = nil }
      controls.append(queued)
    } else {
      latest = queued
    }
  }
  private func metadata(_ frame: ControlTLSFrame) throws -> (Data, UInt64) {
    let packet = frame.payload
    guard frame.kind == .input, packet.count == 108,
      packet.prefix(8) == Data([84, 72, 73, 49, 0, 0, 0, 0])
    else { throw ControlTLSError.rejected }
    let sequence = packet.dropFirst(32).prefix(8).enumerated().reduce(UInt64(0)) {
      $0 | (UInt64($1.element) << ($1.offset * 8))
    }
    guard sequence < 1_048_576 else { throw ControlTLSError.rejected }
    return (Data(packet.prefix(32)), sequence)
  }
  /// Reserve credit before handing the frame to NWConnection, including its active write.
  func next() throws -> ControlTLSFrame? {
    guard !closed else { return nil }
    while true {
      let queued: Queued
      if !controls.isEmpty {
        queued = controls.removeFirst()
      } else if let input = latest {
        if clock != nil {
          if barrier { return nil }
          let (header, sequence) = try metadata(input.frame)
          if scope == header && (acknowledged.map({ sequence > $0 }) ?? true),
            pending.count >= 8
          {
            return nil
          }
        }
        queued = input
        latest = nil
      } else {
        return nil
      }
      guard queued.frame.kind == .input, let clock else { return queued.frame }
      guard let offered = queued.offered else { throw ControlTLSError.rejected }
      let now = clock()
      guard now >= offered, offered.duration(to: now) < .milliseconds(350) else {
        throw ControlTLSError.rejected
      }
      let (header, sequence) = try metadata(queued.frame)
      if scope == nil {
        guard sequence == 0, pending.isEmpty else { throw ControlTLSError.rejected }
        scope = header
      }
      guard scope == header else { throw ControlTLSError.rejected }
      if acknowledged.map({ sequence <= $0 }) == true { continue }
      guard pending.count < 8, written.map({ sequence > $0 }) ?? true else {
        throw ControlTLSError.rejected
      }
      pending.append(sequence)
      written = sequence
      return queued.frame
    }
  }
  /// Only called after the owner validates current session/map and the shared UDP/TLS counter.
  func acknowledge(scope header: Data, sequence: UInt64, highestOffered: UInt64) throws {
    guard !closed else { throw ControlTLSError.rejected }
    guard clock != nil else { return }
    guard header.count == 32, scope == header, sequence <= highestOffered,
      acknowledged.map({ sequence >= $0 }) ?? true
    else { throw ControlTLSError.rejected }
    acknowledged = sequence
    pending.removeAll { $0 <= sequence }
  }
  func completeControl() throws {
    guard !closed else { throw ControlTLSError.rejected }
    barrier = false
  }
  /// A strict renewal response behind our held writer barrier proves all prior TLS inputs consumed.
  func validatedRenewalReply() throws {
    guard !closed else { throw ControlTLSError.rejected }
    guard clock != nil else { return }
    guard barrier, !controls.contains(where: { $0.frame.kind == .input }) else {
      throw ControlTLSError.rejected
    }
    scope = nil
    written = nil
    acknowledged = nil
    pending.removeAll()
  }
  func close() {
    closed = true
    controls.removeAll()
    latest = nil
    pending.removeAll()
    scope = nil
    barrier = true
  }
}
