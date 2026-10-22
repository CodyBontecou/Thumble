import CoreGraphics
import CryptoKit
import Foundation
import Testing

@testable import WowCaptureMac

private func fixtureURL(_ name: String) throws -> URL {
  try #require(
    Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
}
private func frame() throws -> Data { try SyntheticPanel.frame(fixtureURL("wow-live-v1")) }
private func request(source: UInt32 = 42, generation: String = "1", receipt: String = "1") throws
  -> CaptureRequest
{
  try CaptureRequest.decode(
    Data(
      "{\"version\":1,\"command\":\"wow-capture\",\"source\":\(source),\"generation\":\"\(generation)\",\"receipt\":\"\(receipt)\"}"
        .utf8))
}
private func identity(
  window: UInt32 = 19, pid: Int32 = 7, start: UInt64 = 10, inode: UInt64 = 12, scale: Double = 1,
  width: Int = 1024
) -> WindowIdentity {
  WindowIdentity(
    window: window,
    process: ProcessIdentity(
      pid: pid, startSeconds: start, startMicroseconds: 20,
      executable: "/Synthetic/_forever_/World of Warcraft", device: 1, inode: inode, size: 100,
      modifiedSeconds: 50, modifiedNanoseconds: 3, changedSeconds: 51, changedNanoseconds: 4),
    x: 17, y: 23, width: Double(width), height: 1100, contentWidth: Double(width),
    contentHeight: 1100, scale: scale, pixelWidth: width, pixelHeight: 1100)
}
private func status(_ response: CaptureResponse) -> CaptureStatus? {
  if case .status(let status) = response { return status }
  return nil
}

@Test(arguments: [0.75, 0.853, 1, 1.1, 1.28, 1.5, 1.6, 2, 2.557, 3])
func retainedDecoderParityAtTenScales(_ scale: Double) throws {
  struct Oracle: Decodable {
    struct Entry: Decodable {
      let scale: Double
      let rgbaSha256: String
    }
    let frameSha256: String
    let scales: [Entry]
  }
  let oracle = try JSONDecoder().decode(
    Oracle.self, from: Data(contentsOf: fixtureURL("optical-retained-checksums-v1")))
  let bytes = try frame()
  let decoded = try #require(try OpticalPanel.decode(SyntheticPanel.image(bytes, scale: scale)))
  #expect(decoded.frame == bytes)
  #expect(
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == oracle.frameSha256)
  let (image, pixels) = try SyntheticPanel.decodedAtlas(decoded.atlas)
  #expect(image.width == 256 && image.height == 256 && decoded.atlas.count <= 2 * 1024 * 1024)
  let expected = try #require(oracle.scales.first { $0.scale == scale })
  #expect(
    SHA256.hash(data: pixels).map { String(format: "%02x", $0) }.joined() == expected.rgbaSha256)
  for (x, y, n) in [(0, 0, 0), (255, 0, 7), (0, 255, 56), (255, 255, 63)] {
    let i = (y * 256 + x) * 4
    #expect(Array(pixels[i..<(i + 4)]) == [UInt8(n), 120, 240, 255])
  }
  // This PNG must fit the strict portable receipt's noninterlaced RGB/RGBA8 subset.
  #expect(Array(decoded.atlas.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
  #expect(decoded.atlas[24] == 8 && [2, 6].contains(decoded.atlas[25]) && decoded.atlas[28] == 0)
}
@Test func corruptionClippingDiscoveryAndAllocationBounds() throws {
  var corrupt = try frame()
  corrupt[100] ^= 1
  #expect(!OpticalPanel.validFrame(corrupt))
  #expect(try OpticalPanel.decode(SyntheticPanel.image(corrupt)) == nil)
  #expect(try OpticalPanel.decode(SyntheticPanel.image(frame(), originX: 600)) == nil)
  #expect(try OpticalPanel.decode(SyntheticPanel.image(frame(), width: 200, height: 400)) == nil)
  let data = Data(count: 8193 * 4)
  let provider = try #require(CGDataProvider(data: data as CFData))
  let oversized = try #require(
    CGImage(
      width: 8193, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8193 * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
  #expect(throws: OpticalPanel.CaptureError.self) { try OpticalPanel.decode(oversized) }
}
@Test func fixedSampleWorkBudget() throws {
  let width = 8192
  let height = 64
  var pixels = [UInt8](repeating: 0, count: width * height * 4)
  for y in stride(from: 0, to: height, by: 2) {
    for marker in 0..<4 {
      for x in (17 + marker * 6)..<(17 + (marker + 1) * 6) {
        let i = (y * width + x) * 4
        pixels[i] = marker % 2 == 0 ? 0 : 255
        pixels[i + 1] = marker % 2 == 0 ? 255 : 0
        pixels[i + 2] = 255
        pixels[i + 3] = 255
      }
    }
    for x in 200..<width {
      let i = (y * width + x) * 4
      pixels[i] = 0
      pixels[i + 1] = 255
      pixels[i + 2] = 255
      pixels[i + 3] = 255
    }
  }
  let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
  let image = try #require(
    CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
  #expect(throws: OpticalPanel.CaptureError.scanLimit) { try OpticalPanel.decode(image) }
}
@Test func strictRequestsAndExactCorrelatedPrivateFreeReplies() throws {
  let r = try request(
    source: UInt32.max, generation: "18446744073709551615", receipt: "18446744073709551615")
  #expect(r.source == UInt32.max && r.receiptValue == UInt64.max)
  let base =
    "{\"version\":1,\"command\":\"wow-capture\",\"source\":42,\"generation\":\"1\",\"receipt\":\"1\"}"
  for text in [
    base.replacingOccurrences(of: "\"source\":42", with: "\"source\":42,\"\\u0073ource\":42"),
    base.replacingOccurrences(of: "\"receipt\":\"1\"", with: "\"receipt\":\"01\""),
    base.replacingOccurrences(
      of: "\"generation\":\"1\"", with: "\"generation\":\"18446744073709551616\""),
    base.replacingOccurrences(of: "\"source\":42", with: "\"source\":0"),
    base.replacingOccurrences(of: "\"source\":42", with: "\"source\":4294967296"),
    base.replacingOccurrences(of: "\"source\":42", with: "\"source\":\"42\""),
    base.replacingOccurrences(of: "\"source\":42", with: "\"source\":{\"id\":42}"),
    base.replacingOccurrences(of: "\"source\":42", with: "\"source\":42,\"windowID\":99"),
    String(repeating: " ", count: 257),
  ] {
    #expect(throws: (any Error).self) { try CaptureRequest.decode(Data(text.utf8)) }
  }
  let panel = try #require(try OpticalPanel.decode(SyntheticPanel.image(frame())))
  let reply = try CaptureResponse.frame(panel).encoded(for: r)
  let value = try #require(JSONSerialization.jsonObject(with: reply) as? [String: Any])
  #expect(
    Set(value.keys)
      == Set([
        "version", "command", "source", "generation", "receipt", "kind", "frameBase64",
        "atlasPNGBase64",
      ]))
  #expect(
    value["generation"] as? String == r.generation && value["receipt"] as? String == r.receipt)
  #expect(Data(base64Encoded: try #require(value["frameBase64"] as? String)) == panel.frame)
  #expect(Data(base64Encoded: try #require(value["atlasPNGBase64"] as? String)) == panel.atlas)
  #expect(throws: CaptureProtocolError.self) {
    try CaptureResponse.frame(
      .init(frame: Data(count: 512), atlas: Data(count: 2 * 1024 * 1024 + 1))
    ).encoded(for: r)
  }
}
@Test func lengthFramingRejectsBeforePayloadAllocationAndDetectsTruncation() throws {
  for payload in [Data([0, 0]), Data([0, 0, 0, 4, 1, 2]), Data([255, 255, 255, 255])] {
    let pipe = Pipe()
    try pipe.fileHandleForWriting.write(contentsOf: payload)
    try pipe.fileHandleForWriting.close()
    #expect(throws: CaptureProtocolError.self) {
      try CaptureFraming.read(from: pipe.fileHandleForReading)
    }
    try pipe.fileHandleForReading.close()
  }
  let pipe = Pipe()
  let data = try CaptureResponse.status(.permissionRequired).encoded(for: request())
  try CaptureFraming.write(data, to: pipe.fileHandleForWriting)
  try pipe.fileHandleForWriting.close()
  // Reply parser is intentionally request-sized; inspect header without using the request reader.
  let bytes = try pipe.fileHandleForReading.readToEnd() ?? Data()
  #expect(bytes.count == data.count + 4)
  #expect(bytes.dropFirst(4) == data)
  try pipe.fileHandleForReading.close()
}
@Test @MainActor func permissionAndAmbiguityDoNotCapture() async throws {
  var enumerations = 0
  var captures = 0
  let image = try SyntheticPanel.image(frame())
  let candidate = CaptureCandidate(
    identity: identity(),
    image: {
      captures += 1
      return image
    })
  let denied = CaptureSession(
    environment: .init(
      permitted: { false },
      windows: {
        enumerations += 1
        return [candidate]
      }))
  #expect(status(await denied.perform(try request())) == .permissionRequired)
  #expect(enumerations == 0 && captures == 0)
  let missing = CaptureSession(environment: .init(permitted: { true }, windows: { [] }))
  #expect(status(await missing.perform(try request())) == .gameNotVisible)
  let multiple = CaptureSession(
    environment: .init(permitted: { true }, windows: { [candidate, candidate] }))
  #expect(status(await multiple.perform(try request())) == .multipleGameWindows)
  #expect(captures == 0)
}
@Test(arguments: ["pid", "start", "inode", "window", "scale", "resize", "multiple", "missing"])
@MainActor func postAwaitIdentityChangesLatchUnavailable(_ change: String) async throws {
  let image = try SyntheticPanel.image(frame())
  let original = identity()
  let changed = identity(
    window: change == "window" ? 20 : 19, pid: change == "pid" ? 8 : 7,
    start: change == "start" ? 11 : 10, inode: change == "inode" ? 13 : 12,
    scale: change == "scale" ? 2 : 1, width: change == "resize" ? 1025 : 1024)
  var reads = 0
  let session = CaptureSession(
    environment: .init(
      permitted: { true },
      windows: {
        reads += 1
        let first = CaptureCandidate(identity: original, image: { image })
        if reads == 1 { return [first] }
        if change == "missing" { return [] }
        if change == "multiple" { return [first, first] }
        return [.init(identity: changed, image: { image })]
      }))
  #expect(status(await session.perform(try request())) == .unavailable)
  #expect(status(await session.perform(try request(receipt: "2"))) == .unavailable)
  #expect(reads == 2)
}
@Test @MainActor func sequentialIdentityReceiptAndSourceBarriers() async throws {
  let image = try SyntheticPanel.image(frame())
  var reads = 0
  let session = CaptureSession(
    environment: .init(
      permitted: { true },
      windows: {
        reads += 1
        return [.init(identity: identity(), image: { image })]
      }))
  #expect(status(await session.perform(try request())) == nil)
  #expect(status(await session.perform(try request())) == .unavailable)
  #expect(reads == 2)
  #expect(status(await session.perform(try request(source: 43, receipt: "2"))) == .unavailable)
  #expect(status(await session.perform(try request(receipt: "3"))) == .unavailable)
  #expect(reads == 2)
}
@Test func eligibleGamePolicyRejectsRetailOtherAppsLayersAndInvalidGeometry() {
  #expect(
    GameWindowPolicy.accepts(
      bundle: "com.blizzard.worldofwarcraft", executable: "/Games/_forever_/WoW", layer: 0,
      width: 320, height: 320))
  #expect(
    GameWindowPolicy.accepts(
      bundle: "com.blizzard.worldofwarcraft", executable: "/Games/_classic_era_/WoW", layer: 0,
      width: 320, height: 320))
  for path in ["/Games/_retail_/WoW", "/Games/_forever_alias/WoW", "_forever_/WoW"] {
    #expect(
      !GameWindowPolicy.accepts(
        bundle: "com.blizzard.worldofwarcraft", executable: path, layer: 0, width: 320, height: 320)
    )
  }
  #expect(
    !GameWindowPolicy.accepts(
      bundle: "other", executable: "/Games/_forever_/WoW", layer: 0, width: 320, height: 320))
  #expect(
    !GameWindowPolicy.accepts(
      bundle: "com.blizzard.worldofwarcraft", executable: "/Games/_forever_/WoW", layer: 1,
      width: 320, height: 320))
  #expect(
    !GameWindowPolicy.accepts(
      bundle: "com.blizzard.worldofwarcraft", executable: "/Games/_forever_/WoW", layer: 0,
      width: .infinity, height: 320))
  #expect(MemoryLayout<CaptureRequest>.size <= 96)
}

@Test(arguments: [false, true])
@MainActor func pendingCaptureCannotPublishAfterCancellationOrContextReplacement(_ replace: Bool)
  async throws
{
  let image = try SyntheticPanel.image(frame())
  let (started, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
  var completion: CheckedContinuation<CGImage, Never>?
  let session = CaptureSession(
    environment: .init(
      permitted: { true },
      windows: {
        [
          .init(
            identity: identity(),
            image: {
              await withCheckedContinuation { continuation in
                completion = continuation
                signal.yield(())
              }
            })
        ]
      }))
  let original = try request()
  let pending = Task { await session.perform(original) }
  for await _ in started { break }
  let finish = try #require(completion)
  if replace {
    #expect(status(await session.perform(try request(source: 43, receipt: "2"))) == .unavailable)
  } else {
    pending.cancel()
  }
  finish.resume(returning: image)
  #expect(status(await pending.value) == .unavailable)
  signal.finish()
}
