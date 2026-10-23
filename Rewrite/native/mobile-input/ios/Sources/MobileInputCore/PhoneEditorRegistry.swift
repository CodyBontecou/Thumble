import Foundation

/// Native module identity; invalidation is synchronous even before an actor hop.
/// The lock protects only this bit, never journal, network, or registry work.
public final class PhoneEditorModuleLifetime: @unchecked Sendable {
  private let lock = NSLock()
  private var live = true
  public init() {}
  public func invalidate() { lock.withLock { live = false } }
  public var isValid: Bool { lock.withLock { live } }
}

/// One protected journal owner across JavaScript runtimes in the same process.
@MainActor public final class PhoneEditorRegistry {
  private final class Reservation {
    let owner: PhoneEditorModuleLifetime
    var session: PhoneEditorSession?
    var handle: String?
    var closing = false
    var closeReturned = false
    var closeTask: Task<Void, Never>?
    init(_ owner: PhoneEditorModuleLifetime) { self.owner = owner }
  }
  private var reservation: Reservation?
  private var opening = false
  public init() {}

  public func open(
    owner: PhoneEditorModuleLifetime,
    create: @MainActor () async throws -> PhoneEditorSession
  ) async throws -> String {
    guard owner.isValid, !opening else { throw PhoneEditorError.unavailable }
    opening = true
    defer { opening = false }
    if let old = reservation {
      guard old.closing, old.closeReturned else { throw PhoneEditorError.busy }
      if let session = old.session {
        guard await session.reusable else { throw PhoneEditorError.busy }
      }
      guard reservation === old, owner.isValid else { throw PhoneEditorError.unavailable }
      reservation = nil
    }
    let candidate = Reservation(owner)
    reservation = candidate  // Reserve before async initialization can suspend.
    do {
      let session = try await create()
      candidate.session = session
      try Task.checkCancellation()
      guard owner.isValid, !candidate.closing else { throw PhoneEditorError.unavailable }
      _ = try await session.snapshot()
      try Task.checkCancellation()
      guard owner.isValid, !candidate.closing, reservation === candidate else {
        throw PhoneEditorError.unavailable
      }
      let handle = UUID().uuidString.lowercased()
      candidate.handle = handle
      return handle
    } catch {
      await retire(candidate)
      throw error
    }
  }
  public func session(owner: PhoneEditorModuleLifetime, handle: String) throws -> PhoneEditorSession
  {
    guard owner.isValid, let record = reservation, record.owner === owner,
      !record.closing, record.handle == handle, let session = record.session
    else { throw PhoneEditorError.unavailable }
    return session
  }
  public func close(owner: PhoneEditorModuleLifetime, handle: String) async throws {
    _ = try session(owner: owner, handle: handle)
    guard let record = reservation else { throw PhoneEditorError.unavailable }
    await retire(record)
  }
  public func invalidate(owner: PhoneEditorModuleLifetime) async {
    owner.invalidate()
    guard let record = reservation, record.owner === owner else { return }
    await retire(record)
  }
  private func retire(_ record: Reservation) async {
    record.closing = true
    guard let session = record.session else {
      // Async creation may still be pending. open() retires its returned candidate.
      // `opening` prevents reuse until that continuation has run.
      record.closeReturned = true
      return
    }
    if record.closeTask == nil {
      record.closeReturned = false
      record.closeTask = Task { await session.close() }
    }
    await record.closeTask?.value
    record.closeReturned = true
  }
}
