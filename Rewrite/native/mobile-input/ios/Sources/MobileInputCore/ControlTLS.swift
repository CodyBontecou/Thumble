import CryptoKit
import Foundation
import Network
import Security

public enum ControlTLSError: Error { case rejected }
public struct ControlTLSFrame: Sendable {
  public enum Kind: UInt8, Sendable {
    case control = 1
    case input = 2
  }
  public let kind: Kind
  public let payload: Data
  public init(kind: Kind, payload: Data) throws {
    guard
      (kind == .control && (1...65_536).contains(payload.count))
        || (kind == .input && payload.count == 108)
    else { throw ControlTLSError.rejected }
    self.kind = kind
    self.payload = payload
  }
  // Routing only: native packet authentication remains the receiver's responsibility.
  var startsInputGrant: Bool {
    kind == .input && payload.prefix(8) == Data([84, 72, 73, 49, 0, 0, 0, 0])
      && payload.dropFirst(32).prefix(8).allSatisfy { $0 == 0 }
  }
  public func encoded() -> Data {
    let length = UInt32(payload.count + 1)
    var result = Data((0..<4).reversed().map { UInt8(truncatingIfNeeded: length >> ($0 * 8)) })
    result.append(kind.rawValue)
    result.append(payload)
    return result
  }
  public static func bodyLength(_ prefix: Data) throws -> Int {
    guard prefix.count == 4 else { throw ControlTLSError.rejected }
    let total = prefix.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    guard (2...65_537).contains(total) else { throw ControlTLSError.rejected }
    return Int(total)
  }
  public static func decodeBody(_ body: Data) throws -> Self {
    guard let byte = body.first, let kind = Kind(rawValue: byte) else {
      throw ControlTLSError.rejected
    }
    return try Self(kind: kind, payload: Data(body.dropFirst()))
  }
}

/// Fixed diagnostic metadata only; never includes endpoint, certificate or error text.
public enum ControlTLSConnectOutcome: String, Sendable {
  case idle, connecting, deadline
  case networkFailed = "network-failed"
  case cancelled
  case versionRejected = "tls-version-rejected"
  case alpnRejected = "alpn-rejected"
  case ready
}
struct ControlTLSConnectDiagnostic {
  private(set) var outcome: ControlTLSConnectOutcome = .idle
  mutating func begin() { if outcome == .idle { outcome = .connecting } }
  mutating func finish(_ next: ControlTLSConnectOutcome) {
    guard outcome == .idle || outcome == .connecting else { return }
    guard next != .idle && next != .connecting else { return }
    outcome = next
  }
}

/// Native TLS transport only. A ready connection is not phone trust or input authorization.
/// UI-thread sampling remains independent of React; Network.framework performs the socket I/O.
/// Fixed diagnostic outcomes only; no network error text, endpoint or packet is exposed.
public enum ControlTLSRuntimeOutcome: String, Sendable {
  case idle, ready, closed, cancelled
  case readDeadline = "read-deadline"
  case writeDeadline = "write-deadline"
  case readFailed = "read-failed"
  case writeFailed = "write-failed"
  case invalidFrame = "invalid-frame"
  case queueOverflow = "queue-overflow"
  case networkFailed = "network-failed"
}
@MainActor public final class ControlTLSClient {
  public private(set) var diagnosticRuntimeOutcome: ControlTLSRuntimeOutcome = .idle
  private func fail(_ outcome: ControlTLSRuntimeOutcome) {
    guard state != .closed else { return }
    diagnosticRuntimeOutcome = outcome
    close()
  }

  public static let serverName = "thumble-rewrite.local"
  public static let alpn = "thumble-rewrite-control/1"
  private enum State { case idle, connecting, ready, closed }
  private var state: State = .idle
  private var connectDiagnostic = ControlTLSConnectDiagnostic()
  public var diagnosticConnectOutcome: ControlTLSConnectOutcome { connectDiagnostic.outcome }
  private let connection: NWConnection
  private let networkQueue = DispatchQueue(label: "com.thumble.rewrite.control-tls")
  private var opening: CheckedContinuation<Void, any Error>?
  private var reading: CheckedContinuation<ControlTLSFrame, any Error>?
  private var connectDeadline: Task<Void, Never>?
  private var readDeadline: Task<Void, Never>?
  private var writeDeadline: Task<Void, Never>?
  private var writing = false
  private let inputWrites = NativeInputWriteQueue()

  public init(host: String, port: UInt16, certificatePin: String) throws {
    guard !host.isEmpty, host.utf8.count <= 253, !host.contains("\0"), port != 0,
      certificatePin.utf8.count == 64,
      certificatePin.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      let endpointPort = NWEndpoint.Port(rawValue: port)
    else { throw ControlTLSError.rejected }
    let tls = NWProtocolTLS.Options()
    let options = tls.securityProtocolOptions
    sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
    sec_protocol_options_set_max_tls_protocol_version(options, .TLSv13)
    sec_protocol_options_set_tls_server_name(options, Self.serverName)
    sec_protocol_options_add_tls_application_protocol(options, Self.alpn)
    sec_protocol_options_set_peer_authentication_required(options, true)
    sec_protocol_options_set_tls_resumption_enabled(options, false)
    sec_protocol_options_set_tls_tickets_enabled(options, false)
    sec_protocol_options_set_tls_false_start_enabled(options, false)
    sec_protocol_options_set_verify_block(
      options,
      { @Sendable _, peer, complete in
        let trust = sec_trust_copy_ref(peer).takeRetainedValue()
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
          chain.count == 1,
          let leaf = chain.first
        else {
          complete(false)
          return
        }
        let der = SecCertificateCopyData(leaf) as Data
        guard der.count <= 16_384,
          SHA256.hash(data: der).map({ String(format: "%02x", $0) }).joined() == certificatePin,
          SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, "thumble-rewrite.local" as CFString))
            == errSecSuccess,
          SecTrustSetAnchorCertificates(trust, [leaf] as CFArray) == errSecSuccess,
          SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
          SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess
        else {
          complete(false)
          return
        }
        complete(SecTrustEvaluateWithError(trust, nil))
      }, networkQueue)
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    connection = NWConnection(
      host: NWEndpoint.Host(host), port: endpointPort, using: NWParameters(tls: tls, tcp: tcp))
  }
  deinit { connection.cancel() }

  public func connect() async throws {
    guard state == .idle else { throw ControlTLSError.rejected }
    state = .connecting
    connectDiagnostic.begin()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        opening = continuation
        connection.stateUpdateHandler = { [weak self] state in
          Task { @MainActor [weak self] in self?.changed(state) }
        }
        connectDeadline = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(3)) } catch { return }
          self?.connectDiagnostic.finish(.deadline)
          self?.close()
        }
        connection.start(queue: networkQueue)
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.close() }
    }
  }
  private func changed(_ update: NWConnection.State) {
    guard state != .closed else { return }
    switch update {
    case .ready:
      guard state == .connecting,
        let metadata = connection.metadata(definition: NWProtocolTLS.definition)
          as? NWProtocolTLS.Metadata,
        sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata.securityProtocolMetadata)
          == .TLSv13
      else {
        connectDiagnostic.finish(.versionRejected)
        close()
        return
      }
      guard Self.negotiatedALPN(metadata.securityProtocolMetadata) == Self.alpn else {
        connectDiagnostic.finish(.alpnRejected)
        close()
        return
      }
      connectDiagnostic.finish(.ready)
      state = .ready
      diagnosticRuntimeOutcome = .ready
      connectDeadline?.cancel()
      connectDeadline = nil
      let continuation = opening
      opening = nil
      continuation?.resume()
    case .failed:
      connectDiagnostic.finish(.networkFailed)
      fail(.networkFailed)
    case .cancelled:
      connectDiagnostic.finish(.cancelled)
      fail(.cancelled)
    default: break
    }
  }
  private static func negotiatedALPN(_ metadata: sec_protocol_metadata_t) -> String? {
    if #available(iOS 18.5, macOS 15.5, *) {
      guard let value = sec_protocol_metadata_copy_negotiated_protocol(metadata) else { return nil }
      defer { free(UnsafeMutableRawPointer(mutating: value)) }
      return String(cString: value)
    }
    return sec_protocol_metadata_get_negotiated_protocol(metadata).map { String(cString: $0) }
  }
  /// Generic transports retain one latest input; admitted v5+ owners opt into bounded credits.
  public func offer(_ frame: ControlTLSFrame) -> Bool {
    guard state == .ready else { return false }
    do { try inputWrites.offer(frame) } catch {
      fail(.queueOverflow)
      return false
    }
    drain()
    return state == .ready
  }
  func enableInputCredits(now: @escaping () -> ContinuousClock.Instant) throws {
    try inputWrites.enable(now: now)
  }
  func inputProgress(scope: Data, sequence: UInt64, highestOffered: UInt64) throws {
    try inputWrites.acknowledge(scope: scope, sequence: sequence, highestOffered: highestOffered)
  }
  func completeInputControl() throws {
    try inputWrites.completeControl()
    drain()
  }
  func validatedInputRenewalReply() throws { try inputWrites.validatedRenewalReply() }
  private func drain() {
    guard state == .ready, !writing else { return }
    let frame: ControlTLSFrame
    do {
      guard let next = try inputWrites.next() else { return }
      frame = next
    } catch {
      fail(.invalidFrame)
      return
    }
    writing = true
    writeDeadline = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(2)) } catch { return }
      self?.fail(.writeDeadline)
    }
    connection.send(
      content: frame.encoded(),
      completion: .contentProcessed { [weak self] error in
        Task { @MainActor [weak self] in
          guard let self, self.state == .ready else { return }
          self.writeDeadline?.cancel()
          self.writeDeadline = nil
          self.writing = false
          if error != nil { self.fail(.writeFailed) } else { self.drain() }
        }
      })
  }
  /// One native reader; control payload interpretation and phone enrollment belong to a separate owner.
  public func receive() async throws -> ControlTLSFrame {
    guard state == .ready, reading == nil else { throw ControlTLSError.rejected }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        reading = continuation
        readDeadline = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(2)) } catch { return }
          self?.fail(.readDeadline)
        }
        receivePrefix()
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.close() }
    }
  }
  private func receivePrefix() {
    connection.receive(minimumIncompleteLength: 4, maximumLength: 4) {
      [weak self] data, _, complete, error in
      Task { @MainActor [weak self] in
        guard let self, self.state == .ready, self.reading != nil else { return }
        guard error == nil, !complete, let data else {
          self.fail(.readFailed)
          return
        }
        guard let length = try? ControlTLSFrame.bodyLength(data) else {
          self.fail(.invalidFrame)
          return
        }
        self.receiveBody(length)
      }
    }
  }
  private func receiveBody(_ length: Int) {
    connection.receive(minimumIncompleteLength: length, maximumLength: length) {
      [weak self] data, _, _, error in
      Task { @MainActor [weak self] in
        guard let self, self.state == .ready, self.reading != nil else { return }
        guard error == nil, let data, data.count == length else {
          self.fail(.readFailed)
          return
        }
        guard let frame = try? ControlTLSFrame.decodeBody(data) else {
          self.fail(.invalidFrame)
          return
        }
        self.readDeadline?.cancel()
        self.readDeadline = nil
        let continuation = self.reading
        self.reading = nil
        continuation?.resume(returning: frame)
      }
    }
  }
  public func close() {
    guard state != .closed else { return }
    if diagnosticRuntimeOutcome == .idle || diagnosticRuntimeOutcome == .ready {
      diagnosticRuntimeOutcome = .closed
    }
    connectDiagnostic.finish(.cancelled)
    state = .closed
    connection.cancel()
    connection.stateUpdateHandler = nil
    connectDeadline?.cancel()
    readDeadline?.cancel()
    writeDeadline?.cancel()
    connectDeadline = nil
    readDeadline = nil
    writeDeadline = nil
    inputWrites.close()
    writing = false
    let open = opening
    let read = reading
    opening = nil
    reading = nil
    open?.resume(throwing: ControlTLSError.rejected)
    read?.resume(throwing: ControlTLSError.rejected)
  }
}
