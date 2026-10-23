import Foundation

@MainActor protocol PhonePresentationBatch: AnyObject {
  func read(_ request: PhonePresentationRequest) async throws -> PhonePresentationMetadata
  func icon(_ control: PhonePresentationControl) async throws -> PhonePresentationIcon
  func close()
}
extension PhonePresentationClient: PhonePresentationBatch {}

/// Cosmetic management only. The caller's connection-lifetime predicate fences every notification.
@MainActor public final class PhonePresentationPoller {
  private let baseline: PhonePresentationRequest
  private let factory: () throws -> any PhonePresentationBatch
  private let colorScheme: () -> String
  private let active: () -> Bool
  private let notification: ([String: Any]) -> Void
  private let pause: () async throws -> Void
  private var task: Task<Void, Never>?
  private var sleeping: Task<Void, any Error>?
  private var refreshRequested = false
  private var current: (any PhonePresentationBatch)?
  private var closed = false
  private var cache: [String: PhonePresentationIcon] = [:]
  private var cacheOrder: [String] = []
  private var cacheBytes = 0
  public convenience init(
    endpoint: TrustedHostEndpoint, storage: PhoneCredentialWorker,
    request: PhonePresentationRequest, colorScheme: @escaping () -> String,
    active: @escaping () -> Bool, notification: @escaping ([String: Any]) -> Void
  ) {
    self.init(
      request: request,
      factory: { try PhonePresentationClient(endpoint: endpoint, storage: storage) },
      colorScheme: colorScheme, active: active, notification: notification)
  }
  init(
    request: PhonePresentationRequest, factory: @escaping () throws -> any PhonePresentationBatch,
    colorScheme: @escaping () -> String, active: @escaping () -> Bool,
    notification: @escaping ([String: Any]) -> Void,
    pause: @escaping () async throws -> Void = { try await Task.sleep(for: .seconds(2)) }
  ) {
    baseline = request
    self.factory = factory
    self.colorScheme = colorScheme
    self.active = active
    self.notification = notification
    self.pause = pause
  }
  public func start() {
    guard !closed, task == nil else { return }
    task = Task { [weak self] in await self?.run() }
  }
  private func valid(_ batch: any PhonePresentationBatch) -> Bool {
    !closed && !Task.isCancelled && active() && current === batch
  }
  private func store(_ icon: PhonePresentationIcon) {
    if cache[icon.sha256] != nil { return }
    while !cacheOrder.isEmpty && (cache.count >= 64 || cacheBytes + icon.byteCount > 524288) {
      let oldest = cacheOrder.removeFirst()
      if let removed = cache.removeValue(forKey: oldest) { cacheBytes -= removed.byteCount }
    }
    guard cache.count < 64, icon.byteCount <= 8192, cacheBytes + icon.byteCount <= 524288 else {
      return
    }
    cache[icon.sha256] = icon
    cacheOrder.append(icon.sha256)
    cacheBytes += icon.byteCount
  }
  private func run() async {
    polls: while !closed && !Task.isCancelled && active() {
      refreshRequested = false
      do {
        let request = try baseline.withColorScheme(colorScheme())
        let batch = try factory()
        current = batch
        do {
          let metadata = try await batch.read(request)
          guard valid(batch) else {
            batch.close()
            return
          }
          guard !refreshRequested, colorScheme() == request.colorScheme else {
            batch.close()
            current = nil
            continue polls
          }
          // Every successful metadata response is emitted, even when unchanged.
          notification(metadata.bridgeEvent)
          for control in metadata.controls {
            guard valid(batch) else {
              batch.close()
              return
            }
            guard let hash = control.iconSHA256 else { continue }
            let icon: PhonePresentationIcon
            if let cached = cache[hash] {
              icon = cached
            } else {
              icon = try await batch.icon(control)
            }
            guard valid(batch) else {
              batch.close()
              return
            }
            guard !refreshRequested, colorScheme() == request.colorScheme else {
              batch.close()
              current = nil
              continue polls
            }
            store(icon)
            notification(try icon.notification(metadata: metadata, controlId: control.id))
          }
          batch.close()
          if current === batch { current = nil }
        } catch {
          batch.close()
          if current === batch { current = nil }
          throw error
        }
      } catch {
        guard !closed, !Task.isCancelled, active() else { return }
        if refreshRequested { continue polls }
        let code: String
        if case PhonePresentationError.unavailable(let candidate) = error,
          PhonePresentationWire.errors.contains(candidate)
        {
          code = candidate
        } else {
          code = "presentation_unavailable"
        }
        notification([
          "kind": "error", "error": code, "generation": baseline.saved.generation,
          "revision": baseline.saved.revision, "configurationSha256": baseline.configurationSha256,
        ])
      }
      let sleeper = Task { try await pause() }
      sleeping = sleeper
      do { try await sleeper.value } catch {
        if !refreshRequested { return }
      }
      sleeping = nil
    }
  }
  public func refreshTheme() {
    guard !closed else { return }
    refreshRequested = true
    current?.close()
    sleeping?.cancel()
  }
  public func close() {
    guard !closed else { return }
    closed = true
    task?.cancel()
    task = nil
    sleeping?.cancel()
    sleeping = nil
    current?.close()
    current = nil
    cache.removeAll()
    cacheOrder.removeAll()
    cacheBytes = 0
  }
}
