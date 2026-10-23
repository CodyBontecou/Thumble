import Foundation
import Testing

@testable import MobileInputCore

private let sessionPin = String(repeating: "a", count: 64)
private let sessionAuthority = "11111111-1111-1111-1111-111111111111"
private let sessionProfile = "aaaaaaaa-0000-0000-0000-000000000001"
private func sessionEndpoint(_ authority: String = sessionAuthority) throws -> TrustedHostEndpoint {
  try TrustedHostEndpoint(
    host: "127.0.0.1", port: 9999, certificatePin: sessionPin, authorityInstanceID: authority)
}
private final class SessionStore: EditorJournalStorage, @unchecked Sendable {
  private let lock = NSLock()
  private var data: Data?
  init(_ data: Data? = nil) { self.data = data }
  func load() -> Data? { lock.withLock { data } }
  func save(_ candidate: Data, replacing expected: Data?) throws {
    try lock.withLock {
      guard data == expected else { throw EditorJournalError.changedOnDisk }
      data = candidate
    }
  }
}
private actor SessionTransport: EditorRPCTransport {
  var count = 0
  func exchange(_ request: EditorRequest) async throws -> EditorAuthenticatedReply {
    count += 1
    throw PhoneEditorError.unavailable
  }
  func cancel() {}
  func calls() -> Int { count }
}
private func sessionStore() throws -> SessionStore {
  let store = SessionStore()
  let journal = try EditorJournal(certificateSHA256: sessionPin, storage: store)
  let controls = try (1...18).map { index in
    try EditorCachedControl(
      id: String(format: "ce000000-0000-0000-0000-%012d", index),
      generatedLabel: "Control \(index)", labelOverride: nil)
  }
  let scope = try EditorHostScope(
    certificateSHA256: sessionPin, authorityInstanceID: sessionAuthority)
  try journal.accept(
    VerifiedEditorRead(
      profile: EditorCachedProfile(
        scope: scope, id: sessionProfile,
        name: "Profile", revision: "7", sourceSHA256: String(repeating: "b", count: 64),
        controls: controls)))
  return store
}
struct PhoneEditorSessionTests {
  @Test func offlineContextPinsBoundedPagesAndDurableQueue() async throws {
    let store = try sessionStore()
    let transport = SessionTransport()
    let endpoint = try sessionEndpoint()
    let session = PhoneEditorSession(
      endpoint: endpoint, transport: transport,
      openJournal: { try EditorJournal(certificateSHA256: sessionPin, storage: store) },
      resolve: { throw PhoneEditorError.unavailable })
    let snapshot = try await session.snapshot()
    #expect(snapshot.profiles.count == 1)
    let summary = try #require(snapshot.profiles.first)
    #expect(summary.controlCount == 18)
    #expect(
      try await session.cachePage(contextID: summary.contextID, offset: 0).controls.count == 8)
    #expect(
      try await session.cachePage(contextID: summary.contextID, offset: 16).controls.count == 2)
    await #expect(throws: (any Error).self) {
      try await session.enqueue(
        contextID: summary.contextID, expectedRevision: "8", sourceSHA256: summary.sourceSHA256,
        controlID: "ce000000-0000-0000-0000-000000000001", operationID: "test-op", label: "New")
    }
    await #expect(throws: (any Error).self) {
      try await session.enqueue(
        contextID: summary.contextID, expectedRevision: "7",
        sourceSHA256: String(repeating: "c", count: 64),
        controlID: "ce000000-0000-0000-0000-000000000001", operationID: "test-op", label: "New")
    }
    try await session.enqueue(
      contextID: summary.contextID, expectedRevision: "7", sourceSHA256: summary.sourceSHA256,
      controlID: "ce000000-0000-0000-0000-000000000001", operationID: "test-op", label: "New")
    let restored = try EditorJournal(certificateSHA256: sessionPin, storage: store)
    #expect(restored.snapshot.entries.count == 1)
    #expect(await transport.calls() == 0)
    try await session.select(contextID: summary.contextID)
    #expect(try await session.snapshot().selection == summary.contextID)
    await session.close()
    await #expect(throws: (any Error).self) { try await session.snapshot() }
  }
  @Test func restoredOriginIsNeverRetargetedAndCorruptionBlocksOpen() async throws {
    let store = try sessionStore()
    let transport = SessionTransport()
    let endpoint = try sessionEndpoint()
    let original = try EditorJournal(certificateSHA256: sessionPin, storage: store)
    try original.enqueue(
      EditorLabelIntent(
        scope: EditorHostScope(
          certificateSHA256: sessionPin, authorityInstanceID: sessionAuthority),
        operationID: "old-op", expectedRevision: "7", profileID: sessionProfile,
        controlID: "ce000000-0000-0000-0000-000000000001", label: nil))
    let changed = try sessionEndpoint("22222222-2222-2222-2222-222222222222")
    let session = PhoneEditorSession(
      endpoint: endpoint, transport: transport,
      openJournal: { try EditorJournal(certificateSHA256: sessionPin, storage: store) },
      resolve: { changed })
    await #expect(throws: PhoneEditorError.originReconciliationRequired) {
      try await session.submit(operationID: "old-op")
    }
    await #expect(throws: PhoneEditorError.originReconciliationRequired) {
      try await session.reconcile(operationID: "old-op")
    }
    #expect(await transport.calls() == 0)
    let corrupt = SessionStore(Data("broken".utf8))
    let blocked = PhoneEditorSession(
      endpoint: endpoint, transport: transport,
      openJournal: { try EditorJournal(certificateSHA256: sessionPin, storage: corrupt) },
      resolve: { endpoint })
    await #expect(throws: (any Error).self) { try await blocked.snapshot() }
    #expect(corrupt.load() == Data("broken".utf8))
  }
}

private actor SessionResolverGate {
  private var releaseContinuation: CheckedContinuation<Void, Never>?
  private var startedContinuation: CheckedContinuation<Void, Never>?
  private var started = false
  func resolve() async throws -> TrustedHostEndpoint {
    started = true
    startedContinuation?.resume()
    startedContinuation = nil
    await withCheckedContinuation { releaseContinuation = $0 }
    return try sessionEndpoint()
  }
  func waitStarted() async {
    if started { return }
    await withCheckedContinuation { startedContinuation = $0 }
  }
  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}
extension PhoneEditorSessionTests {
  @Test func cancellationReservesSessionUntilOldResolutionActuallySettles() async throws {
    let store = try sessionStore()
    let transport = SessionTransport()
    let endpoint = try sessionEndpoint()
    let gate = SessionResolverGate()
    let session = PhoneEditorSession(
      endpoint: endpoint, transport: transport,
      openJournal: { try EditorJournal(certificateSHA256: sessionPin, storage: store) },
      resolve: { try await gate.resolve() })
    let pending = Task {
      try await session.read(
        profileID: sessionProfile, expectedRevision: "7",
        sourceSHA256: String(repeating: "b", count: 64))
    }
    await gate.waitStarted()
    await session.cancel()
    #expect(await session.settled == false)
    await #expect(throws: PhoneEditorError.busy) { try await session.submit(operationID: "new") }
    await session.close()
    #expect(await session.settled == false)
    await gate.release()
    await #expect(throws: (any Error).self) { try await pending.value }
    #expect(await session.settled)
    #expect(await transport.calls() == 0)
  }
  @Test func canceledFacadeFenceCannotBeAdmittedAfterActorHop() async throws {
    let store = try sessionStore()
    let transport = SessionTransport()
    let owner = PhoneEditorCoordinator(
      journal: try EditorJournal(certificateSHA256: sessionPin, storage: store),
      transport: transport)
    await owner.cancel(fence: 1)
    let pin = try EditorReadPin(
      scope: EditorHostScope(certificateSHA256: sessionPin, authorityInstanceID: sessionAuthority),
      revision: "7", sourceHash: String(repeating: "b", count: 64), profileID: sessionProfile)
    await #expect(throws: PhoneEditorError.unavailable) {
      try await owner.readProfile(pin, fence: 1)
    }
    #expect(await transport.calls() == 0)
  }
}

private actor SessionCancelGate: EditorRPCTransport {
  private var cancellations = 0
  private var blocked: [CheckedContinuation<Void, Never>] = []
  private var observer: (Int, CheckedContinuation<Void, Never>)?
  private var requests = 0
  func cancel() async {
    cancellations += 1
    if let (count, continuation) = observer, cancellations >= count {
      observer = nil
      continuation.resume()
    }
    await withCheckedContinuation { blocked.append($0) }
  }
  func exchange(_ request: EditorRequest) throws -> EditorAuthenticatedReply {
    requests += 1
    throw PhoneEditorError.unavailable
  }
  func waitForCancellation(_ count: Int) async {
    if cancellations >= count { return }
    await withCheckedContinuation { observer = (count, $0) }
  }
  func release() {
    let pending = blocked
    blocked = []
    for continuation in pending { continuation.resume() }
  }
  func count() -> Int { requests }
}
extension PhoneEditorSessionTests {
  @Test func delayedIdleCancellationCannotCloseANewGenerationAndCloseMustReturnBeforeReuse()
    async throws
  {
    let store = try sessionStore()
    let transport = SessionCancelGate()
    let endpoint = try sessionEndpoint()
    let session = PhoneEditorSession(
      endpoint: endpoint, transport: transport,
      openJournal: { try EditorJournal(certificateSHA256: sessionPin, storage: store) },
      resolve: { endpoint })
    _ = try await session.snapshot()
    #expect(await session.reusable == false)
    let cancel = Task { await session.cancel() }
    await transport.waitForCancellation(1)
    #expect(await session.settled == false)
    await #expect(throws: PhoneEditorError.busy) {
      try await session.read(
        profileID: sessionProfile, expectedRevision: "7",
        sourceSHA256: String(repeating: "b", count: 64))
    }
    #expect(await transport.count() == 0)
    await transport.release()
    await cancel.value
    #expect(await session.settled)
    await #expect(throws: PhoneEditorError.unavailable) {
      try await session.read(
        profileID: sessionProfile, expectedRevision: "7",
        sourceSHA256: String(repeating: "b", count: 64))
    }
    #expect(await transport.count() == 1)
    let close = Task { await session.close() }
    await transport.waitForCancellation(2)
    #expect(await session.reusable == false)
    #expect(await session.settled == false)
    await transport.release()
    await close.value
    #expect(await session.reusable)
  }
}
