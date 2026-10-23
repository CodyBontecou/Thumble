import Foundation

/// Explicit editor owner. Opening and offline work never create a network connection.
public actor PhoneEditorSession {
  private let endpoint: TrustedHostEndpoint
  private let transport: any EditorRPCTransport
  private let openJournal: @Sendable () throws -> EditorJournal
  private let resolve: @Sendable () async throws -> TrustedHostEndpoint
  private var coordinator: PhoneEditorCoordinator?
  private var catalogClient: PhoneCatalogClient?
  private var contexts: [String: EditorCachedProfile] = [:]
  private var closed = false
  private var closeReturned = false
  private var cancellationsActive = 0
  private var networkActive = false
  private var localActive = 0
  private var generation: UInt64 = 0
  private var cancellation: UInt64 = 0
  public init(endpoint: TrustedHostEndpoint) async {
    self.endpoint = endpoint
    transport = await EditorSessionTransport(endpoint: endpoint)
    openJournal = {
      try EditorJournal(
        certificateSHA256: endpoint.certificatePin,
        storage: EditorJournalFileStore(certificateSHA256: endpoint.certificatePin))
    }
    resolve = { try await PhoneAuthorityResolver(endpoint: endpoint).resolve() }
  }
  init(
    endpoint: TrustedHostEndpoint, transport: any EditorRPCTransport,
    openJournal: @escaping @Sendable () throws -> EditorJournal,
    resolve: @escaping @Sendable () async throws -> TrustedHostEndpoint
  ) {
    self.endpoint = endpoint
    self.transport = transport
    self.openJournal = openJournal
    self.resolve = resolve
  }
  private func owner() throws -> PhoneEditorCoordinator {
    guard !closed else { throw PhoneEditorError.unavailable }
    if let coordinator { return coordinator }
    let value = PhoneEditorCoordinator(journal: try openJournal(), transport: transport)
    coordinator = value
    return value
  }
  private func context(_ id: String) throws -> EditorCachedProfile {
    guard !closed, let profile = contexts[id] else { throw PhoneEditorError.rejected }
    return profile
  }
  private func contextID(_ profile: EditorCachedProfile) -> String {
    if let old = contexts.first(where: { $0.value == profile }) { return old.key }
    let id = UUID().uuidString.lowercased()
    contexts = contexts.filter { $0.value.scope != profile.scope || $0.value.id != profile.id }
    contexts[id] = profile
    return id
  }
  public func snapshot() async throws -> PhoneEditorSnapshot {
    localActive += 1
    defer { localActive -= 1 }
    let snapshot = await (try owner()).snapshot()
    contexts = contexts.filter { snapshot.profiles.contains($0.value) }
    let profiles = snapshot.profiles.map {
      PhoneEditorCacheSummary(contextID: contextID($0), profile: $0)
    }
    let selection = snapshot.selection.flatMap { selected in
      profiles.first {
        $0.profileID == selected.profileID && contexts[$0.contextID]?.scope == selected.scope
      }?.contextID
    }
    return PhoneEditorSnapshot(profiles: profiles, entries: snapshot.entries, selection: selection)
  }
  public func cachePage(contextID: String, offset: Int) throws -> PhoneEditorCachePage {
    let profile = try context(contextID)
    guard offset >= 0, offset <= profile.controls.count, offset % 8 == 0 else {
      throw PhoneEditorError.rejected
    }
    let end = min(offset + 8, profile.controls.count)
    return PhoneEditorCachePage(
      contextID: contextID, offset: offset,
      nextOffset: end < profile.controls.count ? end : nil,
      controls: Array(profile.controls[offset..<end]))
  }
  public func select(contextID: String?) async throws {
    localActive += 1
    defer { localActive -= 1 }
    let selection = try contextID.map { id in
      let profile = try context(id)
      return try EditorSelection(scope: profile.scope, profileID: profile.id)
    }
    try await (try owner()).select(selection)
  }
  public func enqueue(
    contextID: String, expectedRevision: String, sourceSHA256: String,
    controlID: String, operationID: String, label: String?
  ) async throws {
    localActive += 1
    defer { localActive -= 1 }
    let profile = try context(contextID)
    let owner = try owner()
    let latest = await owner.snapshot()
    guard profile.revision == expectedRevision, profile.sourceSHA256 == sourceSHA256,
      latest.profiles.contains(profile), profile.controls.contains(where: { $0.id == controlID })
    else { throw PhoneEditorError.rejected }
    try await owner.enqueueCached(
      profile,
      intent: EditorLabelIntent(
        scope: profile.scope, operationID: operationID,
        expectedRevision: profile.revision, profileID: profile.id, controlID: controlID,
        label: label))
  }
  private func begin() throws -> UInt64 {
    guard !closed else { throw PhoneEditorError.unavailable }
    guard !networkActive, cancellationsActive == 0 else { throw PhoneEditorError.busy }
    guard generation < UInt64.max else { throw PhoneEditorError.unavailable }
    generation += 1
    networkActive = true
    return generation
  }
  private func resolved() async throws -> TrustedHostEndpoint {
    let token = cancellation
    let current = try await resolve()
    guard !closed, token == cancellation, current.host == endpoint.host,
      current.port == endpoint.port,
      current.certificatePin == endpoint.certificatePin
    else { throw PhoneEditorError.rejected }
    return current
  }
  public func read(profileID: String, expectedRevision: String, sourceSHA256: String) async throws
    -> PhoneEditorSnapshot
  {
    let token = try begin()
    defer { networkActive = false }
    let current = try await resolved()
    let scope = try EditorHostScope(
      certificateSHA256: current.certificatePin, authorityInstanceID: current.authorityInstanceID)
    let pin = try EditorReadPin(
      scope: scope, revision: expectedRevision, sourceHash: sourceSHA256, profileID: profileID)
    _ = try await (try owner()).readProfile(pin, fence: token)
    return try await snapshot()
  }
  public func catalog(expectedRevision: String?, offset: Int) async throws -> PhoneCatalogResult {
    _ = try begin()
    defer { networkActive = false }
    let token = cancellation
    let current = try await resolved()
    let client = try await Self.makeCatalog(current)
    catalogClient = client
    defer { catalogClient = nil }
    guard !closed, token == cancellation else {
      await client.close()
      throw PhoneEditorError.unavailable
    }
    let result = try await client.read(expectedRevision: expectedRevision, offset: offset)
    guard !closed, token == cancellation else { throw PhoneEditorError.unavailable }
    return result
  }
  @MainActor private static func makeCatalog(_ endpoint: TrustedHostEndpoint) throws
    -> PhoneCatalogClient
  {
    try PhoneCatalogClient(endpoint: endpoint, storage: PhoneCredentialWorker())
  }
  public func submit(operationID: String) async throws -> String {
    try await dispatch(operationID, reconcile: false)
  }
  public func reconcile(operationID: String) async throws -> String {
    try await dispatch(operationID, reconcile: true)
  }
  private func dispatch(_ id: String, reconcile: Bool) async throws -> String {
    let token = try begin()
    defer { networkActive = false }
    let current = try await resolved()
    let scope = try EditorHostScope(
      certificateSHA256: current.certificatePin, authorityInstanceID: current.authorityInstanceID)
    let owner = try owner()
    let outcome: EditorDispatchOutcome
    if reconcile {
      outcome = try await owner.reconcile(id, endpointScope: scope, fence: token)
    } else {
      outcome = try await owner.submit(id, endpointScope: scope, fence: token)
    }
    switch outcome {
    case .committed: return "committed"
    case .retained: return "retained"
    case .conflict: return "conflict"
    }
  }
  public func cancel() async {
    cancellationsActive += 1
    defer { cancellationsActive -= 1 }
    cancellation &+= 1
    let coordinator = coordinator
    let catalog = catalogClient
    await coordinator?.cancel(fence: generation)
    await catalog?.close()
  }
  public func close() async {
    guard !closed else { return }
    closed = true
    cancellationsActive += 1
    defer { cancellationsActive -= 1 }
    cancellation &+= 1
    let coordinator = coordinator
    let catalog = catalogClient
    await coordinator?.cancel(fence: generation)
    await catalog?.close()
    closeReturned = true
  }
  public var settled: Bool { !networkActive && localActive == 0 && cancellationsActive == 0 }
  /// Reuse requires close completion, not merely observing an idle actor before close enters.
  public var reusable: Bool { closed && closeReturned && settled }

}

public struct PhoneEditorCacheSummary: Sendable {
  public let contextID, profileID, name, revision, sourceSHA256: String
  public let controlCount: Int
  init(contextID: String, profile: EditorCachedProfile) {
    self.contextID = contextID
    profileID = profile.id
    name = profile.name
    revision = profile.revision
    sourceSHA256 = profile.sourceSHA256
    controlCount = profile.controls.count
  }
}
public struct PhoneEditorSnapshot: Sendable {
  public let profiles: [PhoneEditorCacheSummary]
  public let entries: [EditorPendingEntry]
  public let selection: String?
}
public struct PhoneEditorCachePage: Sendable {
  public let contextID: String
  public let offset: Int
  public let nextOffset: Int?
  public let controls: [EditorCachedControl]
}

@MainActor private final class EditorSessionTransport: EditorRPCTransport {
  private let endpoint: TrustedHostEndpoint
  private let credentials = PhoneCredentialWorker()
  private var rpc: PhoneEditorRPC?
  init(endpoint: TrustedHostEndpoint) { self.endpoint = endpoint }
  func cancel() { rpc?.cancel() }
  func exchange(_ request: EditorRequest) async throws -> EditorAuthenticatedReply {
    guard rpc == nil else { throw PhoneEditorError.busy }
    let current = try TrustedHostEndpoint(
      host: endpoint.host, port: endpoint.port,
      certificatePin: endpoint.certificatePin,
      authorityInstanceID: request.scope.authorityInstanceID)
    let rpc = PhoneEditorRPC(
      endpoint: current, credentials: credentials,
      makeIO: {
        try ControlTLSClient(
          host: current.host, port: current.port, certificatePin: current.certificatePin)
      },
      now: {
        let value = Date().timeIntervalSince1970 * 1000
        return value.isFinite && value >= 0 && value < Double(Int64.max)
          ? UInt64(value) : UInt64.max
      })
    self.rpc = rpc
    defer { self.rpc = nil }
    return try await rpc.exchange(request)
  }
}
