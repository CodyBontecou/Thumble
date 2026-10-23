import Foundation
import zlib

/// Strict 32-square RGB/RGBA PNG validation. No image process, capture or OS input access.
enum PhonePresentationPNG {
  static func verify(_ data: Data) throws {
    func reject() throws -> Never { throw PhonePresentationError.rejected }
    let bytes = [UInt8](data)
    guard (57...8192).contains(bytes.count),
      Array(bytes.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10]
    else { try reject() }
    func word(_ at: Int) -> UInt32 {
      bytes[at..<at + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    var at = 8
    var chunks = 0
    var channels = 0
    var header = false
    var image = false
    var imageEnded = false
    var ended = false
    var palette = false
    var transparency = false
    var compressed = Data()
    while at < bytes.count {
      chunks += 1
      guard chunks <= 64, at + 12 <= bytes.count else { try reject() }
      let size = Int(word(at))
      let end = at + size + 12
      guard end <= bytes.count else { try reject() }
      let name = Array(bytes[at + 4..<at + 8])
      guard name.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }),
        (65...90).contains(name[2])
      else { try reject() }
      let crc = bytes.withUnsafeBufferPointer {
        crc32(0, $0.baseAddress!.advanced(by: at + 4), uInt(size + 4))
      }
      guard UInt32(truncatingIfNeeded: crc) == word(at + size + 8) else { try reject() }
      let type = String(decoding: name, as: UTF8.self)
      if !header {
        guard type == "IHDR", size == 13, word(at + 8) == 32, word(at + 12) == 32,
          bytes[at + 16] == 8, [2, 6].contains(bytes[at + 17]),
          bytes[at + 18] == 0, bytes[at + 19] == 0, bytes[at + 20] == 0
        else { try reject() }
        channels = bytes[at + 17] == 6 ? 4 : 3
        header = true
      } else if ["IHDR", "acTL", "fcTL", "fdAT", "iCCP", "zTXt", "iTXt"].contains(type) {
        try reject()
      } else if type == "IDAT" {
        guard !imageEnded else { try reject() }
        image = true
        compressed.append(contentsOf: bytes[at + 8..<at + 8 + size])
      } else if type == "IEND" {
        guard size == 0, image, end == bytes.count else { try reject() }
        ended = true
      } else {
        if image { imageEnded = true }
        if type == "PLTE" {
          guard !image, !palette, size > 0, size <= 768, size % 3 == 0 else { try reject() }
          palette = true
        } else if type == "tRNS" {
          guard !image, !transparency, channels == 3, size == 6,
            [0, 2, 4].allSatisfy({ bytes[at + 8 + $0] == 0 })
          else { try reject() }
          transparency = true
        } else if (65...90).contains(name[0]) {
          try reject()
        }
      }
      at = end
    }
    guard ended else { try reject() }
    let stride = 32 * channels + 1
    let expected = 32 * stride
    var output = [UInt8](repeating: 0, count: expected)
    var outputSize = uLong(expected)
    var inputSize = uLong(compressed.count)
    let result = output.withUnsafeMutableBufferPointer { destination in
      compressed.withUnsafeBytes { source in
        uncompress2(
          destination.baseAddress, &outputSize,
          source.bindMemory(to: UInt8.self).baseAddress, &inputSize)
      }
    }
    guard result == Z_OK, outputSize == expected, inputSize == compressed.count,
      (0..<32).allSatisfy({ output[$0 * stride] <= 4 })
    else { try reject() }
  }
}
