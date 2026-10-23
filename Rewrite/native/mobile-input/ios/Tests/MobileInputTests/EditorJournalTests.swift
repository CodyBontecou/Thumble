import CryptoKit
import Foundation
import Testing

@testable import MobileInputCore

#if os(macOS)
  import Darwin
#endif

private let editorPin = String(repeating: "a", count: 64)
private let editorAuthority = "11111111-1111-1111-1111-111111111111"
private let editorA = "aaaaaaaa-0000-0000-0000-000000000001"
private let editorB = "bbbbbbbb-0000-0000-0000-000000000002"
private let editorControl = "ce000000-0000-0000-0000-000000000001"
private func editorScope(_ authority: String = editorAuthority) throws -> EditorHostScope {
  try EditorHostScope(certificateSHA256: editorPin, authorityInstanceID: authority)
}
private func editorIntent(
  _ operation: String = "edit-A-1", profile: String = editorA, label: String? = "Move 🦊"
) throws -> EditorLabelIntent {
  try EditorLabelIntent(
    scope: editorScope(), operationID: operation, expectedRevision: "7", profileID: profile,
    controlID: editorControl, label: label)
}
private func editorProfile(_ id: String = editorA, revision: String = "7") throws
  -> EditorCachedProfile
{
  try EditorCachedProfile(
    scope: editorScope(), id: id, name: "Synthetic", revision: revision,
    sourceSHA256: String(repeating: "b", count: 64),
    controls: [
      EditorCachedControl(id: editorControl, generatedLabel: "Movement", labelOverride: nil)
    ])
}
private final class EditorMemoryStore: EditorJournalStorage {
  var bytes: Data?
  var beforeFailure = false, afterFailure = false
  func load() -> Data? { bytes }
  func save(_ candidate: Data, replacing expected: Data?) throws {
    guard bytes == expected else { throw EditorJournalError.changedOnDisk }
    if beforeFailure { throw EditorJournalError.unavailable }
    bytes = candidate
    if afterFailure { throw EditorJournalError.uncertain(nil) }
  }
}
private func editorAck(
  _ intent: EditorLabelIntent, operation: String? = nil, scope: EditorHostScope? = nil,
  session: String = "verified-session", revision: String = "8",
  hash: String = String(repeating: "c", count: 64), entities: [String]? = nil, rebound: Bool = false
) throws -> VerifiedEditorAcknowledgment {
  try VerifiedEditorAcknowledgment(
    intent: intent, responseScope: scope ?? editorScope(), sessionID: session,
    receiptOperationID: operation ?? intent.operationID, resultingRevision: revision,
    contentSHA256: hash, affectedEntities: entities ?? [intent.profileID, intent.controlID],
    originRebound: rebound)
}
private func privateEditorDirectory(_ prefix: String = "thumble-editor-") throws -> URL {
  let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(
    prefix + UUID().uuidString)
  try FileManager.default.createDirectory(
    at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  guard let pointer = realpath(url.path, nil) else { throw EditorJournalError.unavailable }
  defer { free(pointer) }
  return URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
}

private final class EditorThreadResult: @unchecked Sendable {
  private let lock = NSLock()
  private var failure: (any Error)?
  let completed = DispatchSemaphore(value: 0)
  func finish(_ error: (any Error)?) {
    lock.withLock { failure = error }
    completed.signal()
  }
  func check() throws { if let error = lock.withLock({ failure }) { throw error } }
}

struct EditorJournalTests {
  @Test func sharedCanonicalFixtureRoundTripsAndPreservesABA() throws {
    let url = try #require(
      Bundle.module.url(
        forResource: "phone-editor-journal-v1", withExtension: "json", subdirectory: "Fixtures"))
    let fixture = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let text = try #require(fixture["canonicalState"] as? String)
    let bytes = Data(text.utf8)
    let state = try EditorJournalCodec.decode(bytes)
    #expect(try EditorJournalCodec.encode(state) == bytes)
    #expect(
      SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == fixture["stateSHA256"]
        as? String)
    #expect(state.entries.map { $0.intent.profileID } == [editorA, editorB, editorA])
    #expect(state.entries.map { $0.intent.label } == ["Move 🦊", "", nil])
    #expect(state.entries.map(\.status) == [.queued, .uncertain, .conflict("9")])
    #expect(state.selection?.profileID == editorA)
    #expect(MemoryLayout<EditorLabelIntent>.size <= 16)
    #expect(MemoryLayout<EditorCachedProfile>.size <= 16)
    #expect(MemoryLayout<EditorJournalSnapshot>.size <= 128)
  }
  @Test func enqueueIsDurableIdempotentAndSelectionCannotRedirectIntent() throws {
    let store = EditorMemoryStore()
    let journal = try EditorJournal(certificateSHA256: editorPin, storage: store)
    try journal.accept(VerifiedEditorRead(profile: editorProfile()))
    try journal.accept(VerifiedEditorRead(profile: editorProfile(editorB)))
    let a = try editorIntent()
    let b = try editorIntent("edit-B-1", profile: editorB, label: "")
    try journal.enqueue(a)
    try journal.select(EditorSelection(scope: editorScope(), profileID: editorB))
    try journal.enqueue(b)
    try journal.select(EditorSelection(scope: editorScope(), profileID: editorA))
    try journal.enqueue(editorIntent("edit-A-2", label: nil))
    let bytes = store.bytes
    try journal.enqueue(a)
    #expect(store.bytes == bytes)
    #expect(journal.snapshot.entries.map { $0.intent.profileID } == [editorA, editorB, editorA])
    #expect(
      try EditorJournal(certificateSHA256: editorPin, storage: store).snapshot == journal.snapshot)
    #expect(throws: EditorJournalError.operationReused) {
      try journal.enqueue(editorIntent(label: "changed"))
    }
  }
  @Test func exactAcknowledgmentOnlyRetiresItsEntryAndNeverAdvancesCache() throws {
    let store = EditorMemoryStore()
    let journal = try EditorJournal(certificateSHA256: editorPin, storage: store)
    let intent = try editorIntent()
    try journal.accept(VerifiedEditorRead(profile: editorProfile(revision: "20")))
    try journal.enqueue(intent)
    try journal.enqueue(editorIntent("another", profile: editorB))
    let profiles = journal.snapshot.profiles
    for bad in [
      try editorAck(intent, operation: "wrong"), try editorAck(editorIntent(label: "changed")),
      try editorAck(intent, session: "old-session"), try editorAck(intent, revision: "7"),
      try editorAck(intent, revision: "9"), try editorAck(intent, hash: "bad"),
      try editorAck(intent, entities: [editorA]),
    ] {
      #expect(throws: EditorJournalError.invalid) {
        try journal.acknowledge(bad, currentScope: editorScope(), sessionID: "verified-session")
      }
      #expect(journal.snapshot.entries.count == 2)
    }
    let otherAuthority = try editorScope("22222222-2222-2222-2222-222222222222")
    #expect(throws: EditorJournalError.invalid) {
      try journal.acknowledge(
        editorAck(intent, scope: otherAuthority), currentScope: otherAuthority,
        sessionID: "verified-session")
    }
    try journal.acknowledge(
      editorAck(intent), currentScope: editorScope(), sessionID: "verified-session")
    #expect(journal.snapshot.entries.map { $0.intent.operationID } == ["another"])
    #expect(journal.snapshot.profiles == profiles)
    #expect(
      try EditorJournal(certificateSHA256: editorPin, storage: store).snapshot == journal.snapshot)
  }
  @Test func oldAuthorityNeedsExplicitInternalRebindAndCrossHostNeverMatches() throws {
    let store = EditorMemoryStore()
    let journal = try EditorJournal(certificateSHA256: editorPin, storage: store)
    let intent = try editorIntent()
    try journal.enqueue(intent)
    let newScope = try editorScope("22222222-2222-2222-2222-222222222222")
    #expect(throws: EditorJournalError.invalid) {
      try journal.acknowledge(
        editorAck(intent, scope: newScope), currentScope: newScope, sessionID: "verified-session")
    }
    let wrongHost = try EditorHostScope(
      certificateSHA256: String(repeating: "d", count: 64), authorityInstanceID: editorAuthority)
    #expect(throws: EditorJournalError.invalid) {
      try journal.acknowledge(
        editorAck(intent, scope: wrongHost, rebound: true), currentScope: wrongHost,
        sessionID: "verified-session")
    }
    try journal.acknowledge(
      editorAck(intent, scope: newScope, rebound: true), currentScope: newScope,
      sessionID: "verified-session")
    #expect(journal.snapshot.entries.isEmpty)
  }
  @Test func conflictsUncertainAndRejectedOutcomesRemainQueued() throws {
    let store = EditorMemoryStore()
    let journal = try EditorJournal(certificateSHA256: editorPin, storage: store)
    let intent = try editorIntent()
    try journal.enqueue(intent)
    for status in [EditorPendingStatus.conflict("9"), .uncertain, .rejected] {
      try journal.mark(intent.operationID, status: status)
      #expect(journal.snapshot.entries == [EditorPendingEntry(intent: intent, status: status)])
      #expect(
        try EditorJournal(certificateSHA256: editorPin, storage: store).snapshot == journal.snapshot
      )
    }
  }
  @Test func precommitFailuresPreserveDiskAndMemoryForEnqueueAndAck() throws {
    let store = EditorMemoryStore()
    let journal = try EditorJournal(certificateSHA256: editorPin, storage: store)
    let intent = try editorIntent()
    let empty = journal.snapshot
    store.beforeFailure = true
    #expect(throws: EditorJournalError.unavailable) { try journal.enqueue(intent) }
    #expect(store.bytes == nil)
    #expect(journal.snapshot == empty)
    store.beforeFailure = false
    try journal.enqueue(intent)
    let old = store.bytes
    let snapshot = journal.snapshot
    store.beforeFailure = true
    #expect(throws: EditorJournalError.unavailable) {
      try journal.acknowledge(
        editorAck(intent), currentScope: editorScope(), sessionID: "verified-session")
    }
    #expect(store.bytes == old)
    #expect(journal.snapshot == snapshot)
  }
  @Test func postcommitUncertaintyLatchesPreservesIdentityAndReopensWholeState() throws {
    let store = EditorMemoryStore()
    let journal = try EditorJournal(certificateSHA256: editorPin, storage: store)
    let intent = try editorIntent()
    store.afterFailure = true
    #expect(throws: EditorJournalError.uncertain(intent.operationID)) {
      try journal.enqueue(intent)
    }
    #expect(journal.snapshot.entries.isEmpty)
    #expect(journal.requiresReopen)
    #expect(journal.recoveryOperationID == intent.operationID)
    #expect(throws: EditorJournalError.uncertain(intent.operationID)) {
      try journal.enqueue(editorIntent("new-id"))
    }
    store.afterFailure = false
    let reopened = try EditorJournal(certificateSHA256: editorPin, storage: store)
    #expect(reopened.snapshot.entries.map(\.intent) == [intent])
    store.afterFailure = true
    #expect(throws: EditorJournalError.uncertain(intent.operationID)) {
      try reopened.acknowledge(
        editorAck(intent), currentScope: editorScope(), sessionID: "verified-session")
    }
    #expect(reopened.snapshot.entries.count == 1)
    #expect(
      try EditorJournal(certificateSHA256: editorPin, storage: store).snapshot.entries.isEmpty)
  }
  @Test func corruptionUnknownFieldsDuplicateKeysAndDeepGraphsFailClosed() throws {
    let state = try EditorJournalSnapshot(pin: editorPin)
    let valid = try EditorJournalCodec.encode(state)
    for bytes in [
      Data(), Data("{}".utf8), valid + Data(" ".utf8),
      Data(
        "{\"certificateSHA256\":\"\(editorPin)\",\"certificateSHA256\":\"\(editorPin)\",\"entries\":[],\"profiles\":[],\"schemaVersion\":1,\"selection\":null}"
          .utf8), Data(repeating: 91, count: 2000), Data(repeating: 0xFF, count: 1),
      Data(repeating: 32, count: EditorJournalCodec.maximumBytes + 1),
    ] {
      let store = EditorMemoryStore()
      store.bytes = bytes
      #expect(throws: (any Error).self) {
        _ = try EditorJournal(certificateSHA256: editorPin, storage: store)
      }
      #expect(store.bytes == bytes)
    }
    let foreign = EditorMemoryStore()
    foreign.bytes = valid
    #expect(throws: EditorJournalError.invalid) {
      _ = try EditorJournal(certificateSHA256: String(repeating: "d", count: 64), storage: foreign)
    }
  }
  @Test func limitsUnicodeScalarsAndImmutableCopiesStayBounded() throws {
    _ = try EditorCachedProfile(
      scope: editorScope(), id: editorA, name: String(repeating: "🦊", count: 256),
      revision: "18446744073709551615", sourceSHA256: String(repeating: "b", count: 64),
      controls: [])
    #expect(throws: EditorJournalError.invalid) {
      _ = try EditorCachedProfile(
        scope: editorScope(), id: editorA, name: String(repeating: "🦊", count: 257), revision: "1",
        sourceSHA256: String(repeating: "b", count: 64), controls: [])
    }
    _ = try editorIntent(label: String(repeating: "🦊", count: 32))
    #expect(throws: EditorJournalError.invalid) {
      _ = try editorIntent(label: String(repeating: "🦊", count: 33))
    }
    let store = EditorMemoryStore()
    let journal = try EditorJournal(certificateSHA256: editorPin, storage: store)
    for i in 0..<128 { try journal.enqueue(editorIntent("bounded-\(i)")) }
    let old = store.bytes
    #expect(throws: EditorJournalError.full) { try journal.enqueue(editorIntent("overflow")) }
    #expect(store.bytes == old)
    var copied = journal.snapshot.entries
    copied.removeAll()
    #expect(journal.snapshot.entries.count == 128)
  }
  @Test func maximumJournalCodecAndCacheFitConstrainedThread() throws {
    let result = EditorThreadResult()
    let thread = Thread {
      do {
        let scope = try editorScope()
        let controls = try (0..<128).map {
          try EditorCachedControl(
            id: String(format: "ce000000-0000-0000-0000-%012d", $0),
            generatedLabel: String(repeating: "🦊", count: 32),
            labelOverride: String(repeating: "x", count: 128))
        }
        let profiles = try (0..<8).map {
          try EditorCachedProfile(
            scope: scope, id: String(format: "aa000000-0000-0000-0000-%012d", $0),
            name: String(repeating: "🦊", count: 256), revision: "18446744073709551615",
            sourceSHA256: String(repeating: "b", count: 64), controls: controls)
        }
        let entries = try (0..<128).map {
          EditorPendingEntry(
            intent: try editorIntent("maximum-\($0)", label: String(repeating: "🦊", count: 32)),
            status: .uncertain)
        }
        let state = try EditorJournalSnapshot(pin: editorPin, entries: entries, profiles: profiles)
        let encoded = try EditorJournalCodec.encode(state)
        guard try EditorJournalCodec.decode(encoded) == state else {
          throw EditorJournalError.invalid
        }
        let store = EditorMemoryStore()
        store.bytes = encoded
        let journal = try EditorJournal(certificateSHA256: editorPin, storage: store)
        try journal.select(EditorSelection(scope: scope, profileID: profiles[7].id))
        guard journal.snapshot.entries.count == 128, journal.snapshot.profiles.count == 8 else {
          throw EditorJournalError.invalid
        }
        result.finish(nil)
      } catch { result.finish(error) }
    }
    thread.stackSize = 512 * 1024
    thread.start()
    try #require(result.completed.wait(timeout: .now() + 10) == .success)
    try result.check()
  }
  @Test func cacheBoundsAndRevisionPinsRejectStaleOrConflictingReads() throws {
    let store = EditorMemoryStore()
    let journal = try EditorJournal(certificateSHA256: editorPin, storage: store)
    try journal.accept(VerifiedEditorRead(profile: editorProfile(revision: "20")))
    let saved = store.bytes
    #expect(throws: EditorJournalError.invalid) {
      try journal.accept(VerifiedEditorRead(profile: editorProfile(revision: "19")))
    }
    let changed = try EditorCachedProfile(
      scope: editorScope(), id: editorA, name: "changed", revision: "20",
      sourceSHA256: String(repeating: "c", count: 64), controls: [])
    #expect(throws: EditorJournalError.invalid) {
      try journal.accept(VerifiedEditorRead(profile: changed))
    }
    #expect(store.bytes == saved)
    let controls = try (0..<129).map {
      try EditorCachedControl(
        id: String(format: "ce000000-0000-0000-0000-%012d", $0), generatedLabel: "",
        labelOverride: nil)
    }
    #expect(throws: EditorJournalError.invalid) {
      _ = try EditorCachedProfile(
        scope: editorScope(), id: editorA, name: "", revision: "1",
        sourceSHA256: String(repeating: "b", count: 64), controls: controls)
    }
    for i in 1..<8 {
      try journal.accept(
        VerifiedEditorRead(
          profile: editorProfile(String(format: "aa000000-0000-0000-0000-%012d", i))))
    }
    let full = store.bytes
    #expect(throws: EditorJournalError.full) {
      try journal.accept(VerifiedEditorRead(profile: editorProfile(editorB)))
    }
    #expect(store.bytes == full)
    let overflow = try EditorLabelIntent(
      scope: editorScope(), operationID: "max-revision", expectedRevision: "18446744073709551615",
      profileID: editorA, controlID: editorControl, label: nil)
    try journal.enqueue(overflow)
    #expect(throws: EditorJournalError.invalid) {
      try journal.acknowledge(
        editorAck(overflow, revision: "1"), currentScope: editorScope(),
        sessionID: "verified-session")
    }
  }
  @Test func actualPrivateStoreReopensRejectsCorruptionAliasesAndCompetingWriters() throws {
    let directory = try privateEditorDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try EditorJournalFileStore(directory: directory, certificateSHA256: editorPin)
    let one = try EditorJournal(certificateSHA256: editorPin, storage: store)
    let competing = try EditorJournal(
      certificateSHA256: editorPin,
      storage: EditorJournalFileStore(directory: directory, certificateSHA256: editorPin))
    try one.enqueue(editorIntent())
    #expect(throws: EditorJournalError.changedOnDisk) {
      try competing.enqueue(editorIntent("other"))
    }
    #expect(
      try EditorJournal(certificateSHA256: editorPin, storage: store).snapshot == one.snapshot)
    let file = directory.appendingPathComponent(editorPin + ".json")
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    try Data("corrupt".utf8).write(to: file)
    #expect(throws: (any Error).self) {
      _ = try EditorJournal(certificateSHA256: editorPin, storage: store)
    }
    #expect(try Data(contentsOf: file) == Data("corrupt".utf8))
    let alias = directory.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
    #expect(throws: (any Error).self) {
      _ = try EditorJournalFileStore(directory: alias, certificateSHA256: editorPin)
    }
  }
  @Test func actualStoreRejectsHardLinkedAndSymlinkedStateWithoutReplacingIt() throws {
    let directory = try privateEditorDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try EditorJournalFileStore(directory: directory, certificateSHA256: editorPin)
    let journal = try EditorJournal(certificateSHA256: editorPin, storage: store)
    try journal.enqueue(editorIntent())
    let file = directory.appendingPathComponent(editorPin + ".json")
    let stage = directory.appendingPathComponent(editorPin + ".new")
    let bytes = try Data(contentsOf: file)
    try FileManager.default.linkItem(at: file, to: stage)
    #expect(throws: (any Error).self) { _ = try store.load() }
    #expect(try Data(contentsOf: file) == bytes)
    try FileManager.default.removeItem(at: stage)
    let original = directory.appendingPathComponent("owned-original")
    try FileManager.default.moveItem(at: file, to: original)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: original)
    #expect(throws: (any Error).self) { _ = try store.load() }
    #expect(try Data(contentsOf: original) == bytes)
  }
  @Test func actualFileFaultBoundariesPreserveOldOrLatchNewWithoutFalseSuccess() throws {
    let directory = try privateEditorDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let base = try EditorJournalFileStore(directory: directory, certificateSHA256: editorPin)
    let initial = try EditorJournal(certificateSHA256: editorPin, storage: base)
    try initial.enqueue(editorIntent())
    let old = try base.load()
    let before = try EditorJournalFileStore(
      directory: directory, certificateSHA256: editorPin,
      fault: { if $0 == .beforeReplace { throw EditorJournalError.unavailable } })
    let rejected = try EditorJournal(certificateSHA256: editorPin, storage: before)
    #expect(throws: EditorJournalError.unavailable) { try rejected.enqueue(editorIntent("second")) }
    #expect(try base.load() == old)
    #expect(rejected.snapshot.entries.count == 1)
    let after = try EditorJournalFileStore(
      directory: directory, certificateSHA256: editorPin,
      fault: { if $0 == .afterReplace { throw EditorJournalError.unavailable } })
    let uncertain = try EditorJournal(certificateSHA256: editorPin, storage: after)
    #expect(throws: EditorJournalError.uncertain("second")) {
      try uncertain.enqueue(editorIntent("second"))
    }
    #expect(uncertain.requiresReopen)
    #expect(uncertain.snapshot.entries.count == 1)
    #expect(
      try EditorJournal(certificateSHA256: editorPin, storage: base).snapshot.entries.count == 2)
  }
}
