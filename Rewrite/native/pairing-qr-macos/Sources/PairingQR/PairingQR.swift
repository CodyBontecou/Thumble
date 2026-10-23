import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum PairingQRError: Error { case invalidInvitation, renderingFailed }

private struct Invitation: Codable {
  let authorityInstanceId: String
  let certificatePin: String
  let expiresAt: UInt64
  let host: String
  let port: UInt16
  let secret: String
  let windowId: String
}

public enum PairingQR {
  public static let maximumInputBytes = 4096
  public static let maximumPNGBytes = 1024 * 1024
  /// Canonical encoding rejects duplicate/unknown keys and alternate number/string
  /// spellings. The invitation remains opaque enrollment data, never a URI.
  public static func validate(_ data: Data) throws {
    guard !data.isEmpty, data.count <= maximumInputBytes,
      data.allSatisfy({ $0 >= 0x20 && $0 <= 0x7e }),
      let value = try? JSONDecoder().decode(Invitation.self, from: data),
      value.port > 0, value.expiresAt > 0, value.expiresAt <= 9_007_199_254_740_991,
      matches(value.authorityInstanceId, "^[A-Za-z0-9-]{1,64}$"),
      matches(value.windowId, "^[A-Za-z0-9-]{1,64}$"),
      matches(value.secret, "^[0-9a-f]{64}$"), matches(value.certificatePin, "^[0-9a-f]{64}$"),
      matches(value.host, "^[A-Za-z0-9.:-]{1,253}$"), !["0.0.0.0", "::"].contains(value.host)
    else { throw PairingQRError.invalidInvitation }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let canonical = try? encoder.encode(value), canonical == data else {
      throw PairingQRError.invalidInvitation
    }
  }
  private static func matches(_ value: String, _ regex: String) -> Bool {
    value.range(of: regex, options: .regularExpression) != nil
  }
  /// CoreImage generation follows the retained renderer; an explicit four-module
  /// white quiet zone and integer scaling avoid interpolated/borderless output.
  public static func render(_ data: Data) throws -> Data {
    try validate(data)
    let filter = CIFilter.qrCodeGenerator()
    filter.message = data
    filter.correctionLevel = "M"
    guard let image = filter.outputImage,
      image.extent.width == image.extent.height,
      image.extent.width >= 21, image.extent.width <= 177,
      image.extent.width.rounded() == image.extent.width
    else {
      throw PairingQRError.renderingFailed
    }
    let modules = Int(image.extent.width)
    let quiet = 4
    let scale = 8
    let dimension = (modules + 2 * quiet) * scale
    guard dimension <= 2048,
      let raw = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(
        image, from: image.extent),
      let context = CGContext(
        data: nil, width: dimension, height: dimension,
        bitsPerComponent: 8, bytesPerRow: dimension * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw PairingQRError.renderingFailed }
    context.interpolationQuality = .none
    context.setShouldAntialias(false)
    context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: dimension, height: dimension))
    context.draw(
      raw,
      in: CGRect(
        x: quiet * scale, y: quiet * scale, width: modules * scale, height: modules * scale))
    guard let output = context.makeImage() else { throw PairingQRError.renderingFailed }
    let bytes = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        bytes, UTType.png.identifier as CFString, 1, nil)
    else { throw PairingQRError.renderingFailed }
    CGImageDestinationAddImage(destination, output, nil)
    guard CGImageDestinationFinalize(destination), bytes.length <= maximumPNGBytes else {
      throw PairingQRError.renderingFailed
    }
    return bytes as Data
  }
}
