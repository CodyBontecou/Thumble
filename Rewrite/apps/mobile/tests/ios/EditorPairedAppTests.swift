import Foundation
import XCTest

@testable import MobileInputCore

private actor PairedKeychainCleanup {
  func forget(_ pin: String) throws -> Bool {
    let vault = PhoneCredentialVault()
    try vault.forget(hostPin: pin)
    return try vault.load(hostPin: pin, now: UInt64(Date().timeIntervalSince1970 * 1000)) == nil
  }
}

/// Test-host only: executes inside the entitled product app UID. No UI automation or fake providers.
@MainActor final class EditorPairedAppTests: XCTestCase {
  private let descriptorKey = "rewrite.phone.endpoint.v1"
  private func gateway(_ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
    guard ["/fixture", "/enrolled", "/captured", "/verified", "/cleaned"].contains(path),
      let url = Bundle(for: Self.self).url(
        forResource: "EditorPairedAppProbeConfig", withExtension: "json"),
      let config = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Int],
      let port = config["fixturePort"], (1...65535).contains(port),
      let target = URL(string: "http://127.0.0.1:\(port)\(path)")
    else { throw PhoneEditorError.unavailable }
    var request = URLRequest(url: target)
    request.timeoutInterval = 8
    if let body {
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
      guard request.httpBody!.count <= 4096 else { throw PhoneEditorError.rejected }
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 8192,
      let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw PhoneEditorError.unavailable }
    return result
  }
  private func endpoint() throws -> TrustedHostEndpoint {
    guard let row = UserDefaults.standard.dictionary(forKey: descriptorKey),
      Set(row.keys) == Set(["host", "port", "pin", "authority"]),
      let host = row["host"] as? String, let port = row["port"] as? Int,
      let bounded = UInt16(exactly: port), let pin = row["pin"] as? String,
      let authority = row["authority"] as? String
    else { throw PhoneEditorError.unavailable }
    return try TrustedHostEndpoint(
      host: host, port: bounded, certificatePin: pin, authorityInstanceID: authority)
  }
  private func snapshot() async throws -> PhoneEditorSnapshot {
    let session = await PhoneEditorSession(endpoint: try endpoint())
    do {
      let value = try await session.snapshot()
      await session.close()
      guard await session.reusable else { throw PhoneEditorError.busy }
      return value
    } catch {
      await session.close()
      throw error
    }
  }
  private func originalFile() throws -> URL {
    let support = try XCTUnwrap(
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
    let folder = support.appendingPathComponent("PairedEditorWitnessV1", isDirectory: true)
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return folder.appendingPathComponent("original.json")
  }
  private nonisolated static func now() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
  func testEnrollWithProductionSDKAndDefaultKeychain() async throws {
    XCTAssertEqual(Bundle.main.bundleIdentifier, "com.codybontecou.thumble.rewrite")
    XCTAssertNil(UserDefaults.standard.dictionary(forKey: descriptorKey), "paired_target_not_fresh")
    let fixture = try await gateway("/fixture")
    let raw = try XCTUnwrap(fixture["invitation"])
    let invitation = try EnrollmentInvitation.decode(JSONSerialization.data(withJSONObject: raw))
    XCTAssertEqual(invitation.host, "127.0.0.1")
    let worker = PhoneCredentialWorker()
    let client = try PhoneEnrollmentClient(invitation: invitation, storage: worker)
    defer { client.close() }
    let metadata = try await client.enroll(
      phoneID: "paired-ios-ui", label: "Editor paired UI witness")
    let restored = try await worker.load(hostPin: invitation.certificatePin, now: Self.now())
    guard restored?.metadata == metadata else { throw PhoneCredentialError.unconfirmed }
    UserDefaults.standard.set(metadata.phoneID, forKey: "rewrite.phone.id")
    UserDefaults.standard.set(
      [
        "host": invitation.host, "port": Int(invitation.port), "pin": invitation.certificatePin,
        "authority": invitation.authorityInstanceID,
      ], forKey: descriptorKey)
    let current = try await snapshot()
    guard current.entries.isEmpty else { throw PhoneEditorError.rejected }
    _ = try await gateway(
      "/enrolled", body: ["version": 1, "keychainRoundTrip": true, "targetUid": true])
  }
  func testCaptureActualUIIntentAfterProcessRestart() async throws {
    let persisted = try await snapshot()
    guard persisted.entries.count == 1, let entry = persisted.entries.first,
      entry.status == .queued, entry.intent.label == "PairedIOS"
    else { throw PhoneEditorError.rejected }
    let intent = entry.intent
    guard let cached = persisted.profiles.first(where: { $0.profileID == intent.profileID }),
      cached.revision == intent.expectedRevision else { throw PhoneEditorError.rejected }
    let row: [String: Any] = [
      "certificatePin": intent.scope.certificateSHA256,
      "authorityInstanceId": intent.scope.authorityInstanceID, "operationId": intent.operationID,
      "expectedRevision": intent.expectedRevision, "profileId": intent.profileID,
      "controlId": intent.controlID, "label": intent.label!, "sourceHash": cached.sourceSHA256,
    ]
    let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
    guard data.count <= 4096 else { throw PhoneEditorError.rejected }
    let file = try originalFile()
    try data.write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    _ = try await gateway("/captured", body: row)
  }
  func testVerifyExactReceiptAndIdempotentReplayWithDefaultKeychain() async throws {
    let current = try await snapshot()
    guard current.entries.isEmpty else { throw PhoneEditorError.rejected }
    let data = try Data(contentsOf: originalFile())
    guard data.count <= 4096,
      let row = try JSONSerialization.jsonObject(with: data) as? [String: String],
      let pin = row["certificatePin"], let authority = row["authorityInstanceId"],
      let operation = row["operationId"], let revision = row["expectedRevision"],
      let profile = row["profileId"], let control = row["controlId"], let label = row["label"]
    else { throw PhoneEditorError.rejected }
    let intent = try EditorLabelIntent(
      scope: EditorHostScope(certificateSHA256: pin, authorityInstanceID: authority),
      operationID: operation, expectedRevision: revision, profileID: profile, controlID: control,
      label: label)
    let endpoint = try endpoint()
    let cached = await PhoneEditorSession(endpoint: endpoint)
    do {
      let snapshot = try await cached.snapshot()
      guard let summary = snapshot.profiles.first(where: { $0.profileID == profile }),
        summary.revision == "2"
      else { throw PhoneEditorError.rejected }
      var offset = 0
      var refreshed = false
      for _ in 0..<16 {
        let page = try await cached.cachePage(contextID: summary.contextID, offset: offset)
        refreshed =
          refreshed || page.controls.contains { $0.id == control && $0.labelOverride == label }
        guard let next = page.nextOffset else { break }
        offset = next
      }
      await cached.close()
      guard refreshed, await cached.reusable else { throw PhoneEditorError.rejected }
    } catch {
      await cached.close()
      throw error
    }
    let rpc = PhoneEditorRPC(
      endpoint: endpoint, credentials: PhoneCredentialWorker(),
      makeIO: {
        try ControlTLSClient(
          host: endpoint.host, port: endpoint.port, certificatePin: endpoint.certificatePin)
      }, now: Self.now)
    defer { rpc.cancel() }
    guard case .committed(let first) = try await rpc.exchange(.status(intent)).reply,
      case .committed(let duplicate) = try await rpc.exchange(.label(intent)).reply,
      case .committed(let last) = try await rpc.exchange(.status(intent)).reply,
      first.operationID == operation, duplicate.operationID == operation,
      last.operationID == operation,
      first.revision == "2", first.revision == duplicate.revision, first.revision == last.revision,
      first.hash == duplicate.hash, first.hash == last.hash, first.entities == [profile, control],
      duplicate.entities == first.entities, last.entities == first.entities
    else { throw PhoneEditorError.rejected }
    _ = try await gateway(
      "/verified",
      body: [
        "operationId": operation, "revision": first.revision,
        "hash": first.hash, "exactStatus": true, "duplicateCommitted": true, "cacheRefreshed": true,
      ])
  }
  func testCleanupOwnCredentialAndDescriptor() async throws {
    let pin = try endpoint().certificatePin
    let forgotten = try await PairedKeychainCleanup().forget(pin)
    guard forgotten else { throw PhoneCredentialError.unconfirmed }
    UserDefaults.standard.removeObject(forKey: descriptorKey)
    UserDefaults.standard.removeObject(forKey: "rewrite.phone.id")
    try FileManager.default.removeItem(at: originalFile())
    _ = try await gateway("/cleaned", body: ["version": 1, "credentialForgotten": true])
  }
}
