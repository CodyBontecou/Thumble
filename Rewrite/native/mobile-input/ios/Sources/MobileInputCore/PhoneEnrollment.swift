import Foundation

public enum PhoneEnrollmentError: Error { case rejected }
/// Invitation secret is native bootstrap material, never a status/configuration document.
public struct EnrollmentInvitation: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  public let host: String, certificatePin: String, authorityInstanceID: String, windowID: String
  public let port: UInt16, expiresAt: UInt64
  fileprivate let proof: String
  public var description: String { "EnrollmentInvitation([redacted])" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: ["invitation": "[redacted]"]) }
  public init(
    host: String, port: UInt16, certificatePin: String, authorityInstanceID: String,
    windowID: String, secret: String, expiresAt: UInt64
  ) throws {
    guard !host.isEmpty, host.utf8.count <= 253, !host.contains("\0"), port > 0,
      PhoneCredential.pin(certificatePin), PhoneCredential.pin(secret),
      Self.identity(authorityInstanceID), Self.identity(windowID), expiresAt > 0,
      expiresAt <= UInt64(Int64.max)
    else { throw PhoneEnrollmentError.rejected }
    self.host = host
    self.port = port
    self.certificatePin = certificatePin
    self.authorityInstanceID = authorityInstanceID
    self.windowID = windowID
    self.proof = secret
    self.expiresAt = expiresAt
  }
  static func identity(_ value: String) -> Bool {
    (1...64).contains(value.utf8.count)
      && value.utf8.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
      }
  }
}
/// A single native storage owner keeps Keychain I/O away from UI/input sampling.
public actor PhoneCredentialWorker {
  private let vault = PhoneCredentialVault()
  public init() {}
  public func save(_ credential: PhoneCredential) throws { try vault.save(credential) }
  public func load(hostPin: String, now: UInt64) throws -> PhoneCredential? {
    try vault.load(hostPin: hostPin, now: now)
  }
}
protocol EnrollmentCredentialSink: Sendable {
  func save(_ credential: PhoneCredential) async throws
}
extension PhoneCredentialWorker: EnrollmentCredentialSink {}
@MainActor protocol EnrollmentFrameIO: AnyObject {
  func connect() async throws
  func offer(_ frame: ControlTLSFrame) -> Bool
  func receive() async throws -> ControlTLSFrame
  func close()
}
extension ControlTLSClient: EnrollmentFrameIO {}

/// Control version 2: success requires durable local storage and the host's final confirmation.
@MainActor public final class PhoneEnrollmentClient {
  private enum State { case idle, enrolling, finished, closed }
  private var state: State = .idle
  private let invitation: EnrollmentInvitation
  private let io: any EnrollmentFrameIO
  private let sink: any EnrollmentCredentialSink
  private let now: () -> UInt64
  private var last: UInt64 = 0
  public convenience init(invitation: EnrollmentInvitation, storage: PhoneCredentialWorker) throws {
    try self.init(
      invitation: invitation,
      io: ControlTLSClient(
        host: invitation.host, port: invitation.port, certificatePin: invitation.certificatePin),
      sink: storage, now: Self.wallTime)
  }
  init(
    invitation: EnrollmentInvitation, io: any EnrollmentFrameIO, sink: any EnrollmentCredentialSink,
    now: @escaping () -> UInt64
  ) {
    self.invitation = invitation
    self.io = io
    self.sink = sink
    self.now = now
  }
  private nonisolated static func wallTime() -> UInt64 {
    let value = Date().timeIntervalSince1970 * 1000
    return value.isFinite && value >= 0 && value < Double(Int64.max) ? UInt64(value) : UInt64.max
  }
  private func clock() -> UInt64 { now() }
  private func checkpoint(invitationRequired: Bool = false) throws -> UInt64 {
    try Task.checkCancellation()
    let time = clock()
    guard state == .enrolling, time >= last, time <= UInt64(Int64.max),
      !invitationRequired || time < invitation.expiresAt
    else { throw PhoneEnrollmentError.rejected }
    last = time
    return time
  }
  private func send(_ value: [String: Any]) throws {
    _ = try checkpoint()
    guard
      io.offer(
        try ControlTLSFrame(kind: .control, payload: JSONSerialization.data(withJSONObject: value)))
    else { throw PhoneEnrollmentError.rejected }
  }
  private func receive() async throws -> [String: EnrollmentJSON.Value] {
    let frame = try await io.receive()
    _ = try checkpoint()
    guard frame.kind == .control else { throw PhoneEnrollmentError.rejected }
    return try EnrollmentJSON.parse(frame.payload)
  }
  public func enroll(phoneID: String, label: String) async throws -> PhoneCredentialMetadata {
    guard state == .idle, EnrollmentInvitation.identity(phoneID), !label.isEmpty,
      label.utf8.count <= 128,
      !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { throw PhoneEnrollmentError.rejected }
    state = .enrolling
    return try await withTaskCancellationHandler {
      do {
        _ = try checkpoint(invitationRequired: true)
        try await io.connect()
        _ = try checkpoint(invitationRequired: true)
        try send([
          "version": 1, "command": "hello", "controlVersion": 2, "inputVersion": 1,
          "documentVersion": 1, "capabilitiesVersion": 1,
        ])
        let hello = try await receive()
        let expected: [String: EnrollmentJSON.Value] = [
          "version": .integer(1), "command": .string("hello"),
          "authorityInstanceId": .string(invitation.authorityInstanceID),
          "controlVersion": .integer(2), "inputVersion": .integer(1),
          "documentVersion": .integer(1), "capabilitiesVersion": .integer(1),
          "inputEnabled": .boolean(false),
        ]
        guard hello == expected else { throw PhoneEnrollmentError.rejected }
        _ = try checkpoint(invitationRequired: true)
        try send([
          "version": 1, "command": "enroll", "authorityInstanceId": invitation.authorityInstanceID,
          "windowId": invitation.windowID, "proof": invitation.proof, "phoneId": phoneID,
          "label": label,
        ])
        let reply = try await receive()
        guard
          Set(reply.keys)
            == Set(["version", "command", "phoneId", "credentialEpoch", "expiresAt", "credential"]),
          reply["version"] == .integer(1), reply["command"] == .string("enrolled"),
          reply["phoneId"] == .string(phoneID),
          case .string(let epochText)? = reply["credentialEpoch"], let epoch = UInt64(epochText),
          epoch > 0, String(epoch) == epochText, case .integer(let expires)? = reply["expiresAt"],
          expires > last, case .string(let token)? = reply["credential"], PhoneCredential.pin(token)
        else { throw PhoneEnrollmentError.rejected }
        let pairs = Array(token.utf8)
        let secret = Data(
          stride(from: 0, to: 64, by: 2).map { i in
            let a = pairs[i]
            let b = pairs[i + 1]
            return (a <= 57 ? a - 48 : a - 87) * 16 + (b <= 57 ? b - 48 : b - 87)
          })
        let credential = try PhoneCredential(
          hostPin: invitation.certificatePin, phoneID: phoneID, epoch: epoch, expiresAt: expires,
          token: secret)
        try await sink.save(credential)
        guard try checkpoint() < expires else { throw PhoneEnrollmentError.rejected }
        try send([
          "version": 1, "command": "enrollment-stored", "phoneId": phoneID,
          "credentialEpoch": epochText,
        ])
        let complete = try await receive()
        guard
          complete == [
            "version": .integer(1), "command": .string("enrollment-complete"),
            "phoneId": .string(phoneID), "credentialEpoch": .string(epochText),
            "inputEnabled": .boolean(false),
          ], last < expires
        else { throw PhoneEnrollmentError.rejected }
        state = .finished
        return credential.metadata
      } catch {
        close()
        throw PhoneEnrollmentError.rejected
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.close() }
    }
  }
  public func close() {
    state = .closed
    io.close()
  }
}

/// This protocol deliberately permits flat objects of strings, unsigned integers and booleans only.
/// Strings use Foundation's JSON validation; duplicate decoded keys and unsupported shapes fail.
enum EnrollmentJSON {
  enum Value: Equatable {
    case string(String)
    case integer(UInt64)
    case boolean(Bool)
    case null
  }
  static func parse(_ data: Data, allowNull: Bool = false) throws -> [String: Value] {
    let bytes = Array(data)
    var at = 0
    func reject() -> PhoneEnrollmentError { .rejected }
    func space() { while at < bytes.count && [9, 10, 13, 32].contains(bytes[at]) { at += 1 } }
    func string() throws -> String {
      guard at < bytes.count, bytes[at] == 34 else { throw reject() }
      let start = at
      at += 1
      while at < bytes.count {
        let byte = bytes[at]
        at += 1
        if byte == 92 {
          guard at < bytes.count else { throw reject() }
          at += 1
        } else if byte == 34 {
          return try JSONDecoder().decode(String.self, from: Data(bytes[start..<at]))
        }
      }
      throw reject()
    }
    guard (2...65_536).contains(bytes.count) else { throw reject() }
    space()
    guard at < bytes.count, bytes[at] == 123 else { throw reject() }
    at += 1
    space()
    var result: [String: Value] = [:]
    if at < bytes.count && bytes[at] == 125 {
      at += 1
      space()
      guard at == bytes.count else { throw reject() }
      return result
    }
    while at < bytes.count {
      let key = try string()
      guard result[key] == nil else { throw reject() }
      space()
      guard at < bytes.count, bytes[at] == 58 else { throw reject() }
      at += 1
      space()
      guard at < bytes.count else { throw reject() }
      let value: Value
      if bytes[at] == 34 {
        value = .string(try string())
      } else {
        let start = at
        while at < bytes.count && ![9, 10, 13, 32, 44, 125].contains(bytes[at]) { at += 1 }
        let token = Array(bytes[start..<at])
        if token == Array("true".utf8) {
          value = .boolean(true)
        } else if token == Array("false".utf8) {
          value = .boolean(false)
        } else if allowNull && token == Array("null".utf8) {
          value = .null
        } else {
          guard !token.isEmpty, token.allSatisfy({ (48...57).contains($0) }),
            token.count == 1 || token.first != 48,
            let integer = UInt64(String(decoding: token, as: UTF8.self)),
            integer <= UInt64(Int64.max)
          else { throw reject() }
          value = .integer(integer)
        }
      }
      result[key] = value
      space()
      guard at < bytes.count else { throw reject() }
      if bytes[at] == 125 {
        at += 1
        space()
        guard at == bytes.count else { throw reject() }
        return result
      }
      guard bytes[at] == 44 else { throw reject() }
      at += 1
      space()
    }
    throw reject()
  }
}
