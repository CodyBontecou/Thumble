import Foundation
import ThumbleContracts

public enum PhoneControlError: Error { case rejected }
public struct TrustedHostEndpoint: Sendable {
  public let host: String, certificatePin: String, authorityInstanceID: String
  public let port: UInt16
  public init(host: String, port: UInt16, certificatePin: String, authorityInstanceID: String)
    throws
  {
    guard !host.isEmpty, host.utf8.count <= 253, !host.contains("\0"), port > 0,
      PhoneCredential.pin(certificatePin), EnrollmentInvitation.identity(authorityInstanceID)
    else { throw PhoneControlError.rejected }
    self.host = host
    self.port = port
    self.certificatePin = certificatePin
    self.authorityInstanceID = authorityInstanceID
  }
}
public struct PhoneControlMetadata: Sendable, Equatable {
  public let phoneID: String, credentialEpoch: UInt64, connectionID: String, expiresAt: UInt64
  public let inputSessionAvailable: Bool
  public let outputMode: PhoneOutputMode
  public let inputEnabled: Bool
  init(
    phoneID: String, credentialEpoch: UInt64, connectionID: String, expiresAt: UInt64,
    inputSessionAvailable: Bool, outputMode: PhoneOutputMode = .recording,
    inputEnabled: Bool = false
  ) {
    self.phoneID = phoneID
    self.credentialEpoch = credentialEpoch
    self.connectionID = connectionID
    self.expiresAt = expiresAt
    self.inputSessionAvailable = inputSessionAvailable
    self.outputMode = outputMode
    self.inputEnabled = inputEnabled
  }
  func sameScope(as other: Self) -> Bool {
    phoneID == other.phoneID && credentialEpoch == other.credentialEpoch
      && connectionID == other.connectionID && expiresAt == other.expiresAt
      && inputSessionAvailable == other.inputSessionAvailable && outputMode == other.outputMode
  }
}
protocol ControlCredentialSource: Sendable {
  func load(hostPin: String, now: UInt64) async throws -> PhoneCredential?
}
extension PhoneCredentialWorker: ControlCredentialSource {}

/// One pinned native channel. Reconnection requires a fresh client and never restores touches.
/// First failure stage only, retained for the synthetic app witness.
public enum PhoneControlFailureStage: String, Sendable {
  case none, checkpoint, progress, renewal, status, offering
}
@MainActor public final class PhoneControlClient {
  public private(set) var diagnosticFailureStage: PhoneControlFailureStage = .none
  public var diagnosticRuntimeOutcome: ControlTLSRuntimeOutcome {
    (io as? ControlTLSClient)?.diagnosticRuntimeOutcome ?? .idle
  }
  private func fail(_ stage: PhoneControlFailureStage) {
    if diagnosticFailureStage == .none { diagnosticFailureStage = stage }
    close()
  }

  private enum State { case idle, authenticating, authenticated, closed }
  private var state: State = .idle
  private var busy = false
  private var last: UInt64 = 0
  private var deadline: UInt64?
  private var admitted: PhoneControlMetadata?
  private var credentialExpiresAt: UInt64?
  private var inputSessionID: String?
  private var inputUDPPort: UInt16?
  private var inputRenewalDue: ContinuousClock.Instant?
  private var inputContinuousLast: ContinuousClock.Instant?
  private let continuousNow: () -> ContinuousClock.Instant
  private let controlVersion: Int
  private let outputMode: PhoneOutputMode
  private var inputAttempted = false
  private var inputChannel: InputPacketChannel?
  private var inputEngine: InputEngine?
  private var inputDeadline: UInt64?
  private var inputContinuousDeadline: ContinuousClock.Instant?
  private var heartbeat: Task<Void, Never>?
  private var datagram: (any NativeDatagramIO)?
  private var datagramOpening: Task<Void, Never>?
  private var route: NativeInputRoute?
  private let datagramFactory: (String, UInt16) throws -> any NativeDatagramIO
  private let routeNow: () -> UInt64
  private let endpoint: TrustedHostEndpoint
  private let io: any EnrollmentFrameIO
  private let storage: any ControlCredentialSource
  private let now: () -> UInt64
  public convenience init(
    endpoint: TrustedHostEndpoint, storage: PhoneCredentialWorker, inputSessions: Bool = false,
    datagrams: Bool = false, renewals: Bool = false, outputMode: PhoneOutputMode = .recording
  ) throws {
    guard !datagrams || inputSessions, !renewals || datagrams,
      outputMode == .recording || (inputSessions && datagrams && renewals)
    else {
      throw PhoneControlError.rejected
    }
    try self.init(
      endpoint: endpoint,
      io: ControlTLSClient(
        host: endpoint.host, port: endpoint.port, certificatePin: endpoint.certificatePin),
      storage: storage,
      now: {
        let time = Date().timeIntervalSince1970 * 1000
        return time.isFinite && time >= 0 && time < Double(Int64.max) ? UInt64(time) : UInt64.max
      },
      controlVersion: outputMode == .macosHID
        ? 9 : renewals ? 6 : (inputSessions ? (datagrams ? 5 : 4) : 3), outputMode: outputMode)
  }
  init(
    endpoint: TrustedHostEndpoint, io: any EnrollmentFrameIO, storage: any ControlCredentialSource,
    now: @escaping () -> UInt64, controlVersion: Int = 3, outputMode: PhoneOutputMode = .recording,
    datagramFactory: @escaping (String, UInt16) throws -> any NativeDatagramIO = {
      try NativeDatagramClient(host: $0, port: $1)
    }, routeNow: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds / 1_000_000 },
    continuousNow: @escaping () -> ContinuousClock.Instant = { .now }
  ) {
    self.continuousNow = continuousNow
    self.datagramFactory = datagramFactory
    self.routeNow = routeNow
    self.controlVersion = controlVersion
    self.outputMode = outputMode
    self.endpoint = endpoint
    self.io = io
    self.storage = storage
    self.now = now
  }
  @discardableResult private func checkpoint() throws -> UInt64 {
    try Task.checkCancellation()
    let time = now()
    guard state != .closed, time >= last, time <= UInt64(Int64.max),
      deadline.map({ time < $0 }) ?? true, admitted.map({ time < $0.expiresAt }) ?? true
    else { throw PhoneControlError.rejected }
    last = time
    return time
  }
  private func send(_ value: [String: Any]) throws {
    try checkpoint()
    guard
      io.offer(
        try ControlTLSFrame(kind: .control, payload: JSONSerialization.data(withJSONObject: value)))
    else { throw PhoneControlError.rejected }
  }
  private func receive() async throws -> [String: EnrollmentJSON.Value] {
    let frame = try await io.receive()
    try checkpoint()
    guard frame.kind == .control else { throw PhoneControlError.rejected }
    return try EnrollmentJSON.parse(frame.payload, allowNull: controlVersion >= 5)
  }
  public func authenticate() async throws -> PhoneControlMetadata {
    guard (3...6).contains(controlVersion) || controlVersion == 9,
      (controlVersion == 9) == (outputMode == .macosHID), state == .idle, !busy
    else {
      throw PhoneControlError.rejected
    }
    state = .authenticating
    busy = true
    defer { busy = false }
    return try await withTaskCancellationHandler {
      do {
        try checkpoint()
        try await io.connect()
        try checkpoint()
        var request: [String: Any] = [
          "version": 1, "command": "hello", "controlVersion": controlVersion, "inputVersion": 1,
          "documentVersion": 1, "capabilitiesVersion": 1,
        ]
        var expected: [String: EnrollmentJSON.Value] = [
          "version": .integer(1), "command": .string("hello"),
          "authorityInstanceId": .string(endpoint.authorityInstanceID),
          "controlVersion": .integer(UInt64(controlVersion)), "inputVersion": .integer(1),
          "documentVersion": .integer(1), "capabilitiesVersion": .integer(1),
        ]
        if outputMode == .macosHID {
          request["role"] = "physical-input"
          request["requiredOutputBackend"] = "macos-hid"
          expected["role"] = .string("physical-input")
          expected["requiredOutputBackend"] = .string("macos-hid")
        } else {
          expected["inputEnabled"] = .boolean(false)
        }
        try send(request)
        let hello = try await receive()
        guard hello == expected else { throw PhoneControlError.rejected }
        let credential = try await storage.load(hostPin: endpoint.certificatePin, now: checkpoint())
        try checkpoint()
        guard let credential, credential.metadata.hostPin == endpoint.certificatePin,
          last < credential.metadata.expiresAt,
          io.offer(try credential.authenticationFrame(authority: endpoint.authorityInstanceID))
        else { throw PhoneControlError.rejected }
        let values = try await receive()
        let receipt = try decode(values, command: "authenticated", credential: credential.metadata)
        admitted = receipt
        credentialExpiresAt = credential.metadata.expiresAt
        deadline = min(receipt.expiresAt, last + 60_000)
        state = .authenticated
        return receipt
      } catch {
        close()
        throw PhoneControlError.rejected
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.close() }
    }
  }
  private func decode(
    _ value: [String: EnrollmentJSON.Value], command: String,
    credential: PhoneCredentialMetadata? = nil
  ) throws -> PhoneControlMetadata {
    guard
      Set(value.keys)
        == outputMode.fields(
          Set([
            "version", "command", "authorityInstanceId", "phoneId", "credentialEpoch",
            "connectionId",
            "expiresAt", "inputSessionAvailable", "inputEnabled",
          ])),
      value["version"] == .integer(1), value["command"] == .string(command),
      value["authorityInstanceId"] == .string(endpoint.authorityInstanceID),
      value["inputSessionAvailable"] == .boolean(controlVersion >= 4),
      case .string(let phone)? = value["phoneId"], EnrollmentInvitation.identity(phone),
      case .string(let epochText)? = value["credentialEpoch"], let epoch = UInt64(epochText),
      epoch > 0, epoch <= UInt64(Int64.max), String(epoch) == epochText,
      case .string(let connection)? = value["connectionId"], connection.utf8.count == 32,
      connection.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      case .integer(let expires)? = value["expiresAt"], expires > last,
      credential.map({ $0.phoneID == phone && $0.epoch == epoch && expires <= $0.expiresAt })
        ?? true
    else { throw PhoneControlError.rejected }
    let enabled = try outputMode.validate(value)
    let receipt = PhoneControlMetadata(
      phoneID: phone, credentialEpoch: epoch, connectionID: connection, expiresAt: expires,
      inputSessionAvailable: controlVersion >= 4, outputMode: outputMode, inputEnabled: enabled)
    guard admitted.map({ $0.sameScope(as: receipt) }) ?? true else {
      throw PhoneControlError.rejected
    }
    return receipt
  }
  public func status() async throws -> PhoneControlMetadata {
    try await operation(disconnect: false)
  }
  public func disconnect() async throws { _ = try await operation(disconnect: true) }
  private func operation(disconnect: Bool) async throws -> PhoneControlMetadata {
    guard state == .authenticated, !busy, let admitted else { throw PhoneControlError.rejected }
    busy = true
    defer { busy = false }
    return try await withTaskCancellationHandler {
      do {
        try send([
          "version": 1, "command": disconnect ? "disconnect" : "control-status",
          "connectionId": admitted.connectionID,
        ])
        let result = try decode(
          try await receive(), command: disconnect ? "disconnected" : "control-status")
        if disconnect { close() }
        return result
      } catch {
        close()
        throw PhoneControlError.rejected
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.close() }
    }
  }
  /// Bootstrap metadata, prior to any input attempt. No packet grant or bearer escapes.
  public func inputConfiguration() async throws -> PhoneInputConfiguration {
    guard controlVersion >= 4, state == .authenticated, !busy, !inputAttempted,
      let admitted
    else { throw PhoneControlError.rejected }
    busy = true
    defer { busy = false }
    return try await withTaskCancellationHandler {
      do {
        try send([
          "version": 1, "command": "input-configuration", "connectionId": admitted.connectionID,
        ])
        return try PhoneInputConfiguration(
          try await receive(), connection: admitted.connectionID, outputMode: outputMode)
      } catch {
        close()
        throw PhoneControlError.rejected
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.close() }
    }
  }

  /// A single native touch owner for one exact acknowledged configuration. No raw grant escapes.
  public func bindInput(
    _ map: ControlMap, feedback: @escaping (GamepadStateV1) -> Void = { _ in }
  ) async throws -> InputEngine {
    guard controlVersion >= 4, state == .authenticated, !busy, !inputAttempted,
      let admitted
    else { throw PhoneControlError.rejected }
    _ = try map.validated()
    inputAttempted = true
    busy = true
    defer { busy = false }
    return try await withTaskCancellationHandler {
      do {
        try send([
          "version": 1, "command": "input-configuration", "connectionId": admitted.connectionID,
        ])
        try PhoneInputGrant.configuration(
          try await receive(), connection: admitted.connectionID, map: map, outputMode: outputMode)
        let requested = try checkpoint()
        let continuous = continuousNow()
        try send([
          "version": 1, "command": "input-grant", "connectionId": admitted.connectionID,
          "generation": map.generation, "revision": map.revision,
        ])
        let grant = try PhoneInputGrant(
          try await receive(), connection: admitted.connectionID, map: map,
          datagrams: controlVersion >= 5, outputMode: outputMode)
        inputDeadline = min(deadline ?? 0, requested + grant.lifetime)
        inputContinuousDeadline = continuous.advanced(by: .milliseconds(Int64(grant.lifetime)))
        inputContinuousLast = continuous
        inputRenewalDue = continuous.advanced(
          by: .milliseconds(Int64(grant.lifetime - min(grant.lifetime, 25_000))))
        inputSessionID = grant.sessionID
        inputUDPPort = grant.udpPort
        try inputCheckpoint()
        if controlVersion >= 5 {
          if let port = grant.udpPort {
            do {
              let udp = try datagramFactory(endpoint.host, port)
              datagram = udp
              // Neutral/TLS input starts immediately; UDP setup cannot consume
              // the receiver TTL or block admission to the fallback transport.
              datagramOpening = Task { [weak self] in
                do { try await udp.connect() } catch {
                  udp.close()
                  if self?.datagram === udp { self?.datagram = nil }
                }
              }
            } catch {
              datagram?.close()
              datagram = nil
            }
          }
          try inputCheckpoint()
          route = makeRoute()
        }
        inputChannel = try InputPacketChannel(grant: grant.packet, packetLimit: 65_536) {
          [weak self] packet in self?.offerInput(packet) ?? false
        }
        let engine = InputEngine(
          output: { [weak self] sample in
            self?.inputChannel?.submit(sample) ?? false
          }, feedback: feedback)
        engine.onRelease = { [weak self] _ in self?.close() }
        inputEngine = engine
        _ = try engine.activate(map)
        try engine.connect(generation: map.generation)
        guard engine.connected else { throw PhoneControlError.rejected }
        heartbeat = Task { [weak self] in
          while !Task.isCancelled {
            let delay = (self?.controlVersion ?? 0) >= 5 ? 100 : 1000
            do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
            guard let self, self.state != .closed else { return }
            if self.busy { continue }
            var stage = PhoneControlFailureStage.checkpoint
            do {
              try self.inputCheckpoint()
              if self.controlVersion >= 5 {
                if self.renewalDue {
                  stage = .renewal
                  try await self.renewInput(map: map)
                } else {
                  guard let session = self.inputSessionID else { throw PhoneControlError.rejected }
                  stage = .progress
                  try await self.progress(session: session, map: map)
                }
              } else {
                stage = .status
                _ = try await self.status()
              }
            } catch {
              self.fail(stage)
              return
            }
          }
        }
        return engine
      } catch {
        close()
        throw PhoneControlError.rejected
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.close() }
    }
  }
  private func makeRoute(reliable: Bool = false) -> NativeInputRoute {
    NativeInputRoute(
      now: routeNow, udp: { [weak self] in self?.datagram?.offer($0) ?? false },
      tls: { [weak self] packet in
        guard let self, let frame = try? ControlTLSFrame(kind: .input, payload: packet) else {
          return false
        }
        return self.io.offer(frame)
      }, initiallyReliable: reliable)
  }
  private func offerInput(_ packet: Data) -> Bool {
    do {
      try inputCheckpoint()
      if let route { return route.offer(packet) }
      return io.offer(try ControlTLSFrame(kind: .input, payload: packet))
    } catch {
      fail(.offering)
      return false
    }
  }
  private var renewalDue: Bool {
    (controlVersion == 6 || controlVersion == 9)
      && inputRenewalDue.map { continuousNow() >= $0 } == true
      && (credentialExpiresAt ?? 0) > (admitted?.expiresAt ?? UInt64.max)
  }
  private func renewInput(map: ControlMap) async throws {
    guard controlVersion == 6 || controlVersion == 9, !busy, let admitted, let credentialExpiresAt,
      let session = inputSessionID, let port = inputUDPPort, let inputChannel,
      let engine = inputEngine, engine.connected
    else { throw PhoneControlError.rejected }
    busy = true
    defer { busy = false }
    try inputCheckpoint()
    let requested = try checkpoint()
    let continuous = continuousNow()
    try send([
      "version": 1, "command": "input-renew", "connectionId": admitted.connectionID,
      "sessionId": session, "generation": map.generation, "revision": map.revision,
    ])
    let value = try await receive()
    // The old source must remain live after I/O. A late grant cannot revive it.
    try inputCheckpoint()
    guard inputSessionID == session, inputEngine === engine, engine.connected else {
      throw PhoneControlError.rejected
    }
    let renewal = try PhoneInputRenewal(
      value, connection: admitted.connectionID, map: map,
      scope: PhoneInputRenewalScope(
        sessionID: session, udpPort: port,
        authorizationExpiresAt: admitted.expiresAt, credentialExpiresAt: credentialExpiresAt),
      now: last, outputMode: outputMode)
    let grant = renewal.grant
    let successor = try inputChannel.continued(grant: grant.packet) { [weak self] in
      self?.offerInput($0) ?? false
    }
    self.admitted = PhoneControlMetadata(
      phoneID: admitted.phoneID, credentialEpoch: admitted.credentialEpoch,
      connectionID: admitted.connectionID, expiresAt: renewal.authorizationExpiresAt,
      inputSessionAvailable: admitted.inputSessionAvailable, outputMode: outputMode,
      inputEnabled: outputMode == .macosHID)
    deadline = min(renewal.authorizationExpiresAt, requested + 60_000)
    inputDeadline = min(deadline ?? 0, requested + grant.lifetime)
    inputContinuousDeadline = continuous.advanced(by: .milliseconds(Int64(grant.lifetime)))
    inputRenewalDue = continuous.advanced(
      by: .milliseconds(Int64(grant.lifetime - min(grant.lifetime, 25_000))))
    inputSessionID = grant.sessionID
    let reliable = route?.reliable ?? false
    route?.close()
    route = makeRoute(reliable: reliable)
    self.inputChannel = successor
    try inputCheckpoint()
    // Same engine/captures, fresh full-state packet zero through the reliable writer barrier.
    engine.tick()
    guard engine.connected else { throw PhoneControlError.rejected }
    try await requestProgress(session: grant.sessionID, map: map)
    guard route?.acknowledged != nil else { throw PhoneControlError.rejected }
  }
  private func progress(session: String, map: ControlMap) async throws {
    guard !busy else { throw PhoneControlError.rejected }
    busy = true
    defer { busy = false }
    try await requestProgress(session: session, map: map)
  }
  private func requestProgress(session: String, map: ControlMap) async throws {
    guard let admitted, let route else { throw PhoneControlError.rejected }
    try send([
      "version": 1, "command": "input-status", "connectionId": admitted.connectionID,
      "sessionId": session,
    ])
    let value = try await receive()
    try inputCheckpoint()
    let progress = try PhoneInputProgress(
      value, connection: admitted.connectionID, session: session,
      map: map, lastOffered: route.lastOffered, previous: route.acknowledged, outputMode: outputMode
    )
    guard route.observe(progress) else { throw PhoneControlError.rejected }
  }
  private func inputCheckpoint() throws {
    let time = try checkpoint()
    guard let inputDeadline, time < inputDeadline,
      let inputContinuousDeadline
    else { throw PhoneControlError.rejected }
    let continuous = continuousNow()
    guard continuous < inputContinuousDeadline,
      inputContinuousLast.map({ continuous >= $0 }) ?? false
    else { throw PhoneControlError.rejected }
    inputContinuousLast = continuous
  }
  public func close() {
    guard state != .closed else { return }
    state = .closed
    heartbeat?.cancel()
    heartbeat = nil
    route?.close()
    route = nil
    datagramOpening?.cancel()
    datagramOpening = nil
    datagram?.close()
    datagram = nil
    inputChannel?.close()
    inputChannel = nil
    if inputEngine?.connected == true { inputEngine?.retire(.disconnected) }
    inputEngine = nil
    admitted = nil
    credentialExpiresAt = nil
    inputSessionID = nil
    inputUDPPort = nil
    inputRenewalDue = nil
    inputDeadline = nil
    inputContinuousDeadline = nil
    inputContinuousLast = nil
    io.close()
  }
}
