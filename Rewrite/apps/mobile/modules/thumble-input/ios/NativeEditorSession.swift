import ExpoModulesCore
import Foundation
import MobileInputCore

/// One journal owner per app process. Closed owners remain reserved until their IO settles.
@MainActor final class NativeEditorSession {
  static let shared = NativeEditorSession()
  private let registry = PhoneEditorRegistry()
  func open(_ owner: PhoneEditorModuleLifetime) async throws -> String {
    try await registry.open(owner: owner) {
      guard let value = UserDefaults.standard.dictionary(forKey: "rewrite.phone.endpoint.v1"),
        Set(value.keys) == Set(["host", "port", "pin", "authority"]),
        let host = value["host"] as? String, let port = value["port"] as? Int,
        let boundedPort = UInt16(exactly: port), let pin = value["pin"] as? String,
        let authority = value["authority"] as? String
      else { throw InputError.unavailable }
      let endpoint = try TrustedHostEndpoint(
        host: host, port: boundedPort, certificatePin: pin, authorityInstanceID: authority)
      return await PhoneEditorSession(endpoint: endpoint)
    }
  }
  func get(_ id: String, owner: PhoneEditorModuleLifetime) throws -> PhoneEditorSession {
    try registry.session(owner: owner, handle: id)
  }
  func close(_ id: String, owner: PhoneEditorModuleLifetime) async throws {
    try await registry.close(owner: owner, handle: id)
  }
  func invalidate(_ owner: PhoneEditorModuleLifetime) async {
    await registry.invalidate(owner: owner)
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
