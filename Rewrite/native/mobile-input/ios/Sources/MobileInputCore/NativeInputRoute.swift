import Foundation

/// One native source and counter across transports. No queue or resealing on fallback.
@MainActor final class NativeInputRoute {
  private let udp: (Data) -> Bool
  private let tls: (Data) -> Bool
  private let now: () -> UInt64
  private let progressObserved: (Data, UInt64, UInt64) throws -> Void
  private var scope: Data?
  private var next: UInt64 = 0
  private var lastTime: UInt64?
  private var pending: [(sequence: UInt64, time: UInt64)] = []
  private(set) var lastOffered: UInt64?
  private(set) var acknowledged: UInt64?
  private(set) var reliable = false
  private(set) var closed = false
  init(
    now: @escaping () -> UInt64, udp: @escaping (Data) -> Bool, tls: @escaping (Data) -> Bool,
    initiallyReliable: Bool = false,
    progressObserved: @escaping (Data, UInt64, UInt64) throws -> Void = { _, _, _ in }
  ) {
    reliable = initiallyReliable
    self.now = now
    self.progressObserved = progressObserved
    self.udp = udp
    self.tls = tls
  }
  private func checkpoint() -> UInt64? {
    let time = now()
    guard !closed, lastTime.map({ time >= $0 }) ?? true else {
      close()
      return nil
    }
    lastTime = time
    return time
  }
  func close() {
    closed = true
    pending.removeAll()
    scope = nil
  }
  func offer(_ packet: Data) -> Bool {
    guard let time = checkpoint(), packet.count == 108,
      packet.prefix(8) == Data([84, 72, 73, 49, 0, 0, 0, 0]), next < 1_048_576
    else {
      close()
      return false
    }
    let header = Data(packet.prefix(32))
    guard scope.map({ $0 == header }) ?? true else {
      close()
      return false
    }
    let sequence = packet.dropFirst(32).prefix(8).enumerated().reduce(UInt64(0)) {
      $0 | (UInt64($1.element) << ($1.offset * 8))
    }
    guard sequence == next else {
      close()
      return false
    }
    scope = header
    if pending.count >= 64 || pending.first.map({ time - $0.time >= 150 }) == true {
      reliable = true
    }
    // Reliable neutral admission protects the source while UDP is being established.
    let sent: Bool
    if next == 0 || reliable {
      sent = tls(packet)
    } else if udp(packet) {
      sent = true
    } else {
      reliable = true
      sent = tls(packet)
    }
    guard sent, !closed else {
      close()
      return false
    }
    if reliable { pending.removeAll() } else { pending.append((sequence, time)) }
    lastOffered = sequence
    next += 1
    return true
  }
  func observe(_ progress: PhoneInputProgress) -> Bool {
    guard checkpoint() != nil, progress.active else {
      close()
      return false
    }
    if let sequence = progress.lastAccepted {
      guard let lastOffered, sequence <= lastOffered,
        acknowledged.map({ sequence >= $0 }) ?? true
      else {
        close()
        return false
      }
      guard let scope else {
        close()
        return false
      }
      do { try progressObserved(scope, sequence, lastOffered) } catch {
        close()
        return false
      }
      if acknowledged != sequence {
        acknowledged = sequence
        pending.removeAll { $0.sequence <= sequence }
      }
    } else if acknowledged != nil {
      close()
      return false
    }
    return true
  }
}
