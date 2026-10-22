import MobileInputCore
import MobileInputUIKit
import ThumbleContracts
import UIKit
import XCTest

@testable internal import ThumbleNativeInput

/// Hosted in the actual bundled React Native app. These are UIKit routing and
/// lifecycle witnesses; Android instrumentation separately injects real touches.
@MainActor final class NativePortalTests: XCTestCase {
  private func applicationWindow() async throws -> UIWindow {
    for _ in 0..<200 {
      let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
      if let window = windows.first(where: { $0.isKeyWindow }),
        let root = window.rootViewController?.view, root.bounds.width > 0,
        findReactRoot(root) != nil
      {
        return window
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw NSError(
      domain: "ThumbleNativePortalTests", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "React root did not start"])
  }
  private func findReactRoot(_ view: UIView) -> UIView? {
    let name = String(describing: type(of: view))
    if name.contains("RCTRoot") || name.contains("RCTSurface") { return view }
    return view.subviews.lazy.compactMap { self.findReactRoot($0) }.first
  }
  private func fixtureMap() throws -> ControlMap {
    let url = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "controller-layout-v1", withExtension: "json"))
    let root = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    return try JSONDecoder().decode(
      ControlMap.self, from: JSONSerialization.data(withJSONObject: try XCTUnwrap(root["map"])))
  }
  private func install(in window: UIWindow) throws -> ThumbleInputView {
    let root = try XCTUnwrap(findReactRoot(try XCTUnwrap(window.rootViewController?.view)))
    let view = ThumbleInputView(appContext: nil)
    view.frame = root.bounds.insetBy(dx: 20, dy: 30)
    root.addSubview(view)
    _ = try view.configure(fixtureMap())
    try view.practice(true)
    window.layoutIfNeeded()
    return view
  }
  func testActualReactRootDoesNotOwnTouchSurface() async throws {
    let window = try await applicationWindow()
    let view = try install(in: window)
    defer {
      view.release(.disposed)
      view.removeFromSuperview()
    }
    XCTAssertTrue(view.engine.practice)
    XCTAssertFalse(view.engine.connected)
    XCTAssertTrue(view.surface.window === window)
    var parent = view.surface.superview
    var reachedWindow = false
    while let current = parent {
      let name = String(describing: type(of: current))
      XCTAssertFalse(name.contains("RCTRoot") || name.contains("RCTSurface"), name)
      reachedWindow = reachedWindow || current === window
      parent = current.superview
    }
    XCTAssertTrue(reachedWindow)
    let map = try fixtureMap()
    for control in map.controls {
      let point = CGPoint(
        x: (control.x + control.width / 2) * view.bounds.width,
        y: (control.y + control.height / 2) * view.bounds.height)
      XCTAssertTrue(
        window.hitTest(view.convert(point, to: window), with: nil) === view.surface,
        control.id)
    }
    XCTAssertFalse(
      window.hitTest(view.convert(CGPoint(x: view.bounds.width - 1, y: 1), to: window), with: nil)
        === view.surface)
  }
  func testHiddenAndRemovedAnchorsReleaseAndStopIntercepting() async throws {
    let window = try await applicationWindow()
    let view = try install(in: window)
    defer {
      view.release(.disposed)
      view.removeFromSuperview()
    }
    let control = try XCTUnwrap(try fixtureMap().controls.first { $0.action == "south" })
    let x = control.x + control.width / 2
    let y = control.y + control.height / 2
    XCTAssertTrue(view.engine.begin(id: 1, generation: "1", x: x, y: y))
    let point = view.convert(
      CGPoint(x: x * view.bounds.width, y: y * view.bounds.height), to: window)
    view.isHidden = true
    XCTAssertFalse(window.hitTest(point, with: nil) === view.surface)
    XCTAssertEqual(GamepadReport.hex(view.engine.state), GamepadReport.hex(.neutral))
    view.isHidden = false
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(window.hitTest(point, with: nil) === view.surface)
    XCTAssertEqual(GamepadReport.hex(view.engine.state), GamepadReport.hex(.neutral))
    XCTAssertTrue(view.engine.begin(id: 2, generation: "1", x: x, y: y))
    view.removeFromSuperview()
    XCTAssertNil(view.surface.window)
    XCTAssertEqual(GamepadReport.hex(view.engine.state), GamepadReport.hex(.neutral))
    XCTAssertFalse(window.hitTest(point, with: nil) === view.surface)
  }
  func testConnectedEngineSurvivesInitialInstallationAndReleasesOnRemoval() async throws {
    let window = try await applicationWindow()
    var samples: [InputSample] = []
    let engine = InputEngine(output: {
      samples.append($0)
      return true
    })
    let map = try fixtureMap()
    try engine.activate(map)
    try engine.connect(generation: map.generation)
    let surface = try InputSurface(connectedEngine: engine)
    XCTAssertEqual(surface.configuration?.generation, map.generation)
    XCTAssertEqual(surface.configuration?.revision, map.revision)
    XCTAssertEqual(samples.count, 1)
    XCTAssertEqual(samples.first?.sequence, "0")
    let container = UIView(frame: CGRect(x: 20, y: 40, width: 240, height: 160))
    surface.frame = container.bounds
    container.addSubview(surface)
    XCTAssertTrue(engine.connected)
    defer {
      surface.dispose()
      container.removeFromSuperview()
    }
    window.addSubview(container)
    container.layoutIfNeeded()
    XCTAssertTrue(surface.window === window)
    XCTAssertTrue(engine.connected)
    XCTAssertThrowsError(try InputSurface(connectedEngine: engine))
    XCTAssertTrue(engine.connected)
    surface.removeFromSuperview()
    XCTAssertFalse(engine.connected)
    XCTAssertEqual(GamepadReport.hex(engine.state), GamepadReport.hex(.neutral))
    container.addSubview(surface)
    XCTAssertFalse(engine.connected)
  }

}
