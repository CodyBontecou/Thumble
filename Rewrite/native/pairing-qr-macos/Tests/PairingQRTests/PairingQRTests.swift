import Foundation
import ImageIO
import PairingQR
import Vision
import XCTest

final class PairingQRTests: XCTestCase {
  private func invitation(host: String = "192.0.2.10") -> Data {
    Data(
      "{\"authorityInstanceId\":\"synthetic-authority\",\"certificatePin\":\"\(String(repeating: "a", count: 64))\",\"expiresAt\":9007199254740991,\"host\":\"\(host)\",\"port\":65535,\"secret\":\"\(String(repeating: "b", count: 64))\",\"windowId\":\"synthetic-window\"}"
        .utf8)
  }
  func testVisionRoundtripExactOfferWithQuietZoneAndIntegerPixels() throws {
    for host in ["192.0.2.10", "2001:db8::1", String(repeating: "a", count: 249) + ".com"] {
      let payload = invitation(host: host)
      let png = try PairingQR.render(payload)
      XCTAssertLessThanOrEqual(png.count, PairingQR.maximumPNGBytes)
      let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
      let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
      XCTAssertEqual(image.width, image.height)
      XCTAssertLessThanOrEqual(image.width, 2048)
      XCTAssertEqual(image.width % 8, 0)
      let request = VNDetectBarcodesRequest()
      request.symbologies = [.qr]
      try VNImageRequestHandler(cgImage: image).perform([request])
      XCTAssertEqual(request.results?.count, 1)
      XCTAssertEqual(
        request.results?.first?.payloadStringValue, String(data: payload, encoding: .utf8))
      // White border is physically encoded in PNG, independent of display styling.
      let pixel = try XCTUnwrap(image.dataProvider?.data)
      let bytes = try XCTUnwrap(CFDataGetBytePtr(pixel))
      for y in [0, 15, 31, image.height - 1] {
        for x in 0..<image.width {
          let index = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
          XCTAssertEqual(bytes[index], 255)
          XCTAssertEqual(bytes[index + 1], 255)
          XCTAssertEqual(bytes[index + 2], 255)
        }
      }
    }
  }
  func testMalformedUnknownDuplicateAndUnboundedPayloadsRejected() {
    let valid = String(decoding: invitation(), as: UTF8.self)
    for value in [
      "", "{}", valid + " ", valid.replacingOccurrences(of: "65535", with: "0"),
      valid.replacingOccurrences(of: "9007199254740991", with: "9007199254740992"),
      valid.replacingOccurrences(of: "192.0.2.10", with: "0.0.0.0"),
      valid.replacingOccurrences(of: "{", with: "{\"extra\":true,"),
      valid.replacingOccurrences(of: "{", with: "{\"port\":1,"),
      String(repeating: "a", count: 4097),
    ] {
      XCTAssertThrowsError(try PairingQR.render(Data(value.utf8)))
    }
  }
}
