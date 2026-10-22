import Foundation

public enum CaptureProtocolError: Error {
  case invalidRequest, invalidReply, truncatedFrame, oversizedFrame
}
public struct CaptureRequest: Sendable, Equatable {
  public let source: UInt32
  public let generation: String
  public let receipt: String
  public let generationValue: UInt64
  public let receiptValue: UInt64
  public static let maximumBytes = 256
  public static let maximumReplyBytes = 4 * ((2 * 1024 * 1024 + 2) / 3) + 1024

  public static func decode(_ data: Data) throws -> Self {
    guard data.count <= maximumBytes else { throw CaptureProtocolError.oversizedFrame }
    let bytes = Array(data)
    guard bytes.allSatisfy({ $0 < 128 }) else { throw CaptureProtocolError.invalidRequest }
    var at = 0
    func whitespace() { while at < bytes.count, [9, 10, 13, 32].contains(bytes[at]) { at += 1 } }
    func string() throws -> String {
      let begin = at
      guard at < bytes.count, bytes[at] == 34 else { throw CaptureProtocolError.invalidRequest }
      at += 1
      while at < bytes.count {
        let byte = bytes[at]
        at += 1
        if byte == 34 {
          do { return try JSONDecoder().decode(String.self, from: Data(bytes[begin..<at])) } catch {
            throw CaptureProtocolError.invalidRequest
          }
        }
        guard byte >= 32 else { throw CaptureProtocolError.invalidRequest }
        if byte == 92 {
          guard at < bytes.count else { throw CaptureProtocolError.invalidRequest }
          at += bytes[at] == 117 ? 5 : 1
        }
      }
      throw CaptureProtocolError.invalidRequest
    }
    whitespace()
    guard at < bytes.count, bytes[at] == 123 else { throw CaptureProtocolError.invalidRequest }
    at += 1
    var fields: [String: String] = [:]
    var strings = Set<String>()
    while true {
      whitespace()
      let key = try string()
      guard fields[key] == nil, fields.count < 5 else { throw CaptureProtocolError.invalidRequest }
      whitespace()
      guard at < bytes.count, bytes[at] == 58 else { throw CaptureProtocolError.invalidRequest }
      at += 1
      whitespace()
      guard at < bytes.count else { throw CaptureProtocolError.invalidRequest }
      if bytes[at] == 34 {
        fields[key] = try string()
        strings.insert(key)
      } else {
        let begin = at
        while at < bytes.count, bytes[at] >= 48, bytes[at] <= 57 { at += 1 }
        guard at > begin else { throw CaptureProtocolError.invalidRequest }
        fields[key] = String(decoding: bytes[begin..<at], as: UTF8.self)
      }
      whitespace()
      guard at < bytes.count else { throw CaptureProtocolError.invalidRequest }
      let end = bytes[at]
      at += 1
      if end == 125 { break }
      guard end == 44 else { throw CaptureProtocolError.invalidRequest }
    }
    whitespace()
    guard at == bytes.count,
      Set(fields.keys) == Set(["version", "command", "source", "generation", "receipt"]),
      strings == Set(["command", "generation", "receipt"]), fields["version"] == "1",
      fields["command"] == "wow-capture",
      let sourceText = fields["source"], let source = UInt32(sourceText), source > 0,
      String(source) == sourceText,
      let generation = fields["generation"], let generationValue = UInt64(generation),
      generationValue > 0, String(generationValue) == generation,
      let receipt = fields["receipt"], let receiptValue = UInt64(receipt), receiptValue > 0,
      String(receiptValue) == receipt
    else { throw CaptureProtocolError.invalidRequest }
    return Self(
      source: source, generation: generation, receipt: receipt, generationValue: generationValue,
      receiptValue: receiptValue)
  }
}
public enum CaptureStatus: String, Codable, Sendable {
  case permissionRequired = "permission-required"
  case gameNotVisible = "game-not-visible"
  case multipleGameWindows = "multiple-game-windows"
  case panelNotVisible = "panel-not-visible"
  case unavailable
}
public enum CaptureResponse: Sendable {
  case status(CaptureStatus)
  case frame(OpticalPanel.Decoded)
  public func encoded(for request: CaptureRequest) throws -> Data {
    struct Reply: Encodable {
      let version = 1, command = "wow-capture-result"
      let source: UInt32
      let generation: String
      let receipt: String
      let kind: String
      var status: CaptureStatus?
      var frameBase64: String?
      var atlasPNGBase64: String?
    }
    var reply = Reply(
      source: request.source, generation: request.generation, receipt: request.receipt,
      kind: "status")
    switch self {
    case .status(let status): reply.status = status
    case .frame(let panel):
      guard panel.frame.count == 512, panel.atlas.count <= 2 * 1024 * 1024 else {
        throw CaptureProtocolError.invalidReply
      }
      reply = Reply(
        source: request.source, generation: request.generation, receipt: request.receipt,
        kind: "frame", frameBase64: panel.frame.base64EncodedString(),
        atlasPNGBase64: panel.atlas.base64EncodedString())
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(reply)
    guard data.count <= CaptureRequest.maximumReplyBytes else {
      throw CaptureProtocolError.oversizedFrame
    }
    return data
  }
}
public enum CaptureFraming {
  public static func read(from input: FileHandle) throws -> Data? {
    func exact(_ size: Int, allowEOF: Bool) throws -> Data? {
      var bytes = Data()
      bytes.reserveCapacity(size)
      while bytes.count < size {
        let part = try input.read(upToCount: size - bytes.count) ?? Data()
        if part.isEmpty {
          if allowEOF && bytes.isEmpty { return nil }
          throw CaptureProtocolError.truncatedFrame
        }
        bytes.append(part)
      }
      return bytes
    }
    guard let header = try exact(4, allowEOF: true) else { return nil }
    let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    guard length > 0, length <= CaptureRequest.maximumBytes else {
      throw CaptureProtocolError.oversizedFrame
    }
    return try exact(Int(length), allowEOF: false)
  }
  public static func write(_ data: Data, to output: FileHandle) throws {
    guard !data.isEmpty, data.count <= CaptureRequest.maximumReplyBytes else {
      throw CaptureProtocolError.oversizedFrame
    }
    var length = UInt32(data.count).bigEndian
    try withUnsafeBytes(of: &length) { try output.write(contentsOf: Data($0)) }
    try output.write(contentsOf: data)
  }
}
