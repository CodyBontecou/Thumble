import Foundation
import Testing

@testable import MobileInputCore

private let registryPin = String(repeating: "a", count: 64)
private let registryAuthority = "11111111-1111-1111-1111-111111111111"
private let registryProfile = "aaaaaaaa-0000-0000-0000-000000000001"
private let registryControl = "ce000000-0000-0000-0000-000000000001"
private func registryEndpoint() throws -> TrustedHostEndpoint {
  try TrustedHostEndpoint(
    host: "127.0.0.1", port: 9999, certificatePin: registryPin,
    authorityInstanceID: registryAuthority)
}
private actor RegistryGate {
  private var entered = false
  private var released = false
  private var observers: [CheckedContinuation<Void, Never>] = []
  private var waiter: CheckedContinuation<Void, Never>?
  func wait() async {
    entered = true
    for observer in observers { observer.resume() }
    observers = []
    if !released { await withCheckedContinuation { waiter = $0 } }
  }
  func untilEntered() async {
    if !entered { await withCheckedContinuation { observers.append($0) } }
  }
  func release() {
    released = true
    waiter?.resume()
    waiter = nil
  }
}
private actor RegistryTransport: EditorRPCTransport {
  var calls = 0
  var cancellations = 0
  let exchangeGate: RegistryGate?
  let cancelGate: RegistryGate?
  init(exchange: RegistryGate? = nil, cancel: RegistryGate? = nil) {
    exchangeGate = exchange
    cancelGate = cancel
  }
  func exchange(_ request: EditorRequest) async throws -> EditorAuthenticatedReply {
    calls += 1
    await exchangeGate?.wait()
    throw PhoneEditorError.unavailable
  }
  func cancel() async {
    cancellations += 1
    await cancelGate?.wait()
  }
}
private final class RegistryStore: EditorJournalStorage, @unchecked Sendable {
  private let lock = NSLock()
  private var bytes: Data?
  private let saveGate: RegistryGate?
  private let saveRelease = DispatchSemaphore(value: 0)
  private var armed = false
  private var loadGate: RegistryGate?
  private let loadRelease = DispatchSemaphore(value: 0)
  init(saveGate: RegistryGate? = nil) { self.saveGate = saveGate }
  func arm() { lock.withLock { armed = true } }
  func release() { saveRelease.signal() }
  func armLoad(_ gate: RegistryGate) { lock.withLock { loadGate = gate } }
  func releaseLoad() { loadRelease.signal() }
  func load() -> Data? {
    let gate = lock.withLock {
      let gate = loadGate
      loadGate = nil
      return gate
    }
    if let gate {
      Task { await gate.wait() }
      _ = loadRelease.wait(timeout: .now() + 5)
    }
    return lock.withLock { bytes }
  }
  func save(_ candidate: Data, replacing expected: Data?) throws {
    let block = lock.withLock {
      let value = armed
      armed = false
      return value
    }
    if block, let saveGate {
      Task { await saveGate.wait() }
      guard saveRelease.wait(timeout: .now() + 5) == .success else {
        throw PhoneEditorError.unavailable
      }
    }
    try lock.withLock {
      guard bytes == expected else { throw EditorJournalError.changedOnDisk }
      bytes = candidate
    }
  }
}
private func seededRegistryStore(saveGate: RegistryGate? = nil) throws -> RegistryStore {
  let store = RegistryStore(saveGate: saveGate)
  let journal = try EditorJournal(certificateSHA256: registryPin, storage: store)
  try journal.accept(
    VerifiedEditorRead(
      profile: EditorCachedProfile(
        scope: EditorHostScope(
          certificateSHA256: registryPin, authorityInstanceID: registryAuthority),
        id: registryProfile, name: "Controller", revision: "7",
        sourceSHA256: String(repeating: "b", count: 64),
        controls: [
          EditorCachedControl(id: registryControl, generatedLabel: "Jump", labelOverride: nil)
        ])))
  return store
}
private func registrySession(
  _ store: RegistryStore, transport: RegistryTransport = RegistryTransport()
) throws -> PhoneEditorSession {
  let endpoint = try registryEndpoint()
  return PhoneEditorSession(
    endpoint: endpoint, transport: transport,
    openJournal: { try EditorJournal(certificateSHA256: registryPin, storage: store) },
    resolve: { endpoint })
}
@MainActor struct PhoneEditorRegistryTests {
  @Test func invalidationDuringAsyncCreationReservesThenClosesTheActualCandidate() async throws {
    let registry = PhoneEditorRegistry()
    let old = PhoneEditorModuleLifetime()
    let fresh = PhoneEditorModuleLifetime()
    let gate = RegistryGate()
    let store = try seededRegistryStore()
    let candidate = try registrySession(store)
    let pending = Task {
      try await registry.open(owner: old) {
        await gate.wait()
        return candidate
      }
    }
    await gate.untilEntered()
    old.invalidate()
    await registry.invalidate(owner: old)
    await #expect(throws: (any Error).self) {
      try await registry.open(owner: fresh) { try registrySession(store) }
    }
    await gate.release()
    await #expect(throws: (any Error).self) { try await pending.value }
    #expect(await candidate.reusable)
    let handle = try await registry.open(owner: fresh) { try registrySession(store) }
    await registry.invalidate(owner: old)  // Late old teardown cannot close the replacement.
    _ = try await registry.session(owner: fresh, handle: handle).snapshot()
    #expect(throws: (any Error).self) { try registry.session(owner: old, handle: handle) }
    try await registry.close(owner: fresh, handle: handle)
    await registry.invalidate(owner: fresh)
  }
  @Test func invalidationDuringInitialSnapshotClosesProvisionalSessionBeforeReuse() async throws {
    let registry = PhoneEditorRegistry()
    let old = PhoneEditorModuleLifetime()
    let fresh = PhoneEditorModuleLifetime()
    let gate = RegistryGate()
    let store = try seededRegistryStore()
    store.armLoad(gate)
    let candidate = try registrySession(store)
    let pending = Task { try await registry.open(owner: old) { candidate } }
    await gate.untilEntered()
    old.invalidate()
    let teardown = Task { await registry.invalidate(owner: old) }
    await #expect(throws: (any Error).self) {
      try await registry.open(owner: fresh) { try registrySession(store) }
    }
    store.releaseLoad()
    await gate.release()
    await #expect(throws: (any Error).self) { try await pending.value }
    await teardown.value
    #expect(await candidate.reusable)
    let id = try await registry.open(owner: fresh) { try registrySession(store) }
    try await registry.close(owner: fresh, handle: id)
  }
  @Test func cancelledOpenRetiresReturnedCandidateWithoutExposingHandle() async throws {
    let registry = PhoneEditorRegistry()
    let old = PhoneEditorModuleLifetime()
    let fresh = PhoneEditorModuleLifetime()
    let gate = RegistryGate()
    let store = try seededRegistryStore()
    let candidate = try registrySession(store)
    let pending = Task {
      try await registry.open(owner: old) {
        await gate.wait()
        return candidate
      }
    }
    await gate.untilEntered()
    pending.cancel()
    await #expect(throws: (any Error).self) {
      try await registry.open(owner: fresh) { try registrySession(store) }
    }
    await gate.release()
    await #expect(throws: CancellationError.self) { try await pending.value }
    #expect(await candidate.reusable)
    let id = try await registry.open(owner: fresh) { try registrySession(store) }
    try await registry.close(owner: fresh, handle: id)
  }
  @Test func failedSnapshotRetiresWithoutResettingJournalAndAllowsFreshOwner() async throws {
    let registry = PhoneEditorRegistry()
    let owner = PhoneEditorModuleLifetime()
    let transport = RegistryTransport()
    let candidate = PhoneEditorSession(
      endpoint: try registryEndpoint(), transport: transport,
      openJournal: { throw EditorJournalError.changedOnDisk }, resolve: { try registryEndpoint() })
    await #expect(throws: (any Error).self) { try await registry.open(owner: owner) { candidate } }
    #expect(await candidate.reusable)
    let store = try seededRegistryStore()
    let handle = try await registry.open(owner: owner) { try registrySession(store) }
    #expect(try await registry.session(owner: owner, handle: handle).snapshot().profiles.count == 1)
    try await registry.close(owner: owner, handle: handle)
  }
  @Test func closeReturnedAndActualRPCDrainBothGateReplacement() async throws {
    let registry = PhoneEditorRegistry()
    let old = PhoneEditorModuleLifetime()
    let fresh = PhoneEditorModuleLifetime()
    let exchange = RegistryGate()
    let cancel = RegistryGate()
    let store = try seededRegistryStore()
    let transport = RegistryTransport(exchange: exchange, cancel: cancel)
    let candidate = try registrySession(store, transport: transport)
    let id = try await registry.open(owner: old) { candidate }
    let rpc = Task {
      try await candidate.read(
        profileID: registryProfile, expectedRevision: "7",
        sourceSHA256: String(repeating: "b", count: 64))
    }
    await exchange.untilEntered()
    let closing = Task { try await registry.close(owner: old, handle: id) }
    await cancel.untilEntered()
    let teardown = Task { await registry.invalidate(owner: old) }
    await #expect(throws: (any Error).self) {
      try await registry.open(owner: fresh) { try registrySession(store) }
    }
    await cancel.release()
    try await closing.value
    await teardown.value
    #expect(!(await candidate.reusable))
    await #expect(throws: (any Error).self) {
      try await registry.open(owner: fresh) { try registrySession(store) }
    }
    await exchange.release()
    _ = try? await rpc.value
    let next = try await registry.open(owner: fresh) { try registrySession(store) }
    #expect(await transport.cancellations == 1)
    await registry.invalidate(owner: old)
    _ = try registry.session(owner: fresh, handle: next)
    try await registry.close(owner: fresh, handle: next)
  }
  @Test func localDurableMutationRetainsOriginalIntentUntilTeardownDrains() async throws {
    let registry = PhoneEditorRegistry()
    let old = PhoneEditorModuleLifetime()
    let fresh = PhoneEditorModuleLifetime()
    let saved = RegistryGate()
    let store = try seededRegistryStore(saveGate: saved)
    let candidate = try registrySession(store)
    _ = try await registry.open(owner: old) { candidate }
    let summary = try #require(try await candidate.snapshot().profiles.first)
    store.arm()
    let mutation = Task {
      try await candidate.enqueue(
        contextID: summary.contextID, expectedRevision: summary.revision,
        sourceSHA256: summary.sourceSHA256, controlID: registryControl,
        operationID: "original-local-edit", label: "Leap")
    }
    await saved.untilEntered()
    old.invalidate()
    let closing = Task { await registry.invalidate(owner: old) }
    await #expect(throws: (any Error).self) {
      try await registry.open(owner: fresh) { try registrySession(store) }
    }
    store.release()
    await saved.release()
    try await mutation.value
    await closing.value
    let next = try await registry.open(owner: fresh) { try registrySession(store) }
    let snapshot = try await registry.session(owner: fresh, handle: next).snapshot()
    #expect(snapshot.entries.map(\.intent.operationID) == ["original-local-edit"])
    try await registry.close(owner: fresh, handle: next)
  }
}
