import Foundation

public enum EditorJournalError: Error, Equatable {
  case invalid, full, operationReused, unavailable, changedOnDisk
  /// The operation identity remains available for explicit recovery, never a new blind retry.
  case uncertain(String?)
}
public struct EditorHostScope: Sendable, Equatable {
  public let certificateSHA256: String
  public let authorityInstanceID: String
  public init(certificateSHA256: String, authorityInstanceID: String) throws {
    guard EditorJournalCodec.hash(certificateSHA256) else { throw EditorJournalError.invalid }
    self.certificateSHA256 = certificateSHA256
    self.authorityInstanceID = try EditorJournalCodec.uuid(authorityInstanceID)
  }
}
/// Immutable intent. Large fields live behind immutable storage; copying never redirects a target.
public struct EditorLabelIntent: Sendable, Equatable {
  private final class Storage: Sendable {
    let scope: EditorHostScope
    let operationID, expectedRevision, profileID, controlID: String
    let label: String?
    init(
      _ scope: EditorHostScope, _ operationID: String, _ revision: String, _ profile: String,
      _ control: String, _ label: String?
    ) {
      self.scope = scope
      self.operationID = operationID
      expectedRevision = revision
      profileID = profile
      controlID = control
      self.label = label
    }
  }
  private let storage: Storage
  public var scope: EditorHostScope { storage.scope }
  public var operationID: String { storage.operationID }
  public var expectedRevision: String { storage.expectedRevision }
  public var profileID: String { storage.profileID }
  public var controlID: String { storage.controlID }
  public var label: String? { storage.label }
  public init(
    scope: EditorHostScope, operationID: String, expectedRevision: String, profileID: String,
    controlID: String, label: String?
  ) throws {
    guard EditorJournalCodec.operation(operationID), EditorJournalCodec.counter(expectedRevision),
      label.map(EditorJournalCodec.label) ?? true
    else { throw EditorJournalError.invalid }
    storage = Storage(
      scope, operationID, expectedRevision, try EditorJournalCodec.uuid(profileID),
      try EditorJournalCodec.uuid(controlID), label)
  }
  public static func == (a: Self, b: Self) -> Bool {
    a.scope == b.scope && a.operationID == b.operationID && a.expectedRevision == b.expectedRevision
      && a.profileID == b.profileID && a.controlID == b.controlID && a.label == b.label
  }
}
public struct EditorCachedControl: Sendable, Equatable {
  public let id, generatedLabel: String
  public let labelOverride: String?
  public init(id: String, generatedLabel: String, labelOverride: String?) throws {
    guard EditorJournalCodec.label(generatedLabel),
      labelOverride.map(EditorJournalCodec.label) ?? true
    else { throw EditorJournalError.invalid }
    self.id = try EditorJournalCodec.uuid(id)
    self.generatedLabel = generatedLabel
    self.labelOverride = labelOverride
  }
}
public struct EditorCachedProfile: Sendable, Equatable {
  private final class Storage: Sendable {
    let scope: EditorHostScope
    let id, name, revision, sourceSHA256: String
    let controls: [EditorCachedControl]
    init(
      _ scope: EditorHostScope, _ id: String, _ name: String, _ revision: String, _ hash: String,
      _ controls: [EditorCachedControl]
    ) {
      self.scope = scope
      self.id = id
      self.name = name
      self.revision = revision
      sourceSHA256 = hash
      self.controls = controls
    }
  }
  private let storage: Storage
  public var scope: EditorHostScope { storage.scope }
  public var id: String { storage.id }
  public var name: String { storage.name }
  public var revision: String { storage.revision }
  public var sourceSHA256: String { storage.sourceSHA256 }
  public var controls: [EditorCachedControl] { storage.controls }
  public init(
    scope: EditorHostScope, id: String, name: String, revision: String, sourceSHA256: String,
    controls: [EditorCachedControl]
  ) throws {
    guard name.unicodeScalars.count <= 256, name.utf8.count <= 1024,
      EditorJournalCodec.counter(revision), EditorJournalCodec.hash(sourceSHA256),
      controls.count <= 128, Set(controls.map(\.id)).count == controls.count
    else { throw EditorJournalError.invalid }
    storage = Storage(
      scope, try EditorJournalCodec.uuid(id), name, revision, sourceSHA256, controls)
  }
  public static func == (a: Self, b: Self) -> Bool {
    a.scope == b.scope && a.id == b.id && a.name == b.name && a.revision == b.revision
      && a.sourceSHA256 == b.sourceSHA256 && a.controls == b.controls
  }
}
public enum EditorPendingStatus: Sendable, Equatable {
  case queued, uncertain
  case conflict(String)
  case rejected
}
public struct EditorPendingEntry: Sendable, Equatable {
  public let intent: EditorLabelIntent
  public let status: EditorPendingStatus
}
public struct EditorSelection: Sendable, Equatable {
  public let scope: EditorHostScope
  public let profileID: String
  public init(scope: EditorHostScope, profileID: String) throws {
    self.scope = scope
    self.profileID = try EditorJournalCodec.uuid(profileID)
  }
}
public struct EditorJournalSnapshot: Sendable, Equatable {
  public let certificateSHA256: String
  public let entries: [EditorPendingEntry]
  public let profiles: [EditorCachedProfile]
  public let selection: EditorSelection?
  init(
    pin: String, entries: [EditorPendingEntry] = [], profiles: [EditorCachedProfile] = [],
    selection: EditorSelection? = nil
  ) throws {
    guard EditorJournalCodec.hash(pin), entries.count <= 128, profiles.count <= 8,
      entries.allSatisfy({ $0.intent.scope.certificateSHA256 == pin }),
      profiles.allSatisfy({ $0.scope.certificateSHA256 == pin }),
      Set(entries.map { $0.intent.operationID }).count == entries.count,
      Set(profiles.map { $0.scope.authorityInstanceID + "/" + $0.id }).count == profiles.count,
      selection.map({ selected in
        profiles.contains { $0.scope == selected.scope && $0.id == selected.profileID }
      }) ?? true
    else { throw EditorJournalError.invalid }
    certificateSHA256 = pin
    self.entries = entries
    self.profiles = profiles
    self.selection = selection
  }
}
/// Future role12 client must mint this only AFTER authenticated request/response validation.
/// No public constructor, JSON decoder, Expo method or trust-from-data promise exists here.
struct VerifiedEditorAcknowledgment {
  let intent: EditorLabelIntent
  let responseScope: EditorHostScope
  let sessionID: String
  let receiptOperationID: String
  let resultingRevision: String
  let contentSHA256: String
  let affectedEntities: [String]
  let originRebound: Bool
}
/// Read provenance is likewise a future trusted client responsibility, never a UI assertion.
struct VerifiedEditorRead { let profile: EditorCachedProfile }
public protocol EditorJournalStorage: AnyObject {
  func load() throws -> Data?
  /// Must compare current bytes under its transaction lock. Precommit errors preserve old bytes.
  func save(_ candidate: Data, replacing expected: Data?) throws
}
/// Synchronous native owner. Caller must keep disk work off input delivery/animation paths.
public final class EditorJournal {
  private let gate = NSLock()
  private let store: any EditorJournalStorage
  private var state: EditorJournalSnapshot
  private var persisted: Data?
  private var recovery: Data?
  private var uncertainOperation: String?
  public init(certificateSHA256: String, storage: any EditorJournalStorage) throws {
    store = storage
    let bytes = try storage.load()
    state =
      try bytes.map(EditorJournalCodec.decode) ?? EditorJournalSnapshot(pin: certificateSHA256)
    guard state.certificateSHA256 == certificateSHA256 else { throw EditorJournalError.invalid }
    persisted = bytes
  }
  public var snapshot: EditorJournalSnapshot { gate.withLock { state } }
  public var requiresReopen: Bool { gate.withLock { recovery != nil } }
  public var recoveryOperationID: String? { gate.withLock { uncertainOperation } }
  // Preserve candidate bytes on uncertain IO. A full new instance must validate old/new disk state.
  private func commit(_ candidate: EditorJournalSnapshot, operation: String?) throws {
    guard recovery == nil else { throw EditorJournalError.uncertain(uncertainOperation) }
    let bytes = try EditorJournalCodec.encode(candidate)
    do { try store.save(bytes, replacing: persisted) } catch EditorJournalError.uncertain {
      recovery = bytes
      uncertainOperation = operation
      throw EditorJournalError.uncertain(operation)
    }
    state = candidate
    persisted = bytes
  }
  public func enqueue(_ intent: EditorLabelIntent) throws {
    try gate.withLock {
      guard recovery == nil else { throw EditorJournalError.uncertain(uncertainOperation) }
      guard intent.scope.certificateSHA256 == state.certificateSHA256 else {
        throw EditorJournalError.invalid
      }
      if let existing = state.entries.first(where: { $0.intent.operationID == intent.operationID })
      {
        guard existing.intent == intent else { throw EditorJournalError.operationReused }
        return
      }
      guard state.entries.count < 128 else { throw EditorJournalError.full }
      let next = try EditorJournalSnapshot(
        pin: state.certificateSHA256,
        entries: state.entries + [EditorPendingEntry(intent: intent, status: .queued)],
        profiles: state.profiles, selection: state.selection)
      try commit(next, operation: intent.operationID)
    }
  }
  public func select(_ selection: EditorSelection?) throws {
    try gate.withLock {
      try commit(
        EditorJournalSnapshot(
          pin: state.certificateSHA256, entries: state.entries, profiles: state.profiles,
          selection: selection), operation: nil)
    }
  }
  func accept(_ read: VerifiedEditorRead) throws {
    try gate.withLock {
      let profile = read.profile
      guard profile.scope.certificateSHA256 == state.certificateSHA256 else {
        throw EditorJournalError.invalid
      }
      var profiles = state.profiles
      if let at = profiles.firstIndex(where: { $0.scope == profile.scope && $0.id == profile.id }) {
        let previous = profiles[at]
        guard UInt64(profile.revision)! >= UInt64(previous.revision)!,
          profile.revision != previous.revision || profile == previous
        else { throw EditorJournalError.invalid }
        profiles[at] = profile
      } else {
        guard profiles.count < 8 else { throw EditorJournalError.full }
        profiles.append(profile)
      }
      try commit(
        EditorJournalSnapshot(
          pin: state.certificateSHA256, entries: state.entries, profiles: profiles,
          selection: state.selection), operation: nil)
    }
  }
  func mark(_ operationID: String, status: EditorPendingStatus) throws {
    try gate.withLock {
      if case .conflict(let revision) = status, !EditorJournalCodec.counter(revision) {
        throw EditorJournalError.invalid
      }
      guard let at = state.entries.firstIndex(where: { $0.intent.operationID == operationID })
      else { throw EditorJournalError.invalid }
      var entries = state.entries
      entries[at] = EditorPendingEntry(intent: entries[at].intent, status: status)
      try commit(
        EditorJournalSnapshot(
          pin: state.certificateSHA256, entries: entries, profiles: state.profiles,
          selection: state.selection), operation: operationID)
    }
  }
  func acknowledge(
    _ ack: VerifiedEditorAcknowledgment, currentScope: EditorHostScope, sessionID: String
  ) throws {
    try gate.withLock {
      guard ack.responseScope == currentScope,
        ack.responseScope.certificateSHA256 == state.certificateSHA256,
        !sessionID.isEmpty, sessionID.utf8.count <= 128, ack.sessionID == sessionID,
        ack.originRebound || ack.intent.scope == ack.responseScope,
        ack.receiptOperationID == ack.intent.operationID,
        EditorJournalCodec.counter(ack.resultingRevision),
        EditorJournalCodec.hash(ack.contentSHA256),
        UInt64(ack.intent.expectedRevision)! < UInt64.max,
        UInt64(ack.resultingRevision)! == UInt64(ack.intent.expectedRevision)! + 1,
        ack.affectedEntities == [ack.intent.profileID, ack.intent.controlID],
        let at = state.entries.firstIndex(where: { $0.intent == ack.intent })
      else { throw EditorJournalError.invalid }
      var entries = state.entries
      entries.remove(at: at)
      // An ACK changes only the journal; cached revisions/labels/selection are untouched.
      try commit(
        EditorJournalSnapshot(
          pin: state.certificateSHA256, entries: entries, profiles: state.profiles,
          selection: state.selection), operation: ack.intent.operationID)
    }
  }
}
