import Foundation

/// Canonical private disk schema only. This is not a network parser or authentication evidence.
enum EditorJournalCodec {
  static let maximumBytes = 2 * 1024 * 1024
  static func hash(_ value: String) -> Bool {
    value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
  static func uuid(_ value: String) throws -> String {
    let value = value.lowercased()
    guard value.utf8.count == 36,
      value.range(
        of: "^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$",
        options: .regularExpression) != nil
    else { throw EditorJournalError.invalid }
    return value
  }
  static func counter(_ value: String) -> Bool {
    UInt64(value).map { String($0) == value } ?? false
  }
  static func operation(_ value: String) -> Bool {
    (1...64).contains(value.utf8.count)
      && value.utf8.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
      }
  }
  static func label(_ value: String) -> Bool { value.utf8.count <= 128 }
  private static func object(_ value: Any, _ keys: Set<String>) throws -> [String: Any] {
    guard let value = value as? [String: Any], Set(value.keys) == keys else {
      throw EditorJournalError.invalid
    }
    return value
  }
  private static func text(_ value: Any?) throws -> String {
    guard let value = value as? String else { throw EditorJournalError.invalid }
    return value
  }
  private static func nullable(_ value: Any?) throws -> String? {
    guard let value else { throw EditorJournalError.invalid }
    return value is NSNull ? nil : try text(value)
  }
  private static func array(_ value: Any?, maximum: Int) throws -> [Any] {
    guard let value = value as? [Any], value.count <= maximum else {
      throw EditorJournalError.invalid
    }
    return value
  }
  private static func scope(_ value: Any) throws -> EditorHostScope {
    let v = try object(value, ["certificateSHA256", "authorityInstanceId"])
    return try EditorHostScope(
      certificateSHA256: text(v["certificateSHA256"]),
      authorityInstanceID: text(v["authorityInstanceId"]))
  }
  private static func scopeJSON(_ scope: EditorHostScope) -> [String: Any] {
    [
      "certificateSHA256": scope.certificateSHA256,
      "authorityInstanceId": scope.authorityInstanceID,
    ]
  }
  private static func intent(_ value: Any) throws -> EditorLabelIntent {
    let v = try object(
      value, ["scope", "operationId", "expectedRevision", "profileId", "controlId", "label"])
    return try EditorLabelIntent(
      scope: scope(v["scope"]!), operationID: text(v["operationId"]),
      expectedRevision: text(v["expectedRevision"]), profileID: text(v["profileId"]),
      controlID: text(v["controlId"]), label: nullable(v["label"]))
  }
  private static func intentJSON(_ intent: EditorLabelIntent) -> [String: Any] {
    [
      "scope": scopeJSON(intent.scope), "operationId": intent.operationID,
      "expectedRevision": intent.expectedRevision, "profileId": intent.profileID,
      "controlId": intent.controlID, "label": intent.label as Any? ?? NSNull(),
    ]
  }
  private static func status(_ value: Any) throws -> EditorPendingStatus {
    guard let raw = value as? [String: Any] else { throw EditorJournalError.invalid }
    switch try text(raw["kind"]) {
    case "queued":
      _ = try object(value, ["kind"])
      return .queued
    case "uncertain":
      _ = try object(value, ["kind"])
      return .uncertain
    case "rejected":
      _ = try object(value, ["kind"])
      return .rejected
    case "conflict":
      let v = try object(value, ["kind", "currentRevision"])
      let revision = try text(v["currentRevision"])
      guard counter(revision) else { throw EditorJournalError.invalid }
      return .conflict(revision)
    default: throw EditorJournalError.invalid
    }
  }
  private static func statusJSON(_ status: EditorPendingStatus) -> [String: Any] {
    switch status {
    case .queued: return ["kind": "queued"]
    case .uncertain: return ["kind": "uncertain"]
    case .rejected: return ["kind": "rejected"]
    case .conflict(let revision): return ["kind": "conflict", "currentRevision": revision]
    }
  }
  private static func profile(_ value: Any) throws -> EditorCachedProfile {
    let v = try object(
      value, ["scope", "profileId", "name", "revision", "sourceSHA256", "controls"])
    let controls = try array(v["controls"], maximum: 128).map { raw in
      let c = try object(raw, ["controlId", "generatedLabel", "labelOverride"])
      return try EditorCachedControl(
        id: text(c["controlId"]), generatedLabel: text(c["generatedLabel"]),
        labelOverride: nullable(c["labelOverride"]))
    }
    return try EditorCachedProfile(
      scope: scope(v["scope"]!), id: text(v["profileId"]), name: text(v["name"]),
      revision: text(v["revision"]), sourceSHA256: text(v["sourceSHA256"]), controls: controls)
  }
  static func encode(_ state: EditorJournalSnapshot) throws -> Data {
    let value: [String: Any] = [
      "schemaVersion": 1, "certificateSHA256": state.certificateSHA256,
      "entries": state.entries.map {
        ["intent": intentJSON($0.intent), "status": statusJSON($0.status)]
      },
      "profiles": state.profiles.map { p -> [String: Any] in
        [
          "scope": scopeJSON(p.scope), "profileId": p.id, "name": p.name, "revision": p.revision,
          "sourceSHA256": p.sourceSHA256,
          "controls": p.controls.map {
            [
              "controlId": $0.id, "generatedLabel": $0.generatedLabel,
              "labelOverride": $0.labelOverride as Any? ?? NSNull(),
            ]
          },
        ]
      },
      "selection": state.selection.map {
        ["scope": scopeJSON($0.scope), "profileId": $0.profileID]
      } as Any? ?? NSNull(),
    ]
    let bytes = try JSONSerialization.data(
      withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    guard bytes.count <= maximumBytes else { throw EditorJournalError.full }
    return bytes
  }
  static func decode(_ bytes: Data) throws -> EditorJournalSnapshot {
    guard (1...maximumBytes).contains(bytes.count), String(data: bytes, encoding: .utf8) != nil
    else { throw EditorJournalError.invalid }
    // Bound native parser nesting/work before materializing any JSON graph.
    var depth = 0
    var nodes = 0
    var quoted = false
    var escaped = false
    for byte in bytes {
      if quoted {
        if escaped {
          escaped = false
        } else if byte == 92 {
          escaped = true
        } else if byte == 34 {
          quoted = false
        }
      } else if byte == 34 {
        quoted = true
      } else if byte == 123 || byte == 91 {
        depth += 1
        nodes += 1
        guard depth <= 12, nodes <= 4096 else { throw EditorJournalError.invalid }
      } else if byte == 125 || byte == 93 {
        depth -= 1
        guard depth >= 0 else { throw EditorJournalError.invalid }
      }
    }
    guard !quoted, depth == 0 else { throw EditorJournalError.invalid }
    do {
      let v = try object(
        JSONSerialization.jsonObject(with: bytes),
        ["schemaVersion", "certificateSHA256", "entries", "profiles", "selection"])
      guard (v["schemaVersion"] as? Int) == 1 else { throw EditorJournalError.invalid }
      let entries = try array(v["entries"], maximum: 128).map { value in
        let e = try object(value, ["intent", "status"])
        return try EditorPendingEntry(intent: intent(e["intent"]!), status: status(e["status"]!))
      }
      let profiles = try array(v["profiles"], maximum: 8).map(profile)
      let selected: EditorSelection?
      if v["selection"] is NSNull {
        selected = nil
      } else {
        let s = try object(v["selection"]!, ["scope", "profileId"])
        selected = try EditorSelection(scope: scope(s["scope"]!), profileID: text(s["profileId"]))
      }
      let state = try EditorJournalSnapshot(
        pin: text(v["certificateSHA256"]), entries: entries, profiles: profiles, selection: selected
      )
      // Canonical re-encoding rejects duplicate keys, lossy Unicode, alternate key
      // spellings, unknown fields and coercions. Existing corrupt bytes are never reset.
      guard try encode(state) == bytes else { throw EditorJournalError.invalid }
      return state
    } catch { throw EditorJournalError.invalid }
  }
}
