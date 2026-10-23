import Foundation

/// Produced only by the internal authenticated RPC path, never decoded from React data.
struct EditorAuthenticatedReply: Sendable {
  let scope: EditorHostScope
  let phoneID: String
  let credentialEpoch: UInt64
  let connectionID: String
  let reply: EditorReply
}
protocol EditorRPCTransport: Sendable {
  func exchange(_ request: EditorRequest) async throws -> EditorAuthenticatedReply
  func cancel() async
}
enum EditorDispatchOutcome: Sendable, Equatable {
  case committed, retained
  case conflict(String)
}

/// Preparatory SDK owner. There is deliberately no production transport/UI factory yet.
actor PhoneEditorCoordinator {
  private let journal: EditorJournal
  private let transport: any EditorRPCTransport
  private var active: UInt64?
  private var canceled: UInt64?
  private var next: UInt64 = 0
  init(journal: sending EditorJournal, transport: any EditorRPCTransport) {
    self.journal = journal
    self.transport = transport
  }
  func snapshot() -> EditorJournalSnapshot { journal.snapshot }
  func enqueue(_ intent: EditorLabelIntent) throws { try journal.enqueue(intent) }
  func select(_ selection: EditorSelection?) throws { try journal.select(selection) }
  func cancel() async {
    canceled = active
    await transport.cancel()
  }
  private func begin() throws -> UInt64 {
    guard active == nil else { throw PhoneEditorError.busy }
    guard next < UInt64.max else { throw PhoneEditorError.unavailable }
    next += 1
    active = next
    return next
  }
  private func current(_ token: UInt64) throws {
    try Task.checkCancellation()
    guard active == token, canceled != token else { throw PhoneEditorError.unavailable }
  }
  private func validate(_ result: EditorAuthenticatedReply, scope: EditorHostScope) throws {
    guard result.scope == scope, !result.phoneID.isEmpty, result.phoneID.utf8.count <= 128,
      result.credentialEpoch > 0, EditorWire.hex(result.connectionID, count: 32)
    else { throw PhoneEditorError.rejected }
  }
  func readProfile(_ pin: EditorReadPin) async throws -> EditorCachedProfile {
    let token = try begin()
    defer { if active == token { active = nil } }
    var controls: [EditorCachedControl] = []
    var seen: Set<String> = []
    var offset = 0
    var total: Int?
    var name: String?
    var identity: String?
    for _ in 0..<16 {
      try current(token)
      let result = try await transport.exchange(.profile(pin, offset))
      try current(token)
      try validate(result, scope: pin.scope)
      let authenticatedIdentity = result.phoneID + "/" + String(result.credentialEpoch)
      guard identity == nil || identity == authenticatedIdentity else {
        throw PhoneEditorError.rejected
      }
      identity = authenticatedIdentity
      guard case .profile(let page) = result.reply, page.pin == pin, page.offset == offset,
        total == nil || total == page.total, name == nil || name == page.name
      else { throw PhoneEditorError.rejected }
      total = page.total
      name = page.name
      for control in page.controls {
        guard seen.insert(control.id).inserted else { throw PhoneEditorError.rejected }
        controls.append(control)
      }
      guard controls.count <= 128 else { throw PhoneEditorError.rejected }
      if let next = page.next {
        guard next == controls.count, next > offset else { throw PhoneEditorError.rejected }
        offset = next
      } else {
        guard controls.count == page.total else { throw PhoneEditorError.rejected }
        let profile = try EditorCachedProfile(
          scope: pin.scope, id: pin.profileID, name: page.name, revision: pin.revision,
          sourceSHA256: pin.sourceHash, controls: controls)
        try current(token)
        try journal.accept(VerifiedEditorRead(profile: profile))
        return profile
      }
    }
    throw PhoneEditorError.rejected
  }
  func submit(_ operationID: String, endpointScope: EditorHostScope) async throws
    -> EditorDispatchOutcome
  {
    let token = try begin()
    defer { if active == token { active = nil } }
    let entry = try pending(operationID, endpointScope: endpointScope)
    guard entry.status == .queued else { return .retained }
    // A process kill after any offer must leave the same uncertain intent durably available.
    try journal.mark(operationID, status: .uncertain)
    try current(token)
    let result = try await transport.exchange(.label(entry.intent))
    try current(token)
    try validate(result, scope: entry.intent.scope)
    return try consume(result, intent: entry.intent)
  }
  func reconcile(_ operationID: String, endpointScope: EditorHostScope) async throws
    -> EditorDispatchOutcome
  {
    let token = try begin()
    defer { if active == token { active = nil } }
    let entry = try pending(operationID, endpointScope: endpointScope)
    try current(token)
    let result = try await transport.exchange(.status(entry.intent))
    try current(token)
    try validate(result, scope: entry.intent.scope)
    return try consume(result, intent: entry.intent)
  }
  private func pending(_ operationID: String, endpointScope: EditorHostScope) throws
    -> EditorPendingEntry
  {
    guard
      let entry = journal.snapshot.entries.first(where: { $0.intent.operationID == operationID })
    else { throw PhoneEditorError.rejected }
    guard entry.intent.scope == endpointScope else {
      throw PhoneEditorError.originReconciliationRequired
    }
    return entry
  }
  private func consume(_ result: EditorAuthenticatedReply, intent: EditorLabelIntent) throws
    -> EditorDispatchOutcome
  {
    switch result.reply {
    case .committed(let receipt):
      let ack = VerifiedEditorAcknowledgment(
        intent: intent, responseScope: result.scope, sessionID: result.connectionID,
        receiptOperationID: receipt.operationID, resultingRevision: receipt.revision,
        contentSHA256: receipt.hash, affectedEntities: receipt.entities, originRebound: false)
      try journal.acknowledge(ack, currentScope: result.scope, sessionID: result.connectionID)
      return .committed
    case .conflict(let revision):
      try journal.mark(intent.operationID, status: .conflict(revision))
      return .conflict(revision)
    case .error(let code):
      if code == "editor_operation_reused" {
        try journal.mark(intent.operationID, status: .rejected)
      }
      return .retained
    case .admitted, .pending: return .retained
    case .profile: throw PhoneEditorError.rejected
    }
  }
}
