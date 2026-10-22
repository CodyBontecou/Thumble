import Foundation
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
  private func install(in window: UIWindow, haptics: TouchHapticPlayer? = nil) throws
    -> ThumbleInputView
  {
    let root = try XCTUnwrap(findReactRoot(try XCTUnwrap(window.rootViewController?.view)))
    let view = ThumbleInputView(appContext: nil)
    if let haptics { view.touchHaptics = haptics }
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
    try await verifyNativeAcceptedTouchFeedback(in: window)
  }
  private final class CallbackTouch: UITouch {
    let point: CGPoint
    init(point: CGPoint) {
      self.point = point
      super.init()
    }
    override var timestamp: TimeInterval { ProcessInfo.processInfo.systemUptime + 1 }
    override func location(in view: UIView?) -> CGPoint { point }
  }
  private func verifyNativeAcceptedTouchFeedback(in window: UIWindow) async throws {
    var impacts = 0
    let haptics = TouchHapticPlayer(intensityScale: { 1 }, sink: { _, _ in impacts += 1 })
    let view = try install(in: window, haptics: haptics)
    defer {
      view.release(.disposed)
      view.removeFromSuperview()
    }
    let region = try XCTUnwrap(try fixtureMap().controls.first { $0.action == "south" })
    let point = CGPoint(
      x: (region.x + region.width / 2) * view.surface.bounds.width,
      y: (region.y + region.height / 2) * view.surface.bounds.height)
    let touch = CallbackTouch(point: point)
    XCTAssertTrue(
      window.hitTest(view.surface.convert(point, to: window), with: nil) === view.surface)
    view.surface.touchesBegan([touch], with: nil)
    XCTAssertEqual(impacts, 1)
    XCTAssertTrue(view.engine.state.buttons.contains(.south))
    view.surface.touchesBegan([touch], with: nil)
    view.surface.touchesMoved([touch], with: nil)
    view.engine.tick()
    XCTAssertEqual(impacts, 1)
    view.surface.touchesCancelled([touch], with: nil)
    XCTAssertEqual(GamepadReport.hex(view.engine.state), GamepadReport.hex(.neutral))
    let cancelled = TouchHapticPlayer(intensityScale: { 1 }, sink: { _, _ in impacts += 1 })
    cancelled.accepted(id: 1, feedback: TouchHapticFeedback(pattern: .double, duration: 0.045))
    cancelled.cancel()
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(impacts, 2)
    let muted = TouchHapticPlayer(intensityScale: { 0 }, sink: { _, _ in impacts += 1 })
    muted.accepted(id: 2, feedback: TouchHapticFeedback())
    XCTAssertEqual(impacts, 2)
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

  func testAppPortalAdoptsExactNativeReceiptWithoutFirstLayoutRelease() async throws {
    let window = try await applicationWindow()
    let view = try install(in: window)
    defer {
      view.release(.disposed)
      view.removeFromSuperview()
    }
    let old = view.engine
    let map = ControlMap(generation: "7", revision: "4", controls: try fixtureMap().controls)
    let engine = InputEngine(
      output: { _ in true }, feedback: { [weak view] in view?.publishFeedback($0) })
    try engine.activate(map)
    try engine.connect(generation: "7")
    try view.adoptConnectedEngine(engine)
    window.layoutIfNeeded()
    XCTAssertFalse(old.connected)
    XCTAssertEqual(GamepadReport.hex(old.state), GamepadReport.hex(.neutral))
    XCTAssertTrue(view.engine === engine)
    XCTAssertTrue(view.surface.window === window)
    XCTAssertTrue(engine.connected)
    XCTAssertEqual(view.surface.configuration?.generation, "7")
    XCTAssertEqual(view.surface.configuration?.revision, "4")
    XCTAssertThrowsError(try view.configure(try fixtureMap()))
    XCTAssertThrowsError(try view.practice(true))
    XCTAssertTrue(engine.connected)
    let control = try XCTUnwrap(map.controls.first { $0.action == "south" })
    let point = CGPoint(
      x: (control.x + control.width / 2) * view.bounds.width,
      y: (control.y + control.height / 2) * view.bounds.height)
    XCTAssertTrue(window.hitTest(view.convert(point, to: window), with: nil) === view.surface)
    XCTAssertTrue(
      engine.begin(
        id: 1, generation: "7", x: control.x + control.width / 2, y: control.y + control.height / 2)
    )
    view.removeFromSuperview()
    XCTAssertFalse(engine.connected)
    XCTAssertEqual(GamepadReport.hex(engine.state), GamepadReport.hex(.neutral))
  }

  /// Diagnostic only: a failing acceptance request is never retried or replaced.
  /// A separate ephemeral health check distinguishes app shared-session state
  /// from loopback reachability while the original error remains the test result.
  private func recordBeginProbeFailure(_ error: any Error, port: Int) async {
    let original = error as NSError
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    var healthSucceeded = false
    var healthErrorCode = 0
    if (1...65535).contains(port),
      let url = URL(string: "http://127.0.0.1:\(port)/health")
    {
      var request = URLRequest(url: url)
      request.timeoutInterval = 6
      do {
        let (data, response) = try await session.data(for: request)
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Bool]
        healthSucceeded = (response as? HTTPURLResponse)?.statusCode == 200 && value == ["ok": true]
      } catch {
        healthErrorCode = max(-100000, min(100000, (error as NSError).code))
      }
    }
    let value: [String: Any] = [
      "phase": "begin-http-failed",
      "originalErrorIsURL": original.domain == NSURLErrorDomain,
      "originalErrorCode": max(-100000, min(100000, original.code)),
      "ephemeralHealthSucceeded": healthSucceeded,
      "ephemeralHealthErrorCode": healthErrorCode,
    ]
    do {
      let attachment = XCTAttachment(
        data: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
        uniformTypeIdentifier: "public.json")
      attachment.name = "qa-loopback-admission-failure"
      attachment.lifetime = .keepAlways
      add(attachment)
    } catch {
      XCTFail("Could not attach bounded QA loopback diagnostic")
    }
  }

  private func probe(_ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
    let resource = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "AppProbeConfig", withExtension: "json"))
    let config = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: resource)) as? [String: Int])
    let port = try XCTUnwrap(config["port"])
    XCTAssertTrue((1...65535).contains(port), "Run this suite with run_mobile_app_probe.py")
    let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)"))
    var request = URLRequest(url: url)
    request.timeoutInterval = 6
    if let body {
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let payload: (Data, URLResponse)
    do {
      payload = try await URLSession.shared.data(for: request)
    } catch {
      if path == "/begin" { await recordBeginProbeFailure(error, port: port) }
      throw error
    }
    let (data, response) = payload
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw NSError(
        domain: "ThumbleAppProbe", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey: "recording-only host witness failed at \(path)"
        ])
    }
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
  private func checkpoint(
    _ view: ThumbleInputView, connectionPhase: String,
    tlsConnectOutcome: ControlTLSConnectOutcome, controlFailure: PhoneControlFailureStage,
    runtimeOutcome: ControlTLSRuntimeOutcome, phase: String, generation: String,
    elapsedMs: Int, publications: Int, maximumPublicationGapMs: Int = 0
  ) async throws {
    _ = try await probe(
      "/diagnostic",
      body: [
        "phase": phase, "generation": generation, "connectionPhase": connectionPhase,
        "tlsConnectOutcome": tlsConnectOutcome.rawValue,
        "controlFailureStage": controlFailure.rawValue,
        "tlsRuntimeOutcome": runtimeOutcome.rawValue,
        "anchorKeyWindow": view.window?.isKeyWindow ?? false,
        "elapsedMs": elapsedMs, "publications": publications,
        "maximumPublicationGapMs": maximumPublicationGapMs,
        "connected": view.engine.connected,
        "held": view.engine.state.buttons.contains(.south) && view.engine.state.leftTrigger == 1,
        "releaseReason": view.engine.lastRelease?.rawValue ?? "none",
        "appState": UIApplication.shared.applicationState.rawValue,
        "idleDisabled": UIApplication.shared.isIdleTimerDisabled,
      ])
  }
  func testNativePairingVaultBindingAndReconnectReachRecordingReceiver() async throws {
    let window = try await applicationWindow()
    let invitation = try await probe("/begin")
    let text = try XCTUnwrap(
      String(data: JSONSerialization.data(withJSONObject: invitation), encoding: .utf8))
    for generation in ["1", "2"] {
      if generation == "2" { _ = try await probe("/next") }
      let view = try install(in: window)
      var phases: [String] = []
      var publications = 0
      var lastPublication: ContinuousClock.Instant?
      var maximumPublicationGapMs = 0
      let flow = PhoneConnection(
        anchor: view,
        feedback: { [weak view] in
          let now = ContinuousClock.now
          if let lastPublication {
            let gap = lastPublication.duration(to: now).components
            maximumPublicationGapMs = max(
              maximumPublicationGapMs,
              min(180000, max(0, Int(gap.seconds * 1000 + gap.attoseconds / 1_000_000_000_000_000)))
            )
          }
          lastPublication = now
          publications += 1
          view?.publishFeedback($0)
        },
        install: { [weak view] engine in
          guard let view else { throw InputError.unavailable }
          try view.adoptConnectedEngine(engine)
        }, status: { phases.append($0) },
        testOnlyMapProvider: { [self] metadata, _ in
          // Explicit-map analog/75s witness; production defaults to saved-map delivery.
          ControlMap(
            generation: metadata.generation, revision: metadata.revision,
            controls: try fixtureMap().controls)
        })
      defer {
        flow.close()
        view.release(.disposed)
        view.removeFromSuperview()
      }
      let template = try fixtureMap()
      flow.start(template: template)
      var top: UIViewController?
      for _ in 0..<200 {
        top = window.rootViewController
        while let next = top?.presentedViewController { top = next }
        if let alert = top as? UIAlertController,
          alert.textFields?.first?.isEnabled == true, !alert.isBeingPresented
        {
          break
        }
        try await Task.sleep(for: .milliseconds(16))
      }
      let alert = try XCTUnwrap(top as? UIAlertController)
      let field = try XCTUnwrap(alert.textFields?.first)
      XCTAssertTrue(field.isSecureTextEntry)
      XCTAssertFalse(field.isFirstResponder)
      XCTAssertTrue(field.canBecomeFirstResponder)
      field.text = nil
      XCTAssertTrue(
        flow.textField(
          field, shouldChangeCharactersIn: NSRange(location: 0, length: 0), replacementString: "{}")
      )
      XCTAssertFalse(
        flow.textField(
          field, shouldChangeCharactersIn: NSRange(location: 0, length: 0),
          replacementString: String(repeating: "x", count: 4097)))
      if generation == "1" {
        for style in [UIUserInterfaceStyle.light, .dark] {
          window.overrideUserInterfaceStyle = style
          window.layoutIfNeeded()
          try await Task.sleep(for: .milliseconds(100))
          let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
          }
          let attachment = XCTAttachment(image: image)
          attachment.name = style == .light ? "native-pairing-light" : "native-pairing-dark"
          attachment.lifetime = .keepAlways
          add(attachment)
        }
        window.overrideUserInterfaceStyle = .unspecified

        field.text = text
        flow.submitInvitation(try XCTUnwrap(field.text), template: template)
      } else {
        XCTAssertTrue(alert.actions.contains { $0.title == "Reconnect" })
        flow.reconnect(template: template)
      }
      for _ in 0..<160 {
        if view.engine.connected || phases.contains("unavailable") { break }
        try await Task.sleep(for: .milliseconds(50))
      }
      guard !phases.contains("unavailable"), view.engine.connected else {
        try? await checkpoint(
          view, connectionPhase: flow.diagnosticPhase.rawValue,
          tlsConnectOutcome: flow.diagnosticConnectOutcome,
          controlFailure: flow.diagnosticControlFailure,
          runtimeOutcome: flow.diagnosticRuntimeOutcome,
          phase: "admission-failed", generation: generation, elapsedMs: 0,
          publications: publications)
        XCTFail("native pairing/admission failed at \(flow.diagnosticPhase.rawValue)")
        return
      }
      XCTAssertEqual(view.engine.generation, generation)
      XCTAssertEqual(GamepadReport.hex(view.engine.state), GamepadReport.hex(.neutral))
      _ = try await probe("/fresh")
      try await checkpoint(
        view, connectionPhase: flow.diagnosticPhase.rawValue,
        tlsConnectOutcome: flow.diagnosticConnectOutcome,
        controlFailure: flow.diagnosticControlFailure,
        runtimeOutcome: flow.diagnosticRuntimeOutcome, phase: "connected",
        generation: generation, elapsedMs: 0, publications: publications)
      let south = try XCTUnwrap(template.controls.first { $0.action == "south" })
      XCTAssertTrue(
        view.engine.begin(
          id: 1, generation: generation, x: south.x + south.width / 2, y: south.y + south.height / 2
        ))
      if generation == "1" {
        let trigger = try XCTUnwrap(template.controls.first { $0.action == "leftTrigger" })
        XCTAssertTrue(
          view.engine.begin(
            id: 2, generation: generation,
            x: trigger.x + trigger.width / 2, y: trigger.y + trigger.height / 2))
        _ = try await probe("/renewal-start")
        let beforePublications = publications
        let started = ContinuousClock.now
        lastPublication = started
        maximumPublicationGapMs = 0
        let until = started.advanced(by: .seconds(75))
        var nextCheckpoint = 0
        while ContinuousClock.now < until {
          try await Task.sleep(for: .milliseconds(250))
          let duration = started.duration(to: .now).components
          let elapsed = min(
            180000,
            max(0, Int(duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000)))
          guard view.engine.connected, view.engine.state.buttons.contains(.south),
            view.engine.state.leftTrigger == 1
          else {
            try? await checkpoint(
              view, connectionPhase: flow.diagnosticPhase.rawValue,
              tlsConnectOutcome: flow.diagnosticConnectOutcome,
              controlFailure: flow.diagnosticControlFailure,
              runtimeOutcome: flow.diagnosticRuntimeOutcome, phase: "ended",
              generation: generation, elapsedMs: elapsed,
              publications: publications - beforePublications,
              maximumPublicationGapMs: maximumPublicationGapMs)
            throw NSError(
              domain: "ThumbleNativePortalTests", code: 2,
              userInfo: [
                NSLocalizedDescriptionKey:
                  "Native hold ended: reason=\(String(describing: view.engine.lastRelease)) elapsedMs=\(elapsed) appState=\(UIApplication.shared.applicationState.rawValue) idleDisabled=\(UIApplication.shared.isIdleTimerDisabled) publications=\(publications-beforePublications)"
              ])
          }
          if elapsed >= nextCheckpoint {
            try await checkpoint(
              view, connectionPhase: flow.diagnosticPhase.rawValue,
              tlsConnectOutcome: flow.diagnosticConnectOutcome,
              controlFailure: flow.diagnosticControlFailure,
              runtimeOutcome: flow.diagnosticRuntimeOutcome, phase: "holding",
              generation: generation, elapsedMs: elapsed,
              publications: publications - beforePublications,
              maximumPublicationGapMs: maximumPublicationGapMs)
            nextCheckpoint = elapsed + 5000
          }
        }
        _ = try await probe("/renewal-verified")
        XCTAssertGreaterThan(publications, beforePublications)
        view.engine.end(id: 2, generation: generation)
      }
      _ = try await probe("/held")
      view.release(.disposed)
      view.removeFromSuperview()
      _ = try await probe("/neutral")
      XCTAssertFalse(view.engine.connected)
    }
    _ = try await probe("/finish")
  }

}
