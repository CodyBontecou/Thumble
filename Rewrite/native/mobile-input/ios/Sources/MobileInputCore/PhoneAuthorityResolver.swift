import Foundation

public enum PhoneAuthorityResolutionError: Error { case rejected }

/// One-shot pinned-host metadata query. Resolving an instance never authenticates or grants input.
@MainActor public final class PhoneAuthorityResolver {
  private let endpoint: TrustedHostEndpoint
  private let io: any EnrollmentFrameIO
  private let timeout: Duration
  private var started = false
  private var closed = false
  private var expires: ContinuousClock.Instant?

  public convenience init(endpoint: TrustedHostEndpoint) throws {
    try self.init(
      endpoint: endpoint,
      io: ControlTLSClient(
        host: endpoint.host, port: endpoint.port, certificatePin: endpoint.certificatePin))
  }
  init(endpoint: TrustedHostEndpoint, io: any EnrollmentFrameIO, timeout: Duration = .seconds(3)) {
    self.endpoint = endpoint
    self.io = io
    self.timeout = timeout
  }
  public func close() {
    guard !closed else { return }
    closed = true
    io.close()
  }
  private func checkpoint() throws {
    try Task.checkCancellation()
    guard !closed, expires.map({ ContinuousClock.now < $0 }) ?? true else {
      throw PhoneAuthorityResolutionError.rejected
    }
  }
  public func resolve() async throws -> TrustedHostEndpoint {
    guard !started else { throw PhoneAuthorityResolutionError.rejected }
    started = true
    expires = ContinuousClock.now.advanced(by: timeout)
    let deadline = Task { @MainActor [weak self, timeout] in
      do { try await Task.sleep(for: timeout) } catch { return }
      self?.close()
    }
    defer {
      deadline.cancel()
      close()
    }
    return try await withTaskCancellationHandler {
      try checkpoint()
      try await io.connect()
      try checkpoint()
      let request: [String: Any] = [
        "version": 1, "command": "hello", "controlVersion": 3,
        "inputVersion": 1, "documentVersion": 1, "capabilitiesVersion": 1,
      ]
      guard
        io.offer(
          try ControlTLSFrame(
            kind: .control,
            payload: JSONSerialization.data(withJSONObject: request)))
      else { throw PhoneAuthorityResolutionError.rejected }
      let frame = try await io.receive()
      try checkpoint()
      guard frame.kind == .control, frame.payload.count <= 4096 else {
        throw PhoneAuthorityResolutionError.rejected
      }
      let reply = try EnrollmentJSON.parse(frame.payload)
      guard case .string(let authority)? = reply["authorityInstanceId"],
        EnrollmentInvitation.identity(authority),
        reply == [
          "version": .integer(1), "command": .string("hello"),
          "authorityInstanceId": .string(authority), "controlVersion": .integer(3),
          "inputVersion": .integer(1), "documentVersion": .integer(1),
          "capabilitiesVersion": .integer(1), "inputEnabled": .boolean(false),
        ]
      else { throw PhoneAuthorityResolutionError.rejected }
      try checkpoint()
      return try TrustedHostEndpoint(
        host: endpoint.host, port: endpoint.port,
        certificatePin: endpoint.certificatePin, authorityInstanceID: authority)
    } onCancel: {
      Task { @MainActor in self.close() }
    }
  }
}
