import Foundation
import UIKit
import XCTest

private enum SavedAppHTTP {
  static func request(port: Int, path: String) async throws -> Data {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    request.timeoutInterval = 6
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 16_384 else {
      throw NSError(domain: "saved_app_http", code: 1)
    }
    return data
  }
  static func check(port: Int, path: String) async throws {
    let value =
      try JSONSerialization.jsonObject(with: await request(port: port, path: path))
      as? [String: Any]
    guard value?["ok"] as? Bool == true else { throw NSError(domain: "saved_app_http", code: 2) }
  }
}

/// Actual React route and production native map admission, using the app's real Keychain.
/// Raw UI logs/xcresult are private because typing the synthetic invitation can be recorded.
@MainActor final class SavedControllerUITests: XCTestCase {
  func testActualReactSavedMapSummaryCornerAndDismissal() async throws {
    let url = try XCTUnwrap(
      Bundle(for: Self.self).url(
        forResource: "SavedControllerAppProbeConfig", withExtension: "json"))
    let config = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let port = try XCTUnwrap(config["port"] as? Int)
    let mode = try XCTUnwrap(config["mode"] as? String)
    XCTAssertTrue((1...65535).contains(port) && ["corner", "unsupported"].contains(mode))
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
    let invitation = try await SavedAppHTTP.request(port: port, path: "/begin")
    let text = try XCTUnwrap(String(data: invitation, encoding: .utf8))
    let field = app.secureTextFields["pairing-invitation"]
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    let enabled = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == true"), object: field)
    XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed)
    // Exercise the product's intended native Paste flow instead of spending the
    // test budget switching software-keyboard layouts for each JSON character.
    UIPasteboard.general.setItems(
      [[UIPasteboard.typeAutomatic: text]],
      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)])
    defer { if UIPasteboard.general.string == text { UIPasteboard.general.items = [] } }
    field.tap()
    field.typeKey("v", modifierFlags: .command)
    field.typeText("\n")
    let pair = app.alerts.buttons["Pair"]
    guard pair.waitForExistence(timeout: 10) else {
      let hierarchy = XCTAttachment(string: app.debugDescription)
      hierarchy.name = "private-post-keyboard-hierarchy"
      hierarchy.lifetime = .keepAlways
      add(hierarchy)
      XCTFail("Pair action was unavailable after keyboard dismissal")
      throw NSError(domain: "saved_app_ui", code: 2)
    }
    pair.tap()
    let done = app.buttons["connection-done"]
    XCTAssertTrue(done.waitForExistence(timeout: 10))
    if mode == "unsupported" {
      let error = app.staticTexts[
        "Ask your agent to start the receiver and open pairing, then try again."]
      XCTAssertTrue(error.waitForExistence(timeout: 20))
      XCTAssertFalse(app.staticTexts["A"].exists)
      XCTAssertFalse(app.staticTexts["saved-profile-summary"].exists)
      done.tap()
      XCTAssertTrue(home.waitForExistence(timeout: 10))
      try await SavedAppHTTP.check(port: port, path: "/finish")
      return
    }
    guard app.staticTexts["connection-ready"].waitForExistence(timeout: 20) else {
      XCTFail("Native saved controller did not become ready")
      throw NSError(domain: "saved_app_ui", code: 3)
    }
    try await SavedAppHTTP.check(port: port, path: "/fresh")
    let summary = app.staticTexts["saved-profile-summary"]
    XCTAssertTrue(summary.waitForExistence(timeout: 10))
    XCTAssertEqual(summary.label, "2 saved profiles")
    let label = app.staticTexts["A"].firstMatch
    XCTAssertTrue(label.waitForExistence(timeout: 10))
    XCTAssertFalse(app.staticTexts["B"].exists)
    let surface = app.descendants(matching: .any)["controller-surface"].firstMatch
    XCTAssertTrue(surface.exists)
    XCTAssertGreaterThanOrEqual(surface.frame.height, 240)
    XCTAssertLessThanOrEqual(done.frame.maxY, surface.frame.minY + 1)
    let side = min(86.0, max(50, min(surface.frame.width, surface.frame.height) * 0.24))
    let point = CGPoint(x: surface.frame.maxX - side / 2, y: surface.frame.minY + side / 2)
    XCTAssertEqual(label.frame.midX, point.x, accuracy: 2)
    XCTAssertEqual(label.frame.midY, point.y, accuracy: 2)
    // HTTP observation runs off the XCTest main actor while XCTest holds the real touch.
    let observation = Task.detached {
      try await Task.sleep(for: .milliseconds(300))
      try await SavedAppHTTP.check(port: port, path: "/saved-start")
      try await Task.sleep(for: .milliseconds(1600))
      try await SavedAppHTTP.check(port: port, path: "/saved-held")
      try await SavedAppHTTP.check(port: port, path: "/held")
    }
    let coordinate = app.coordinate(withNormalizedOffset: .zero).withOffset(
      CGVector(dx: point.x, dy: point.y))
    coordinate.press(forDuration: 3)
    try await observation.value
    done.tap()
    XCTAssertTrue(home.waitForExistence(timeout: 10))
    try await SavedAppHTTP.check(port: port, path: "/neutral")
    try await SavedAppHTTP.check(port: port, path: "/finish")
  }
}
