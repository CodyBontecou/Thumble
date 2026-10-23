import Foundation

/// A one-page, dedicated MANAGEMENT connection. It cannot create or access input sessions.
@MainActor public final class SavedControllerClient {
  #if DEBUG
    public enum ReadDiagnostic: String {
      case idle, connecting, hello, credential, authentication, query, decoding, complete
    }
    public private(set) var diagnosticReadStage: ReadDiagnostic = .idle
  #endif
  private let endpoint: TrustedHostEndpoint
  private let io: any EnrollmentFrameIO
  private let storage: any ControlCredentialSource
  private let now: () -> UInt64
  private var started = false, closed = false
  private var last: UInt64 = 0
  private var expires: UInt64?
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
    endpoint: TrustedHostEndpoint, io: any EnrollmentFrameIO, storage: any ControlCredentialSource,
    now: @escaping () -> UInt64
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
    else { throw SavedControllerError.rejected }
    last = time
    return time
  }
  private func send(_ value: [String: Any]) throws {
    try checkpoint()
    guard
      io.offer(
        try ControlTLSFrame(kind: .control, payload: JSONSerialization.data(withJSONObject: value)))
    else { throw SavedControllerError.rejected }
  }
  private func receive() async throws -> [String: EnrollmentJSON.Value] {
    let frame = try await io.receive()
    try checkpoint()
    guard frame.kind == .control, frame.payload.count <= 65536 else {
      throw SavedControllerError.rejected
    }
    return try EnrollmentJSON.parse(frame.payload, allowNull: true)
  }
  public func read(_ request: SavedControllerRequest) async throws -> SavedControllerMap {
    guard !started else { throw SavedControllerError.rejected }
    started = true
    defer { close() }
    return try await withTaskCancellationHandler {
      try checkpoint()
      #if DEBUG
        diagnosticReadStage = .connecting
      #endif
      try await io.connect()
      try checkpoint()
      let hello: [String: Any] = [
        "version": 1, "command": "hello", "controlVersion": 8, "role": "management",
        "inputVersion": 1, "documentVersion": 1, "capabilitiesVersion": 1,
      ]
      #if DEBUG
        diagnosticReadStage = .hello
      #endif
      try send(hello)
      let reply = try await receive()
      guard
        reply == [
          "version": .integer(1), "command": .string("hello"),
          "authorityInstanceId": .string(endpoint.authorityInstanceID),
          "controlVersion": .integer(8), "role": .string("management"), "inputVersion": .integer(1),
          "documentVersion": .integer(1), "capabilitiesVersion": .integer(1),
          "inputEnabled": .boolean(false),
        ]
      else { throw SavedControllerError.rejected }
      #if DEBUG
        diagnosticReadStage = .credential
      #endif
      let credential = try await storage.load(hostPin: endpoint.certificatePin, now: checkpoint())
      try checkpoint()
      #if DEBUG
        diagnosticReadStage = .authentication
      #endif
      guard let credential, credential.metadata.hostPin == endpoint.certificatePin,
        last < credential.metadata.expiresAt,
        io.offer(try credential.authenticationFrame(authority: endpoint.authorityInstanceID))
      else { throw SavedControllerError.rejected }
      let admission = try await receive()
      guard
        Set(admission.keys)
          == Set([
            "version", "command", "authorityInstanceId", "phoneId", "credentialEpoch",
            "connectionId", "expiresAt", "inputSessionAvailable", "inputEnabled", "role",
          ]), admission["version"] == .integer(1), admission["command"] == .string("authenticated"),
        admission["authorityInstanceId"] == .string(endpoint.authorityInstanceID),
        admission["phoneId"] == .string(credential.metadata.phoneID),
        admission["credentialEpoch"] == .string(String(credential.metadata.epoch)),
        admission["inputSessionAvailable"] == .boolean(false),
        admission["inputEnabled"] == .boolean(false), admission["role"] == .string("management"),
        case .string(let connection)? = admission["connectionId"],
        PhoneCatalogClient.hex(connection, count: 32),
        case .integer(let end)? = admission["expiresAt"], end > last,
        let localDeadline = ManagementReadDeadline.admitted(
          hostExpiry: end, credentialExpiry: credential.metadata.expiresAt, now: last)
      else { throw SavedControllerError.rejected }
      expires = localDeadline
      #if DEBUG
        diagnosticReadStage = .query
      #endif
      try send(request.fields(connection: connection))
      let fields = try await receive()
      #if DEBUG
        diagnosticReadStage = .decoding
      #endif
      let result = try SavedControllerWire.decode(
        fields, request: request, authority: endpoint.authorityInstanceID, connection: connection)
      #if DEBUG
        diagnosticReadStage = .complete
      #endif
      return result
    } onCancel: {
      Task { @MainActor [weak self] in self?.close() }
    }
  }
  public func close() {
    if !closed {
      closed = true
      io.close()
    }
  }
}
