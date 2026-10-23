import Foundation
import MobileInputCore
import MobileInputUIKit
import ThumbleContracts
import UIKit

/// Explicit-map simulator diagnostic. Never linked into the product or JS bridge.
@main @MainActor final class TLSRuntimeProbe: UIResponder, UIApplicationDelegate {
  var window: UIWindow?
  private var port: UInt16 = 0
  private var flow: PhoneConnection?
  private var surface: InputSurface?
  private var phase = "launch"
  private var generation = "1"
  private var publications = 0
  private var maximumGap = 0
  private var lastPublication: ContinuousClock.Instant?
  private var started = ContinuousClock.now
  private var finished = false
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    guard CommandLine.arguments.count == 2, let port = UInt16(CommandLine.arguments[1]), port > 0
    else { return false }
    self.port = port
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = UIViewController()
    window.makeKeyAndVisible()
    self.window = window
    application.isIdleTimerDisabled = true
    Task {
      do {
        // The app must be active before the real bootstrap admits enrollment.
        for _ in 0..<100 where application.applicationState != .active {
          try await Task.sleep(for: .milliseconds(20))
        }
        try await run()
        finish(true)
      } catch { finish(false) }
    }
    return true
  }
  private func elapsed(_ instant: ContinuousClock.Instant) -> Int {
    let value = instant.duration(to: .now).components
    return min(
      180000, max(0, Int(value.seconds * 1000 + value.attoseconds / 1_000_000_000_000_000)))
  }
  private func probe(_ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
    guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
      throw InputError.unavailable
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 6
    if let body {
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200,
      let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw InputError.unavailable }
    return value
  }
  private func checkpoint(_ label: String) async throws {
    guard let flow, let surface else { throw InputError.unavailable }
    _ = try await probe(
      "/diagnostic",
      body: [
        "phase": label, "generation": generation,
        "connectionPhase": flow.diagnosticPhase.rawValue,
        "tlsConnectOutcome": flow.diagnosticConnectOutcome.rawValue,
        "controlFailureStage": flow.diagnosticControlFailure.rawValue,
        "tlsRuntimeOutcome": flow.diagnosticRuntimeOutcome.rawValue,
        "anchorKeyWindow": surface.window?.isKeyWindow ?? false,
        "elapsedMs": elapsed(started), "publications": publications,
        "maximumPublicationGapMs": maximumGap, "connected": surface.engine.connected,
        "held": surface.engine.state.buttons.contains(.south)
          && surface.engine.state.leftTrigger == 1,
        "releaseReason": surface.engine.lastRelease?.rawValue ?? "none",
        "appState": UIApplication.shared.applicationState.rawValue,
        "idleDisabled": UIApplication.shared.isIdleTimerDisabled,
      ])
  }
  private func map() throws -> ControlMap {
    guard let url = Bundle.main.url(forResource: "controller-layout-v1", withExtension: "json"),
      let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
      let map = value["map"]
    else { throw InputError.unavailable }
    return try JSONDecoder().decode(
      ControlMap.self, from: JSONSerialization.data(withJSONObject: map))
  }
  private func run() async throws {
    phase = "begin"
    let invitation = try await probe("/begin")
    guard
      let text = String(
        data: try JSONSerialization.data(withJSONObject: invitation), encoding: .utf8),
      let root = window?.rootViewController?.view
    else { throw InputError.unavailable }
    let template = try map()
    for generation in ["1", "2"] {
      self.generation = generation
      phase = "admission"
      if generation == "2" { _ = try await probe("/next") }
      let anchor = UIView(frame: root.bounds.insetBy(dx: 20, dy: 30))
      root.addSubview(anchor)
      publications = 0
      maximumGap = 0
      lastPublication = nil
      let connection = PhoneConnection(
        anchor: anchor,
        feedback: { [weak self] _ in
          guard let self else { return }
          if let lastPublication { maximumGap = max(maximumGap, elapsed(lastPublication)) }
          lastPublication = .now
          publications = min(1_000_000, publications + 1)
        },
        install: { [weak self, weak anchor] engine in
          guard let self, let anchor else { throw InputError.unavailable }
          let surface = try InputSurface(connectedEngine: engine)
          surface.frame = anchor.bounds
          anchor.addSubview(surface)
          self.surface = surface
        }, status: { _ in },
        testOnlyMapProvider: { metadata, _ in
          ControlMap(
            generation: metadata.generation, revision: metadata.revision,
            controls: template.controls)
        })
      flow = connection
      if generation == "1" {
        connection.submitInvitation(text, template: template)
      } else {
        connection.reconnect(template: template)
      }
      for _ in 0..<160 {
        if surface?.engine.connected == true { break }
        try await Task.sleep(for: .milliseconds(50))
      }
      guard let surface, surface.engine.connected, surface.engine.generation == generation,
        GamepadReport.hex(surface.engine.state) == GamepadReport.hex(.neutral)
      else { throw InputError.unavailable }
      phase = "fresh"
      _ = try await probe("/fresh")
      guard let south = template.controls.first(where: { $0.action == "south" }),
        surface.engine.begin(
          id: 1, generation: generation, x: south.x + south.width / 2, y: south.y + south.height / 2
        )
      else { throw InputError.unavailable }
      if generation == "1" {
        guard let trigger = template.controls.first(where: { $0.action == "leftTrigger" }),
          surface.engine.begin(
            id: 2, generation: generation, x: trigger.x + trigger.width / 2,
            y: trigger.y + trigger.height / 2)
        else { throw InputError.unavailable }
        phase = "renewal-start"
        _ = try await probe("/renewal-start")
        phase = "holding"
        started = .now
        maximumGap = 0
        var nextCheckpoint = 0
        while elapsed(started) < 75000 {
          try await Task.sleep(for: .milliseconds(250))
          guard surface.engine.connected, surface.engine.state.buttons.contains(.south),
            surface.engine.state.leftTrigger == 1
          else {
            try? await checkpoint("ended")
            throw InputError.unavailable
          }
          if elapsed(started) >= nextCheckpoint {
            try await checkpoint("holding")
            nextCheckpoint = elapsed(started) + 5000
          }
        }
        phase = "renewal-verified"
        _ = try await probe("/renewal-verified")
        surface.engine.end(id: 2, generation: generation)
      }
      phase = "held"
      _ = try await probe("/held")
      surface.dispose()
      surface.removeFromSuperview()
      phase = "neutral"
      _ = try await probe("/neutral")
      connection.close()
      anchor.removeFromSuperview()
      self.surface = nil
    }
    phase = "finish"
    _ = try await probe("/finish")
  }
  private func finish(_ passed: Bool) {
    guard !finished else { return }
    finished = true
    let result: [String: Any] = [
      "version": 1, "scope": "explicit-map-ios-runtime", "passed": passed,
      "phase": phase, "generation": generation, "elapsedMs": elapsed(started),
      "publications": publications, "maximumPublicationGapMs": maximumGap,
      "tlsRuntimeOutcome": flow?.diagnosticRuntimeOutcome.rawValue ?? "idle",
      "controlFailureStage": flow?.diagnosticControlFailure.rawValue ?? "none",
    ]
    if let documents = try? FileManager.default.url(
      for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true),
      let bytes = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    {
      try? bytes.write(to: documents.appendingPathComponent("result.json"), options: .atomic)
    }
    flow?.close()
    surface?.dispose()
  }
}
