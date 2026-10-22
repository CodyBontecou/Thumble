// Synthetic/local test witness only. No camera, permissions or native output.
import Foundation
import ImageIO
import Vision

func check() throws {
  guard CommandLine.arguments.count == 2 else { throw CocoaError(.fileReadCorruptFile) }
  let expected = FileHandle.standardInput.readDataToEndOfFile()
  guard expected.count <= 4096, let expectedText = String(data: expected, encoding: .utf8) else {
    throw CocoaError(.fileReadCorruptFile)
  }
  let url = URL(fileURLWithPath: CommandLine.arguments[1])
  let png = try Data(contentsOf: url)
  guard png.count <= 1024 * 1024, let source = CGImageSourceCreateWithData(png as CFData, nil),
    let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
    let width = props[kCGImagePropertyPixelWidth as String] as? Int,
    let height = props[kCGImagePropertyPixelHeight as String] as? Int,
    width == height, width <= 2048, width >= 232,
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
  else { throw CocoaError(.fileReadCorruptFile) }
  let request = VNDetectBarcodesRequest()
  request.symbologies = [.qr]
  try VNImageRequestHandler(cgImage: image).perform([request])
  guard request.results?.count == 1, request.results?.first?.payloadStringValue == expectedText
  else { throw CocoaError(.fileReadCorruptFile) }
  print("qr_verified")
}
do { try check() } catch {
  fputs("qr_verification_failed\n", stderr)
  exit(1)
}
