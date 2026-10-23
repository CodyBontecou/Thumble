import Foundation
import UIKit
import XCTest

private enum BankHTTP {
  static func screenshot(_ port: Int, data: Data) async throws {
    guard data.count > 8 && data.count <= 2_097_152 else {
      throw NSError(domain: "bank_ui_image", code: 1)
    }
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/screenshot")!)
    request.httpMethod = "POST"
    request.httpBody = data
    request.timeoutInterval = 6
    let (_, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw NSError(domain: "bank_ui_image", code: 2)
    }
  }
  static func check(_ port: Int, _ path: String, key: String = "ok") async throws {
    guard try await request(port, path)[key] as? Bool == true else {
      throw NSError(domain: "bank_ui_http", code: 2)
    }
  }
  static func request(_ port: Int, _ path: String) async throws -> [String: Any] {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    request.timeoutInterval = 6
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 16_384,
      let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw NSError(domain: "bank_ui_http", code: 1) }
    return result
  }
}

/// Simulator tooling proof only: actual React/native clients and OS pointer routing.
/// The private XCTest event helper belongs exclusively to this UI-test runner.
@MainActor final class BankPresentationUITests: XCTestCase {
  private var captureFrame = CGRect.zero
  private func pixel(_ app: XCUIApplication, point: CGPoint, port: Int) async throws -> [Int] {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/capture")!)
    request.timeoutInterval = 6
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 2_097_152 else {
      throw NSError(domain: "bank_capture", code: 1)
    }
    let image = try XCTUnwrap(UIImage(data: data)?.cgImage)
    let width = image.width
    let height = image.height
    print(
      "bank_pixel_geometry width=\(width) height=\(height) appWidth=\(captureFrame.width) appHeight=\(captureFrame.height)"
    )
    XCTAssertTrue(width <= 4096 && height <= 4096)
    let x = Int(point.x / captureFrame.width * Double(width))
    let y = Int(point.y / captureFrame.height * Double(height))
    XCTAssertTrue((0..<width).contains(x) && (0..<height).contains(y))
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    try rgba.withUnsafeMutableBytes { bytes in
      let context = try XCTUnwrap(
        CGContext(
          data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    let at = (y * width + x) * 4
    return rgba[at..<at + 3].map(Int.init)
  }

  private func expectedPixel(bank: Int, refreshed: Bool, held: Bool, dark: Bool) -> [Int] {
    precondition((0..<4).contains(bank))
    // The actual transparent native touch portal composites its accepted-state highlight
    // over the React Image. Verify that visible composite, not a detached image draw.
    let highlight = UIColor.systemBlue.resolvedColor(
      with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
    var r: CGFloat = 0
    var g: CGFloat = 0
    var b: CGFloat = 0
    highlight.getRed(&r, green: &g, blue: &b, alpha: nil)
    let red = (bank + (dark ? 4 : 0) + (refreshed ? 8 : 0)) * 16
    let rawValues: [Int] = [red, 64, 255 - red]
    let tints: [Double] = [Double(r), Double(g), Double(b)]
    var expected = rawValues
    if held {
      for index in 0..<3 {
        let mixed = Double(rawValues[index]) * 0.7 + tints[index] * 76.5
        expected[index] = Int(mixed.rounded())
      }
    }
    return expected
  }

  private func assertPaletteDiscrimination() {
    var states = [[Int]]()
    for refreshed in [false, true] {
      for dark in [false, true] {
        for held in [false, true] {
          for bank in 0..<4 {
            states.append(expectedPixel(bank: bank, refreshed: refreshed, held: held, dark: dark))
          }
        }
      }
    }
    for a in states.indices {
      for b in states.indices where b > a {
        let distance = zip(states[a], states[b]).map { abs($0 - $1) }.max()!
        // With tolerance five, integer RGB boxes are disjoint iff at least one
        // channel differs by more than ten. Resolve actual UIKit tint at runtime.
        XCTAssertGreaterThan(distance, 10, "bank_palette_tolerance_boxes_overlap")
      }
    }
  }

  private func color(
    _ app: XCUIApplication, point: CGPoint, port: Int, bank: Int, refreshed: Bool = false,
    held: Bool, dark: Bool
  ) async throws {
    let expected = expectedPixel(bank: bank, refreshed: refreshed, held: held, dark: dark)
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    var observed = [Int]()
    repeat {
      observed = try await pixel(app, point: point, port: port)
      if zip(observed, expected).allSatisfy({ abs($0 - $1) <= 5 }) { return }
      try await Task.sleep(for: .milliseconds(100))
    } while ContinuousClock.now < deadline
    XCTFail("bank_visible_pixel_mismatch expected=\(expected) observed=\(observed)")
    throw NSError(domain: "bank_ui_pixel", code: 1)
  }

  func testActualReactModifierBankArtworkAndAppearanceRefresh() async throws {
    assertPaletteDiscrimination()
    let configURL = try XCTUnwrap(
      Bundle(for: Self.self).url(
        forResource: "SavedControllerAppProbeConfig", withExtension: "json"))
    let config = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any])
    let port = try XCTUnwrap(config["port"] as? Int)
    XCTAssertTrue((1...65535).contains(port) && config["mode"] as? String == "bank-presentation")
    let app = XCUIApplication()
    XCUIDevice.shared.orientation = .landscapeLeft
    app.launch()
    defer {
      app.terminate()
      XCUIDevice.shared.orientation = .portrait
    }
    let home = app.descendants(matching: .any)["home-connect"].firstMatch
    XCTAssertTrue(home.waitForExistence(timeout: 20))
    home.tap()
    print("bank_ui phase=invitation")
    let invitation = try await BankHTTP.request(port, "/begin")
    let text = String(
      data: try JSONSerialization.data(withJSONObject: invitation), encoding: .utf8)!
    let field = app.secureTextFields["pairing-invitation"]
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    field.tap()
    field.typeText(text)
    XCTAssertNotEqual(field.value as? String, "Pairing invitation", "bank_invitation_entry_empty")
    field.typeText("\n")
    let pair = app.alerts.buttons["Pair"]
    XCTAssertTrue(pair.waitForExistence(timeout: 10))
    pair.tap()
    print("bank_ui phase=admission")
    XCTAssertTrue(app.staticTexts["connection-ready"].waitForExistence(timeout: 20))
    let surface = app.descendants(matching: .any)["controller-surface"].firstMatch
    let done = app.buttons["connection-done"]
    XCTAssertTrue(surface.exists && done.exists)
    let bounds = surface.frame
    XCTAssertGreaterThanOrEqual(bounds.height, 240)
    XCTAssertLessThanOrEqual(done.frame.maxY, bounds.minY + 1)
    let south = CGPoint(x: bounds.midX, y: bounds.midY)
    let left = CGPoint(x: bounds.minX + bounds.width * 0.37, y: bounds.minY + bounds.height * 0.43)
    let right = CGPoint(x: bounds.minX + bounds.width * 0.63, y: left.y)
    for (name, center) in [("Left trigger", left), ("Right trigger", right)] {
      let label = app.staticTexts[name].firstMatch
      XCTAssertTrue(label.waitForExistence(timeout: 5))
      XCTAssertEqual(label.frame.midX, center.x, accuracy: 2)
      XCTAssertEqual(label.frame.midY, center.y, accuracy: 2)
    }
    captureFrame = app.frame
    print("bank_ui phase=base-pixel")
    try await color(app, point: south, port: port, bank: 0, held: false, dark: false)
    let origin = app.coordinate(withNormalizedOffset: .zero)
    let points = [
      south, left, right,
      CGPoint(x: left.x, y: bounds.minY + bounds.height * 0.25),
      CGPoint(x: right.x, y: bounds.minY + bounds.height * 0.25),
      CGPoint(x: left.x, y: bounds.minY + bounds.height * 0.65),
      CGPoint(x: right.x, y: bounds.minY + bounds.height * 0.65),
    ]
    XCTAssertTrue(points.allSatisfy { bounds.contains($0) })
    let screenPoints = points.map { origin.withOffset(CGVector(dx: $0.x, dy: $0.y)).screenPoint }
    let signal = AsyncStream<ContinuousClock.Instant>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
    let observations = Task {
      var iterator = signal.stream.makeAsyncIterator()
      guard let started = await iterator.next() else {
        throw NSError(domain: "bank_gesture_start", code: 1)
      }
      func at(_ seconds: Int) async throws {
        try await ContinuousClock().sleep(until: started.advanced(by: .seconds(seconds)))
      }
      try await at(3)
      try await color(app, point: south, port: port, bank: 1, held: true, dark: false)
      try await at(8)
      try await color(app, point: south, port: port, bank: 3, held: true, dark: false)
      try await at(13)
      try await color(app, point: south, port: port, bank: 2, held: true, dark: false)
      try await at(19)
      try await color(app, point: south, port: port, bank: 0, held: true, dark: false)
      try await at(24)
      try await color(app, point: south, port: port, bank: 1, held: true, dark: false)
      try await at(29)
      try await color(app, point: south, port: port, bank: 3, held: true, dark: false)
      try await BankHTTP.check(port, "/dark", key: "dark")
      try await at(32)
      try await color(app, point: south, port: port, bank: 3, held: true, dark: true)
      try await BankHTTP.check(port, "/bank-hold-start", key: "watching")
      try await BankHTTP.check(port, "/refresh", key: "refreshed")
      try await at(36)
      try await color(
        app, point: south, port: port, bank: 3, refreshed: true, held: true, dark: true)
      try await at(38)
      try await BankHTTP.check(port, "/bank-held", key: "bankHeld")
      // Do not enqueue AX or XCTest screenshot queries behind the active long gesture.
      var captureRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/capture")!)
      captureRequest.timeoutInterval = 6
      let (captureData, captureResponse) = try await URLSession.shared.data(for: captureRequest)
      XCTAssertEqual((captureResponse as? HTTPURLResponse)?.statusCode, 200)
      try await BankHTTP.screenshot(port, data: captureData)
      try await at(42)
      try await color(
        app, point: south, port: port, bank: 1, refreshed: true, held: true, dark: true)
      try await at(46)
      try await color(
        app, point: south, port: port, bank: 0, refreshed: true, held: true, dark: true)
      try await at(49)
      try await color(
        app, point: south, port: port, bank: 2, refreshed: true, held: true, dark: true)
      try await at(55)
      try await color(
        app, point: south, port: port, bank: 3, refreshed: true, held: true, dark: true)
      try await at(60)
      try await color(
        app, point: south, port: port, bank: 0, refreshed: true, held: true, dark: true)
    }
    defer {
      signal.continuation.finish()
      observations.cancel()
    }
    print("bank_ui phase=gesture")
    let injected = await withCheckedContinuation { continuation in
      ThumbleBankPresentationGesture(
        app, screenPoints.map { NSValue(cgPoint: $0) },
        {
          signal.continuation.yield(ContinuousClock.now)
          signal.continuation.finish()
        }
      ) { ok in
        signal.continuation.finish()
        continuation.resume(returning: ok)
      }
    }
    XCTAssertTrue(injected, "bank_xctest_three_pointer_runtime_unavailable_or_failed")
    try await observations.value
    XCTAssertTrue(app.staticTexts["connection-ready"].exists)
    done.tap()
    XCTAssertTrue(home.waitForExistence(timeout: 10))
    try await BankHTTP.check(port, "/neutral", key: "neutral")
    try await BankHTTP.check(port, "/finish", key: "completed")
  }
}
