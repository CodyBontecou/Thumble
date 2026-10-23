import ExpoModulesCore
import Foundation
import MobileInputCore

/// One journal owner per app process. Closed owners remain reserved until their IO settles.
@MainActor final class NativeEditorSession {
  static let shared = NativeEditorSession()
  private var session: PhoneEditorSession?
  private var handle: String?
  private var closing = false
  private var closeReturned = false
  private var opening = false
  func open() async throws -> String {
    guard !opening else { throw InputError.unavailable }
    opening = true
    defer { opening = false }
    if let session {
      guard closing, closeReturned, await session.reusable else { throw InputError.unavailable }
      self.session = nil
      handle = nil
      closing = false
      closeReturned = false
    }
    guard let value = UserDefaults.standard.dictionary(forKey: "rewrite.phone.endpoint.v1"),
      Set(value.keys) == Set(["host", "port", "pin", "authority"]),
      let host = value["host"] as? String, let port = value["port"] as? Int,
      let boundedPort = UInt16(exactly: port), let pin = value["pin"] as? String,
      let authority = value["authority"] as? String
    else { throw InputError.unavailable }
    let endpoint = try TrustedHostEndpoint(
      host: host, port: boundedPort, certificatePin: pin, authorityInstanceID: authority)
    let next = await PhoneEditorSession(endpoint: endpoint)
    // Corruption is a failed open, never permission to reset the store.
    _ = try await next.snapshot()
    let id = UUID().uuidString.lowercased()
    session = next
    handle = id
    return id
  }
  func get(_ id: String) throws -> PhoneEditorSession {
    guard !closing, handle == id, let session else { throw InputError.unavailable }
    return session
  }
  func close(_ id: String) async throws {
    let owner = try get(id)
    closing = true
    closeReturned = false
    await owner.close()
    closeReturned = true
  }
}

extension PhoneEditorSnapshot {
  var editorBridge: [String: Any] {
    [
      "profiles": profiles.map {
        [
          "contextId": $0.contextID, "profileId": $0.profileID,
          "name": $0.name, "revision": $0.revision, "sourceSha256": $0.sourceSHA256,
          "controlCount": $0.controlCount,
        ] as [String: Any]
      },
      "selection": selection as Any? ?? NSNull(),
      "queue": entries.map { entry -> [String: Any] in
        let status: String
        let conflict: String?
        switch entry.status {
        case .queued:
          status = "queued"
          conflict = nil
        case .uncertain:
          status = "uncertain"
          conflict = nil
        case .rejected:
          status = "rejected"
          conflict = nil
        case .conflict(let revision):
          status = "conflict"
          conflict = revision
        }
        return [
          "operationId": entry.intent.operationID, "profileId": entry.intent.profileID,
          "controlId": entry.intent.controlID, "expectedRevision": entry.intent.expectedRevision,
          "label": entry.intent.label as Any? ?? NSNull(), "status": status,
          "conflictRevision": conflict as Any? ?? NSNull(),
        ]
      },
    ]
  }
}
extension PhoneEditorCachePage {
  var editorBridge: [String: Any] {
    [
      "contextId": contextID, "offset": offset, "nextOffset": nextOffset as Any? ?? NSNull(),
      "controls": controls.map {
        [
          "id": $0.id, "generatedLabel": $0.generatedLabel,
          "labelOverride": $0.labelOverride as Any? ?? NSNull(),
        ] as [String: Any]
      },
    ]
  }
}

extension PhoneEditorError: @retroactive CodedError {
  public var code: String { rawValue }
  public var description: String { rawValue }
}
