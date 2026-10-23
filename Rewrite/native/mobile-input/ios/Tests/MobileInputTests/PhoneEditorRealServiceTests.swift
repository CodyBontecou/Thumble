import Foundation
import Testing

@testable import MobileInputCore

/// Opt-in synthetic credential witness. No Keychain, phone, pairing UI, or input session.
private struct RealEditorFixture: Decodable {
  let version: Int
  let host: String
  let port: UInt16
  let certificatePin, authorityInstanceId, phoneId: String
  let credentialEpoch, expiresAt: UInt64
  let credential, profileId, revision, sourceHash, controlId: String
}
private actor RealEditorCredentials: ControlCredentialSource {
  let credential: PhoneCredential
  init(_ credential: PhoneCredential) { self.credential = credential }
  func load(hostPin: String, now: UInt64) -> PhoneCredential? {
    guard credential.metadata.hostPin == hostPin, now < credential.metadata.expiresAt else {
      return nil
    }
    return credential
  }
}
private final class RealEditorMemoryStore: EditorJournalStorage, @unchecked Sendable {
  private let lock = NSLock()
  private var bytes: Data?
  func load() -> Data? { lock.withLock { bytes } }
  func save(_ candidate: Data, replacing expected: Data?) throws {
    try lock.withLock {
      guard bytes == expected else { throw EditorJournalError.changedOnDisk }
      bytes = candidate
    }
  }
}
struct PhoneEditorRealServiceTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["THUMBLE_EDITOR_SDK_FIXTURE"] != nil))
  @MainActor func realServiceEditorUsesPinnedTLSAndExactReceipt() async throws {
    let environment = ProcessInfo.processInfo.environment
    let fixturePath = try #require(environment["THUMBLE_EDITOR_SDK_FIXTURE"])
    let summaryPath = try #require(environment["THUMBLE_EDITOR_SDK_SUMMARY"])
    let data = try Data(contentsOf: URL(fileURLWithPath: fixturePath))
    try #require(data.count <= 4096)
    let fixture = try JSONDecoder().decode(RealEditorFixture.self, from: data)
    try #require(fixture.version == 1 && fixture.host == "127.0.0.1" && fixture.revision == "3")
    try #require(
      fixture.credential.utf8.count == 64 && fixture.credential.allSatisfy { $0.isHexDigit })
    var token = Data()
    var index = fixture.credential.startIndex
    while index < fixture.credential.endIndex {
      let end = fixture.credential.index(index, offsetBy: 2)
      guard let value = UInt8(fixture.credential[index..<end], radix: 16) else {
        throw PhoneEditorError.rejected
      }
      token.append(value)
      index = end
    }
    let endpoint = try TrustedHostEndpoint(
      host: fixture.host, port: fixture.port,
      certificatePin: fixture.certificatePin, authorityInstanceID: fixture.authorityInstanceId)
    let credentials = RealEditorCredentials(
      try PhoneCredential(
        hostPin: fixture.certificatePin,
        phoneID: fixture.phoneId, epoch: fixture.credentialEpoch, expiresAt: fixture.expiresAt,
        token: token))
    let rpc = PhoneEditorRPC(
      endpoint: endpoint, credentials: credentials,
      makeIO: {
        try ControlTLSClient(
          host: endpoint.host, port: endpoint.port, certificatePin: endpoint.certificatePin)
      },
      now: { UInt64(Date().timeIntervalSince1970 * 1000) })
    let store = RealEditorMemoryStore()
    let session = PhoneEditorSession(
      endpoint: endpoint, transport: rpc,
      openJournal: {
        try EditorJournal(certificateSHA256: endpoint.certificatePin, storage: store)
      },
      resolve: { try await PhoneAuthorityResolver(endpoint: endpoint).resolve() })
    let before = try await session.read(
      profileID: fixture.profileId, expectedRevision: fixture.revision,
      sourceSHA256: fixture.sourceHash)
    let profile = try #require(before.profiles.first)
    let page = try await session.cachePage(contextID: profile.contextID, offset: 0)
    try #require(page.controls.contains(where: { $0.id == fixture.controlId }))
    let operation = "swift-cross-layer-label"
    try await session.enqueue(
      contextID: profile.contextID, expectedRevision: profile.revision,
      sourceSHA256: profile.sourceSHA256, controlID: fixture.controlId, operationID: operation,
      label: "NativeSDK")
    var outcome = try await session.submit(operationID: operation)
    for _ in 0..<100 where outcome != "committed" {
      try await Task.sleep(for: .milliseconds(25))
      outcome = try await session.reconcile(operationID: operation)
    }
    try #require(outcome == "committed")
    let committed = try await session.snapshot()
    #expect(committed.entries.isEmpty)
    #expect(committed.profiles.first?.revision == "3")
    let intent = try EditorLabelIntent(
      scope: EditorHostScope(
        certificateSHA256: endpoint.certificatePin,
        authorityInstanceID: endpoint.authorityInstanceID), operationID: operation,
      expectedRevision: "3",
      profileID: fixture.profileId, controlID: fixture.controlId, label: "NativeSDK")
    let status = try await rpc.exchange(.status(intent))
    guard case .committed(let receipt) = status.reply else { throw PhoneEditorError.rejected }
    try #require(
      receipt.operationID == operation && receipt.revision == "4"
        && receipt.entities.contains(fixture.controlId))
    // Exact replay cannot create revision five; a fresh pinned read proves current owner state.
    _ = try await rpc.exchange(.label(intent))
    let statusAgain = try await rpc.exchange(.status(intent))
    guard case .committed(let replay) = statusAgain.reply else { throw PhoneEditorError.rejected }
    #expect(replay.revision == "4" && replay.hash == receipt.hash)
    let after = try await session.read(
      profileID: fixture.profileId, expectedRevision: "4", sourceSHA256: receipt.hash)
    let updated = try #require(after.profiles.first)
    let updatedPage = try await session.cachePage(contextID: updated.contextID, offset: 0)
    #expect(
      updatedPage.controls.first(where: { $0.id == fixture.controlId })?.labelOverride
        == "NativeSDK")
    await session.close()
    let summary: [String: Any] = [
      "version": 1, "kind": "swift-editor-sdk", "committed": true,
      "queueEmpty": true, "baseRevision": "3", "resultingRevision": "4",
    ]
    try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]).write(
      to: URL(fileURLWithPath: summaryPath), options: .atomic)
  }
}
