import Foundation

/// Internal frame adapter, constructed only by the explicit editor SDK factory.
/// Existing TLS IO runs on its native Network queue; journal and full DTO decoding stay off UI.
@MainActor final class PhoneEditorRPC: EditorRPCTransport {
  private let endpoint: TrustedHostEndpoint
  private let credentials: any ControlCredentialSource
  private let makeIO: @MainActor () throws -> any EnrollmentFrameIO
  private let now: @Sendable () -> UInt64
  private var active: (any EnrollmentFrameIO)?
  private var serial: UInt64 = 0
  private var canceled: UInt64?
  init(
    endpoint: TrustedHostEndpoint, credentials: any ControlCredentialSource,
    makeIO: @escaping @MainActor () throws -> any EnrollmentFrameIO,
    now: @escaping @Sendable () -> UInt64
  ) {
    self.endpoint = endpoint
    self.credentials = credentials
    self.makeIO = makeIO
    self.now = now
  }
  func cancel() {
    canceled = serial
    active?.close()
  }
  func exchange(_ request: EditorRequest) async throws -> EditorAuthenticatedReply {
    guard active == nil, serial < UInt64.max,
      request.scope.certificateSHA256 == endpoint.certificatePin,
      request.scope.authorityInstanceID == endpoint.authorityInstanceID
    else { throw PhoneEditorError.rejected }
    serial += 1
    let identity = serial
    let io = try makeIO()
    active = io
    defer {
      io.close()
      if identity == serial { active = nil }
    }
    var highwater: UInt64 = 0
    var expires: UInt64?
    func checkpoint() throws -> UInt64 {
      try Task.checkCancellation()
      let time = now()
      guard identity == serial, canceled != identity, active != nil, time >= highwater,
        time <= UInt64(Int64.max),
        expires.map({ time < $0 }) ?? true
      else { throw PhoneEditorError.rejected }
      highwater = time
      return time
    }
    func offer(_ fields: [String: Any]) throws {
      _ = try checkpoint()
      let data = try JSONSerialization.data(withJSONObject: fields)
      guard data.count <= 2048, io.offer(try ControlTLSFrame(kind: .control, payload: data)) else {
        throw PhoneEditorError.rejected
      }
    }
    func receive(_ maximum: Int) async throws -> Data {
      let frame = try await io.receive()
      _ = try checkpoint()
      guard frame.kind == .control, frame.payload.count <= maximum else {
        throw PhoneEditorError.rejected
      }
      return frame.payload
    }
    do {
      return try await withTaskCancellationHandler {
        _ = try checkpoint()
        try await io.connect()
        _ = try checkpoint()
        try offer([
          "version": 1, "command": "hello", "controlVersion": 12, "role": "management",
          "inputVersion": 1, "documentVersion": 1, "capabilitiesVersion": 1,
        ])
        guard
          try EditorWire.parse(await receive(4096)) == [
            "version": .integer(1), "command": .string("hello"),
            "authorityInstanceId": .string(endpoint.authorityInstanceID),
            "controlVersion": .integer(12), "role": .string("management"),
            "inputVersion": .integer(1), "documentVersion": .integer(1),
            "capabilitiesVersion": .integer(1), "inputEnabled": .boolean(false),
            "inputSessionAvailable": .boolean(false),
          ]
        else { throw PhoneEditorError.rejected }
        let credential = try await credentials.load(
          hostPin: endpoint.certificatePin, now: checkpoint())
        _ = try checkpoint()
        guard let credential, credential.metadata.hostPin == endpoint.certificatePin,
          highwater < credential.metadata.expiresAt,
          io.offer(try credential.authenticationFrame(authority: endpoint.authorityInstanceID))
        else { throw PhoneEditorError.rejected }
        let admission = try EditorWire.parse(await receive(4096))
        try EditorWire.keys(
          admission,
          [
            "version", "command", "authorityInstanceId", "phoneId", "credentialEpoch",
            "connectionId",
            "expiresAt", "inputSessionAvailable", "inputEnabled", "role",
          ])
        guard admission["version"] == .integer(1), admission["command"] == .string("authenticated"),
          admission["authorityInstanceId"] == .string(endpoint.authorityInstanceID),
          admission["phoneId"] == .string(credential.metadata.phoneID),
          admission["credentialEpoch"] == .string(String(credential.metadata.epoch)),
          admission["inputSessionAvailable"] == .boolean(false),
          admission["inputEnabled"] == .boolean(false), admission["role"] == .string("management"),
          let connection = admission["connectionId"]?.text, EditorWire.hex(connection, count: 32),
          let end = admission["expiresAt"]?.number, end > 0,
          let deadline = ManagementReadDeadline.admitted(
            hostExpiry: UInt64(end), credentialExpiry: credential.metadata.expiresAt, now: highwater
          )
        else { throw PhoneEditorError.rejected }
        expires = deadline
        try offer(request.fields(connection: connection))
        let bytes = try await receive(16_384)
        let reply = try await Self.decode(bytes, request: request, connection: connection)
        _ = try checkpoint()
        return EditorAuthenticatedReply(
          scope: request.scope, phoneID: credential.metadata.phoneID,
          credentialEpoch: credential.metadata.epoch, connectionID: connection, reply: reply)
      } onCancel: {
        Task { @MainActor [weak self] in if self?.serial == identity { self?.cancel() } }
      }
    } catch let error as PhoneEditorError { throw error } catch is CancellationError {
      throw CancellationError()
    } catch { throw PhoneEditorError.unavailable }
  }
  @concurrent private static func decode(_ bytes: Data, request: EditorRequest, connection: String)
    async throws -> EditorReply
  {
    try EditorWire.reply(bytes, request: request, connection: connection)
  }
}
