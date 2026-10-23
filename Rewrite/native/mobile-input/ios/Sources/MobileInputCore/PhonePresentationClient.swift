import Foundation

/// Dedicated read-only role10 batch. Close after metadata and at most64 requested icons.
/// Polling uses a fresh client; no management failure changes an input session.
@MainActor public final class PhonePresentationClient {
  private let endpoint: TrustedHostEndpoint
  private let io: any EnrollmentFrameIO
  private let storage: any ControlCredentialSource
  private let now: () -> UInt64
  private var started = false, closed = false, busy = false
  private var last: UInt64 = 0
  private var expires: UInt64?
  private var connection: String?
  private var metadata: PhonePresentationMetadata?
  private var requestedIcons: Set<String> = []
  public convenience init(endpoint: TrustedHostEndpoint, storage: PhoneCredentialWorker) throws {
    try self.init(
      endpoint: endpoint,
      io: ControlTLSClient(
        host: endpoint.host, port: endpoint.port, certificatePin: endpoint.certificatePin),
      storage: storage,
      now: {
        let value = Date().timeIntervalSince1970 * 1000
        return value.isFinite && value >= 0 && value < Double(Int64.max)
          ? UInt64(value) : UInt64.max
      })
  }
  init(
    endpoint: TrustedHostEndpoint, io: any EnrollmentFrameIO,
    storage: any ControlCredentialSource, now: @escaping () -> UInt64
  ) {
    self.endpoint = endpoint
    self.io = io
    self.storage = storage
    self.now = now
  }
  @discardableResult private func checkpoint() throws -> UInt64 {
    try Task.checkCancellation()
    let time = now()
    guard !closed, time >= last, time <= UInt64(Int64.max), expires.map({ time < $0 }) ?? true
    else { throw PhonePresentationError.rejected }
    last = time
    return time
  }
  private func send(_ fields: [String: Any]) throws {
    try checkpoint()
    let bytes = try JSONSerialization.data(withJSONObject: fields)
    guard bytes.count <= 2048, io.offer(try ControlTLSFrame(kind: .control, payload: bytes))
    else { throw PhonePresentationError.rejected }
  }
  private func receive(limit: Int) async throws -> [String: EnrollmentJSON.Value] {
    let frame = try await io.receive()
    try checkpoint()
    guard frame.kind == .control, frame.payload.count <= limit else {
      throw PhonePresentationError.rejected
    }
    return try EnrollmentJSON.parse(frame.payload)
  }
  public func read(_ request: PhonePresentationRequest) async throws -> PhonePresentationMetadata {
    guard !started, !busy, !closed else { throw PhonePresentationError.rejected }
    started = true
    busy = true
    defer { busy = false }
    return try await withTaskCancellationHandler {
      do {
        try checkpoint()
        try await io.connect()
        try checkpoint()
        try send([
          "version": 1, "command": "hello", "controlVersion": 10, "role": "management",
          "inputVersion": 1, "documentVersion": 1, "capabilitiesVersion": 1,
        ])
        let hello = try await receive(limit: 4096)
        guard
          hello == [
            "version": .integer(1), "command": .string("hello"),
            "authorityInstanceId": .string(endpoint.authorityInstanceID),
            "controlVersion": .integer(10),
            "role": .string("management"), "inputVersion": .integer(1),
            "documentVersion": .integer(1),
            "capabilitiesVersion": .integer(1), "inputEnabled": .boolean(false),
          ]
        else { throw PhonePresentationError.rejected }
        let credential = try await storage.load(hostPin: endpoint.certificatePin, now: checkpoint())
        try checkpoint()
        guard let credential, credential.metadata.hostPin == endpoint.certificatePin,
          last < credential.metadata.expiresAt,
          io.offer(try credential.authenticationFrame(authority: endpoint.authorityInstanceID))
        else { throw PhonePresentationError.rejected }
        let admission = try await receive(limit: 4096)
        guard
          Set(admission.keys)
            == Set([
              "version", "command", "authorityInstanceId", "phoneId",
              "credentialEpoch", "connectionId", "expiresAt", "inputSessionAvailable",
              "inputEnabled", "role",
            ]),
          admission["version"] == .integer(1), admission["command"] == .string("authenticated"),
          admission["authorityInstanceId"] == .string(endpoint.authorityInstanceID),
          admission["phoneId"] == .string(credential.metadata.phoneID),
          admission["credentialEpoch"] == .string(String(credential.metadata.epoch)),
          admission["inputSessionAvailable"] == .boolean(false),
          admission["inputEnabled"] == .boolean(false),
          admission["role"] == .string("management"),
          case .string(let connection)? = admission["connectionId"],
          PhoneCatalogClient.hex(connection, count: 32),
          case .integer(let end)? = admission["expiresAt"],
          let deadline = ManagementReadDeadline.admitted(
            hostExpiry: end,
            credentialExpiry: credential.metadata.expiresAt, now: last)
        else { throw PhonePresentationError.rejected }
        expires = deadline
        self.connection = connection
        try send(request.fields(connection: connection))
        let result = try PhonePresentationWire.metadata(
          try await receive(limit: 32768), request: request,
          authority: endpoint.authorityInstanceID, connection: connection)
        metadata = result
        return result
      } catch {
        close()
        throw error
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.close() }
    }
  }
  public func icon(_ control: PhonePresentationControl) async throws -> PhonePresentationIcon {
    guard !busy, !closed, let metadata, let connection,
      requestedIcons.count < 64, !requestedIcons.contains(control.id)
    else { throw PhonePresentationError.rejected }
    busy = true
    defer { busy = false }
    return try await withTaskCancellationHandler {
      do {
        try checkpoint()
        let fields = try metadata.iconFields(connection: connection, control: control)
        requestedIcons.insert(control.id)
        try send(fields)
        return try PhonePresentationWire.icon(
          try await receive(limit: 16384), metadata: metadata,
          control: control, authority: endpoint.authorityInstanceID, connection: connection)
      } catch {
        close()
        throw error
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.close() }
    }
  }
  public func close() {
    guard !closed else { return }
    closed = true
    metadata = nil
    connection = nil
    requestedIcons.removeAll()
    io.close()
  }
}
