import Foundation

// Strict internal codec. The explicit SDK factory owns transport and trust.
public enum PhoneEditorError: String, Error, Equatable, CustomNSError {
  case rejected = "editor_rejected"
  case busy = "editor_busy"
  case unavailable = "editor_unavailable"
  case originReconciliationRequired = "origin-reconciliation-required"
  public static var errorDomain: String { "ThumblePhoneEditor" }
  public var errorCode: Int {
    switch self {
    case .rejected: 1
    case .busy: 2
    case .unavailable: 3
    case .originReconciliationRequired: 4
    }
  }
  public var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: rawValue] }
}
indirect enum EditorJSON: Sendable, Equatable {
  case object([String: EditorJSON])
  case array([EditorJSON])
  case string(String)
  case integer(Int64)
  case boolean(Bool)
  case null
  var object: [String: EditorJSON]? {
    if case .object(let value) = self { return value }
    return nil
  }
  var text: String? {
    if case .string(let value) = self { return value }
    return nil
  }
  var number: Int64? {
    if case .integer(let value) = self { return value }
    return nil
  }
}
struct EditorWireParser {
  private let bytes: [UInt8]
  private var at = 0
  private var nodes = 0
  init(_ data: Data) throws {
    guard data.count <= 16_384, String(data: data, encoding: .utf8) != nil else {
      throw PhoneEditorError.rejected
    }
    bytes = Array(data)
  }
  mutating func parse() throws -> [String: EditorJSON] {
    let value = try value(0)
    whitespace()
    guard at == bytes.count, let result = value.object else { throw PhoneEditorError.rejected }
    return result
  }
  private mutating func whitespace() {
    while at < bytes.count && [9, 10, 13, 32].contains(bytes[at]) { at += 1 }
  }
  private mutating func consume(_ byte: UInt8) throws {
    whitespace()
    guard at < bytes.count, bytes[at] == byte else { throw PhoneEditorError.rejected }
    at += 1
  }
  private mutating func string() throws -> String {
    whitespace()
    let start = at
    try consume(34)
    var escaped = false
    while at < bytes.count {
      let byte = bytes[at]
      at += 1
      if byte < 32 { throw PhoneEditorError.rejected }
      if !escaped && byte == 34 {
        let fragment = Data(bytes[start..<at])
        guard
          let decoded = try JSONSerialization.jsonObject(with: fragment, options: .fragmentsAllowed)
            as? String, decoded.utf8.count <= 1024
        else { throw PhoneEditorError.rejected }
        return decoded
      }
      if !escaped && byte == 92 { escaped = true } else { escaped = false }
    }
    throw PhoneEditorError.rejected
  }
  private mutating func value(_ depth: Int) throws -> EditorJSON {
    whitespace()
    nodes += 1
    guard depth <= 4, nodes <= 128, at < bytes.count else { throw PhoneEditorError.rejected }
    switch bytes[at] {
    case 123:
      at += 1
      whitespace()
      var result: [String: EditorJSON] = [:]
      if at < bytes.count && bytes[at] == 125 {
        at += 1
        return .object(result)
      }
      while true {
        let key = try string()
        guard key.utf8.count <= 64, result[key] == nil else { throw PhoneEditorError.rejected }
        try consume(58)
        result[key] = try value(depth + 1)
        whitespace()
        guard at < bytes.count else { throw PhoneEditorError.rejected }
        if bytes[at] == 125 {
          at += 1
          return .object(result)
        }
        try consume(44)
      }
    case 91:
      at += 1
      whitespace()
      var result: [EditorJSON] = []
      if at < bytes.count && bytes[at] == 93 {
        at += 1
        return .array(result)
      }
      while true {
        guard result.count < 8 else { throw PhoneEditorError.rejected }
        result.append(try value(depth + 1))
        whitespace()
        guard at < bytes.count else { throw PhoneEditorError.rejected }
        if bytes[at] == 93 {
          at += 1
          return .array(result)
        }
        try consume(44)
      }
    case 34: return .string(try string())
    case 110:
      try literal("null")
      return .null
    case 116:
      try literal("true")
      return .boolean(true)
    case 102:
      try literal("false")
      return .boolean(false)
    default:
      let start = at
      guard bytes[at] != 45 else { throw PhoneEditorError.rejected }
      guard at < bytes.count, (48...57).contains(bytes[at]) else { throw PhoneEditorError.rejected }
      if bytes[at] == 48 {
        at += 1
      } else {
        while at < bytes.count && (48...57).contains(bytes[at]) { at += 1 }
      }
      guard let number = Int64(String(decoding: bytes[start..<at], as: UTF8.self)) else {
        throw PhoneEditorError.rejected
      }
      return .integer(number)
    }
  }
  private mutating func literal(_ text: String) throws {
    let word = Array(text.utf8)
    guard at + word.count <= bytes.count, Array(bytes[at..<at + word.count]) == word else {
      throw PhoneEditorError.rejected
    }
    at += word.count
  }
}
struct EditorReadPin: Sendable, Equatable {
  let scope: EditorHostScope
  let revision, sourceHash, profileID: String
  init(scope: EditorHostScope, revision: String, sourceHash: String, profileID: String) throws {
    guard EditorJournalCodec.counter(revision), EditorJournalCodec.hash(sourceHash) else {
      throw PhoneEditorError.rejected
    }
    self.scope = scope
    self.revision = revision
    self.sourceHash = sourceHash
    self.profileID = try EditorJournalCodec.uuid(profileID)
  }
}
enum EditorRequest: Sendable, Equatable {
  case profile(EditorReadPin, Int)
  case label(EditorLabelIntent)
  case status(EditorLabelIntent)
  var scope: EditorHostScope {
    switch self {
    case .profile(let pin, _): pin.scope
    case .label(let intent), .status(let intent): intent.scope
    }
  }
  var command: String {
    switch self {
    case .profile: "editor-profile"
    case .label: "configuration-set-control-label"
    case .status: "editor-label-status"
    }
  }
  func fields(connection: String) throws -> [String: Any] {
    guard EditorWire.hex(connection, count: 32) else { throw PhoneEditorError.rejected }
    var result: [String: Any] = [
      "version": 1, "connectionId": connection, "authorityInstanceId": scope.authorityInstanceID,
      "command": command,
    ]
    switch self {
    case .profile(let pin, let offset):
      guard (0...120).contains(offset), offset % 8 == 0 else { throw PhoneEditorError.rejected }
      result.merge([
        "expectedRevision": pin.revision, "expectedSourceHash": pin.sourceHash,
        "profileId": pin.profileID, "offset": offset,
      ]) { _, new in new }
    case .label(let intent): result.merge(Self.intentFields(intent)) { _, new in new }
    case .status(let intent):
      var inner = Self.intentFields(intent)
      inner["command"] = "configuration-set-control-label"
      result["intent"] = inner
    }
    return result
  }
  private static func intentFields(_ intent: EditorLabelIntent) -> [String: Any] {
    [
      "operationId": intent.operationID, "expectedRevision": intent.expectedRevision,
      "profileId": intent.profileID, "controlId": intent.controlID,
      "label": intent.label as Any? ?? NSNull(),
    ]
  }
}
struct EditorProfilePage: Sendable {
  let pin: EditorReadPin
  let name: String
  let offset, total: Int
  let next: Int?
  let controls: [EditorCachedControl]
}
struct EditorReceipt: Sendable {
  let operationID, revision, hash: String
  let entities: [String]
}
enum EditorReply: Sendable {
  case profile(EditorProfilePage)
  case admitted, pending
  case committed(EditorReceipt)
  case conflict(String)
  case error(String)
}
struct EditorWire {
  static let errors: Set<String> = [
    "editor_busy", "editor_unavailable", "editor_invalid_request", "editor_access_denied",
    "editor_operation_reused", "editor_profile_not_found", "editor_control_not_found",
    "editor_source_changed", "editor_unsupported_profile", "editor_response_too_large",
  ]
  static func parse(_ data: Data) throws -> [String: EditorJSON] {
    var parser = try EditorWireParser(data)
    return try parser.parse()
  }
  static func hex(_ text: String, count: Int) -> Bool {
    text.utf8.count == count
      && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
  static func keys(_ fields: [String: EditorJSON], _ expected: [String]) throws {
    guard Set(fields.keys) == Set(expected) else { throw PhoneEditorError.rejected }
  }
  static func reply(_ bytes: Data, request: EditorRequest, connection: String) throws -> EditorReply
  {
    let fields = try parse(bytes)
    let common = ["version", "connectionId", "authorityInstanceId", "command", "kind"]
    guard fields["version"] == .integer(1), fields["connectionId"] == .string(connection),
      fields["authorityInstanceId"] == .string(request.scope.authorityInstanceID),
      fields["command"] == .string(request.command + "-result"), let kind = fields["kind"]?.text
    else { throw PhoneEditorError.rejected }
    if kind == "error" {
      try keys(fields, common + ["error"])
      guard let error = fields["error"]?.text, errors.contains(error) else {
        throw PhoneEditorError.rejected
      }
      return .error(error)
    }
    switch request {
    case .profile(let pin, let requestedOffset):
      try keys(
        fields,
        common + [
          "revision", "contentHash", "profileId", "name", "offset", "totalControls", "nextOffset",
          "controls",
        ])
      guard kind == "editor-profile", fields["revision"] == .string(pin.revision),
        fields["contentHash"] == .string(pin.sourceHash),
        fields["profileId"] == .string(pin.profileID),
        fields["offset"] == .integer(Int64(requestedOffset)), let name = fields["name"]?.text,
        validName(name), let total = fields["totalControls"]?.number, (0...128).contains(total),
        case .array(let rows)? = fields["controls"]
      else { throw PhoneEditorError.rejected }
      let remaining = max(0, Int(total) - requestedOffset)
      let expectedCount = min(8, remaining)
      guard rows.count == expectedCount, requestedOffset <= Int(total),
        requestedOffset == 0 || requestedOffset < Int(total)
      else { throw PhoneEditorError.rejected }
      let next = requestedOffset + rows.count < Int(total) ? requestedOffset + rows.count : nil
      guard fields["nextOffset"] == next.map({ .integer(Int64($0)) }) ?? .null else {
        throw PhoneEditorError.rejected
      }
      let controls = try rows.map { row -> EditorCachedControl in
        guard let row = row.object else { throw PhoneEditorError.rejected }
        try keys(row, ["id", "generatedLabel", "labelOverride"])
        guard let id = row["id"]?.text, try EditorJournalCodec.uuid(id) == id,
          let generated = row["generatedLabel"]?.text
        else { throw PhoneEditorError.rejected }
        return try EditorCachedControl(
          id: id, generatedLabel: generated, labelOverride: nullableLabel(row["labelOverride"]))
      }
      guard Set(controls.map(\.id)).count == controls.count else { throw PhoneEditorError.rejected }
      return .profile(
        EditorProfilePage(
          pin: pin, name: name, offset: requestedOffset, total: Int(total), next: next,
          controls: controls))
    case .label(let intent), .status(let intent):
      if kind == "editor-label-admitted" || kind == "editor-label-pending" {
        try keys(fields, common + ["operationId"])
        guard fields["operationId"] == .string(intent.operationID),
          (request.command == "configuration-set-control-label" && kind == "editor-label-admitted")
            || (request.command == "editor-label-status" && kind == "editor-label-pending")
        else { throw PhoneEditorError.rejected }
        return kind == "editor-label-admitted" ? .admitted : .pending
      }
      if kind == "conflict" {
        try keys(fields, common + ["currentRevision"])
        guard request.command == "configuration-set-control-label",
          let revision = fields["currentRevision"]?.text, EditorJournalCodec.counter(revision)
        else { throw PhoneEditorError.rejected }
        return .conflict(revision)
      }
      let committed = request.command == "configuration-set-control-label"
      try keys(fields, common + ["receipt"] + (committed ? ["replayed"] : []))
      guard kind == (committed ? "committed" : "editor-label-receipt"),
        !committed || fields["replayed"] == .boolean(true) || fields["replayed"] == .boolean(false),
        let receipt = fields["receipt"]?.object
      else { throw PhoneEditorError.rejected }
      try keys(
        receipt, ["version", "operationId", "resultingRevision", "contentHash", "affectedEntities"])
      guard receipt["version"] == .integer(1),
        receipt["operationId"] == .string(intent.operationID),
        let revision = receipt["resultingRevision"]?.text, EditorJournalCodec.counter(revision),
        UInt64(intent.expectedRevision)! < UInt64.max,
        UInt64(revision)! == UInt64(intent.expectedRevision)! + 1,
        let hash = receipt["contentHash"]?.text, EditorJournalCodec.hash(hash),
        receipt["affectedEntities"]
          == .array([.string(intent.profileID), .string(intent.controlID)])
      else { throw PhoneEditorError.rejected }
      return .committed(
        EditorReceipt(
          operationID: intent.operationID, revision: revision, hash: hash,
          entities: [intent.profileID, intent.controlID]))
    }
  }
  private static func nullableLabel(_ value: EditorJSON?) throws -> String? {
    if value == .null { return nil }
    guard let text = value?.text, EditorJournalCodec.label(text) else {
      throw PhoneEditorError.rejected
    }
    return text
  }
  private static func validName(_ name: String) -> Bool {
    name.unicodeScalars.count <= 256 && name.utf8.count <= 1024
      && name.unicodeScalars.contains { scalar in
        switch scalar.value {
        case 9...13, 32, 160, 5760, 8192...8202, 8232, 8233, 8239, 8287, 12288, 65279: return false
        default: return true
        }
      }
  }
}
extension EditorWire {
  static func request(_ bytes: Data, scope: EditorHostScope, connection: String) throws
    -> EditorRequest
  {
    guard bytes.count <= 2048 else { throw PhoneEditorError.rejected }
    let fields = try parse(bytes)
    let common = ["version", "connectionId", "authorityInstanceId", "command"]
    guard fields["version"] == .integer(1), fields["connectionId"] == .string(connection),
      fields["authorityInstanceId"] == .string(scope.authorityInstanceID),
      let command = fields["command"]?.text
    else { throw PhoneEditorError.rejected }
    switch command {
    case "editor-profile":
      try keys(fields, common + ["expectedRevision", "expectedSourceHash", "profileId", "offset"])
      guard let revision = fields["expectedRevision"]?.text,
        let source = fields["expectedSourceHash"]?.text, let profile = fields["profileId"]?.text,
        try EditorJournalCodec.uuid(profile) == profile, let offset = fields["offset"]?.number,
        (0...120).contains(offset), offset % 8 == 0
      else { throw PhoneEditorError.rejected }
      return .profile(
        try EditorReadPin(scope: scope, revision: revision, sourceHash: source, profileID: profile),
        Int(offset))
    case "configuration-set-control-label":
      try keys(
        fields, common + ["operationId", "expectedRevision", "profileId", "controlId", "label"])
      return .label(try intent(fields, scope: scope))
    case "editor-label-status":
      try keys(fields, common + ["intent"])
      guard let inner = fields["intent"]?.object else { throw PhoneEditorError.rejected }
      try keys(
        inner, ["command", "operationId", "expectedRevision", "profileId", "controlId", "label"])
      guard inner["command"] == .string("configuration-set-control-label") else {
        throw PhoneEditorError.rejected
      }
      return .status(try intent(inner, scope: scope))
    default: throw PhoneEditorError.rejected
    }
  }
  private static func intent(_ fields: [String: EditorJSON], scope: EditorHostScope) throws
    -> EditorLabelIntent
  {
    guard let operation = fields["operationId"]?.text,
      let revision = fields["expectedRevision"]?.text, let profile = fields["profileId"]?.text,
      let control = fields["controlId"]?.text, try EditorJournalCodec.uuid(profile) == profile,
      try EditorJournalCodec.uuid(control) == control
    else { throw PhoneEditorError.rejected }
    return try EditorLabelIntent(
      scope: scope, operationID: operation, expectedRevision: revision, profileID: profile,
      controlID: control, label: nullableLabel(fields["label"]))
  }
}
