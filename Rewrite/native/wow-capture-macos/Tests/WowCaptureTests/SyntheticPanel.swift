import CoreGraphics
import Foundation
import ImageIO

enum SyntheticPanel {
  enum Invalid: Error { case fixture, image }
  static func frame(_ url: URL) throws -> Data {
    struct Fixture: Decodable { let frames: [String] }
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    guard let hex = fixture.frames.first, hex.count == 1024 else { throw Invalid.fixture }
    var bytes = Data()
    bytes.reserveCapacity(512)
    var at = hex.startIndex
    while at < hex.endIndex {
      let next = hex.index(at, offsetBy: 2)
      guard let byte = UInt8(hex[at..<next], radix: 16) else { throw Invalid.fixture }
      bytes.append(byte)
      at = next
    }
    return bytes
  }
  static func image(
    _ frame: Data, scale: Double = 1, originX: Int = 17, originY: Int = 23, width: Int = 1024,
    height: Int = 1100
  ) throws -> CGImage {
    let bytes = Array(frame)
    guard bytes.count == 512 else { throw Invalid.fixture }
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ color: [UInt8]) {
      for py
        in (originY + Int((y * scale).rounded(.down)))..<(originY
        + Int(((y + h) * scale).rounded(.down)))
      {
        for px
          in (originX + Int((x * scale).rounded(.down)))..<(originX
          + Int(((x + w) * scale).rounded(.down)))
        {
          guard px >= 0, py >= 0, px < width, py < height else { continue }
          let offset = (py * width + px) * 4
          pixels[offset] = color[0]
          pixels[offset + 1] = color[1]
          pixels[offset + 2] = color[2]
          pixels[offset + 3] = 255
        }
      }
    }
    for i in 0..<4 { rect(Double(i * 6), 0, 6, 6, i % 2 == 0 ? [0, 255, 255] : [255, 0, 255]) }
    for i in 0..<4 {
      rect(Double(240 + i * 4), 0, 4, 6, i % 2 == 0 ? [0, 255, 255] : [255, 0, 255])
    }
    for i in 0..<16 {
      let n = UInt8(i * 17)
      rect(Double(24 + i * 6), 0, 6, 6, [n, n, n])
    }
    for i in 0..<1024 {
      let n = (i % 2 == 0 ? bytes[i / 2] >> 4 : bytes[i / 2] & 15) * 17
      rect(Double(i % 64 * 3), Double(8 + i / 64 * 3), 3, 3, [n, n, n])
    }
    for i in 0..<64 {
      rect(Double(i % 8 * 32), Double(64 + i / 8 * 32), 32, 32, [UInt8(i), 120, 240])
    }
    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
      let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { throw Invalid.image }
    return image
  }
  static func decodedAtlas(_ png: Data) throws -> (CGImage, Data) {
    guard let source = CGImageSourceCreateWithData(png as CFData, nil),
      CGImageSourceGetCount(source) == 1,
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width == 256,
      image.height == 256
    else { throw Invalid.image }
    var bytes = Data(count: 256 * 256 * 4)
    let success = bytes.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 1024,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: 256, height: 256))
      return true
    }
    guard success else { throw Invalid.image }
    return (image, bytes)
  }
}
