import Foundation
import Testing

@testable import MobileInputCore

private actor AuthorityStorage: ControlCredentialSource {
  var loads = 0
  func load(hostPin: String, now: UInt64) -> PhoneCredential? {
    loads += 1
    return nil
  }
}
@MainActor private final class AuthorityIO: EnrollmentFrameIO {
  let payload: Data
  var sent = 0, closed = false, entered = false
  var pauseConnect = false, hang = false
  private var pending: CheckedContinuation<ControlTLSFrame, Error>?
  init(_ text: String) { payload = Data(text.utf8) }
  func connect() async throws {
    entered = true
    if pauseConnect { try await Task.sleep(for: .milliseconds(30)) }
  }
  func offer(_ frame: ControlTLSFrame) -> Bool {
    sent += 1
    return !closed
  }
  func receive() async throws -> ControlTLSFrame {
    if hang { return try await withCheckedThrowingContinuation { pending = $0 } }
    return try ControlTLSFrame(kind: .control, payload: payload)
  }
  func close() {
    closed = true
    pending?.resume(throwing: PhoneAuthorityResolutionError.rejected)
    pending = nil
  }
}
private func authorityHello(_ id: String = "new-owner") -> String {
  """
  {"version":1,"command":"hello","authorityInstanceId":"\(id)","controlVersion":3,"inputVersion":1,"documentVersion":1,"capabilitiesVersion":1,"inputEnabled":false}
  """
}
@MainActor private func oldEndpoint() throws -> TrustedHostEndpoint {
  try TrustedHostEndpoint(
    host: "127.0.0.1", port: 1234, certificatePin: String(repeating: "a", count: 64),
    authorityInstanceID: "old-owner")
}
@Test @MainActor func authorityResolverPreservesPinAndRejectsRestartRace() async throws {
  let old = try oldEndpoint()
  let io = AuthorityIO(authorityHello())
  let resolver = PhoneAuthorityResolver(endpoint: old, io: io)
  let current = try await resolver.resolve()
  #expect(
    current.host == old.host && current.port == old.port
      && current.certificatePin == old.certificatePin)
  #expect(current.authorityInstanceID == "new-owner" && io.sent == 1 && io.closed)
  await #expect(throws: (any Error).self) { try await resolver.resolve() }
  let next = AuthorityIO(authorityHello("yet-another-owner"))
  let storage = AuthorityStorage()
  let client = PhoneControlClient(endpoint: current, io: next, storage: storage, now: { 100 })
  await #expect(throws: (any Error).self) { try await client.authenticate() }
  #expect(await storage.loads == 0)
  #expect(next.sent == 1 && next.closed)
}
@Test @MainActor func authorityResolverStrictMetadataOnly() async throws {
  let good = authorityHello()
  for bad in [
    good.replacingOccurrences(of: "false", with: "true"),
    good.replacingOccurrences(of: "\"controlVersion\":3", with: "\"controlVersion\":9"),
    good.replacingOccurrences(
      of: "\"authorityInstanceId\":\"new-owner\"", with: "\"authorityInstanceId\":null"),
    String(good.dropLast()) + ",\"token\":\"secret\"}",
    String(good.dropLast()) + ",\"version\":1}",
    String(repeating: " ", count: 4097) + good,
  ] {
    let io = AuthorityIO(bad)
    let resolver = PhoneAuthorityResolver(endpoint: try oldEndpoint(), io: io)
    await #expect(throws: (any Error).self) { try await resolver.resolve() }
    #expect(io.closed && io.sent == 1)
  }
}
@Test @MainActor func authorityResolverTimeoutAndLateConnectAreTerminal() async throws {
  let io = AuthorityIO(authorityHello())
  io.hang = true
  let resolver = PhoneAuthorityResolver(
    endpoint: try oldEndpoint(), io: io, timeout: .milliseconds(20))
  await #expect(throws: (any Error).self) { try await resolver.resolve() }
  #expect(io.closed)
  let late = AuthorityIO(authorityHello())
  late.pauseConnect = true
  let canceled = PhoneAuthorityResolver(endpoint: try oldEndpoint(), io: late)
  let task = Task { try await canceled.resolve() }
  while !late.entered { await Task.yield() }
  task.cancel()
  await #expect(throws: (any Error).self) { try await task.value }
  #expect(late.closed && late.sent == 0)
}
