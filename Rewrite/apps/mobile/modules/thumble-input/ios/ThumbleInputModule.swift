import CoreFoundation
import ExpoModulesCore
import MobileInputCore
import MobileInputUIKit
import ThumbleContracts
import UIKit

public final class ThumbleInputModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ThumbleNativeInput")
    // Expo dispatches view AsyncFunctions on the main queue. Assert that
    // contract before entering the Swift UI actor; only typed Sendable metadata
    // leaves the actor, with bridge dictionaries assembled afterwards.
    View(ThumbleInputView.self) {
      Events("onAdmission")
      Prop("practiceMap") { (view: ThumbleInputView, value: [String: Any]) in
        view.pendingPractice = value
      }
      Prop("connectionMap") { (view: ThumbleInputView, value: [String: Any]) in
        view.pendingConnection = value
      }
      OnViewDidUpdateProps { (view: ThumbleInputView) in
        view.admitPractice()
        view.admitConnection()
      }
      AsyncFunction("configure") { (view: ThumbleInputView, value: [String: Any]) in
        let map = try ThumbleInputView.decodeMap(value)
        let receipt = try withInputView(view) { try $0.configure(map) }
        return [
          "version": receipt.version, "generation": receipt.generation,
          "revision": receipt.revision,
        ] as [String: Any]
      }
      AsyncFunction("setPractice") { (view: ThumbleInputView, enabled: Bool) in
        try withInputView(view) { try $0.practice(enabled) }
      }
      AsyncFunction("release") { (view: ThumbleInputView, reason: String) in
        guard let reason = ReleaseReason(rawValue: reason) else { throw InputError.invalidMap }
        withInputView(view) { $0.release(reason) }
      }
      AsyncFunction("snapshot") { (view: ThumbleInputView) in
        withInputView(view) { $0.snapshot() }.value
      }
    }
  }
}

@MainActor final class ThumbleInputView: ExpoView {
  let onAdmission = EventDispatcher()
  fileprivate var pendingConnection: [String: Any]?
  fileprivate var pendingPractice: [String: Any]?
  private var practiceAdmitted = false
  fileprivate func admitPractice() {
    guard pendingConnection == nil, let pendingPractice, !practiceAdmitted else { return }
    practiceAdmitted = true
    do {
      let receipt = try configure(Self.decodeMap(pendingPractice))
      try practice(true)
      guard engine.practice, !engine.connected else { throw InputError.unavailable }
      onAdmission([
        "admission": [
          "version": 1, "status": "ready", "generation": receipt.generation,
          "revision": receipt.revision, "practice": true, "connected": false,
        ]
      ])
    } catch {
      release(.disposed)
      onAdmission(["admission": ["version": 1, "status": "unavailable"]])
    }
  }
  lazy var engine = InputEngine(
    output: { _ in false },
    feedback: { [weak self] state in
      self?.feedbackState = state
      self?.setNeedsDisplay()
    })
  lazy var surface = InputSurface(engine: engine)
  private var liveOwned = false
  private var liveMode = false
  private var connectionAttempted = false
  private var connection: PhoneConnection?
  fileprivate func admitConnection() {
    guard !disposed, !connectionAttempted, let pendingConnection, window != nil,
      bounds.width > 0, bounds.height > 0
    else { return }
    connectionAttempted = true
    do {
      guard pendingPractice == nil else { throw InputError.invalidMap }
      let template = try Self.decodeMap(pendingConnection)
      _ = try configure(template)
      let flow = PhoneConnection(
        anchor: self,
        feedback: { [weak self] state in self?.publishFeedback(state) },
        install: { [weak self] engine in
          guard let self, self.window != nil, !self.disposed else { throw InputError.unavailable }
          try self.adoptConnectedEngine(engine)
        },
        status: { [weak self] status in
          self?.onAdmission(["admission": ["version": 1, "status": status]])
        })
      connection = flow
      flow.start(template: template)
    } catch {
      onAdmission(["admission": ["version": 1, "status": "unavailable"]])
    }
  }
  func publishFeedback(_ state: GamepadStateV1) {
    feedbackState = state
    setNeedsDisplay()
  }
  func adoptConnectedEngine(_ next: InputEngine) throws {
    guard !disposed, window != nil else { throw InputError.unavailable }
    let nextSurface = try InputSurface(connectedEngine: next)
    guard let map = nextSurface.configuration else { throw InputError.unavailable }
    portal?.removeFromSuperview()
    portal = nil
    surface.removeFromSuperview()
    surface.dispose()
    engine = next
    surface = nextSurface
    configured = map
    lastReceipt = nil
    liveOwned = true
    liveMode = true
    installPortal()
    guard next.connected else { throw InputError.unavailable }
    onAdmission([
      "admission": [
        "version": 1, "status": "ready", "generation": map.generation,
        "revision": map.revision, "practice": false, "connected": true,
      ]
    ])
  }
  fileprivate func connectionTick() {
    if liveOwned && !engine.connected {
      liveOwned = false
      connection?.close()
      onAdmission(["admission": ["version": 1, "status": "disconnected"]])
    }
  }
  private var feedbackState = GamepadStateV1.neutral
  private var lastReceipt: ActivationReceipt?
  private var configured: ControlMap?
  private var disposed = false
  private var portal: TouchPortal?
  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    isOpaque = false
    clipsToBounds = true
  }
  override func layoutSubviews() {
    super.layoutSubviews()
    portal?.synchronize()
    admitConnection()
  }
  override func didMoveToWindow() {
    super.didMoveToWindow()
    portal?.removeFromSuperview()
    portal = nil
    surface.removeFromSuperview()
    guard window != nil, !disposed else {
      connection?.close()
      return
    }
    installPortal()
    admitConnection()
  }
  private func installPortal() {
    guard let window, !disposed else { return }
    // UIWindow-owned sibling: no React root gesture recognizer in touch ancestry.
    let next = TouchPortal(anchor: self, surface: surface)
    portal = next
    window.addSubview(next)
    next.synchronize()
  }
  fileprivate func controlContains(_ point: CGPoint) -> Bool {
    guard !disposed, engine.practice || engine.connected, let configured,
      bounds.width > 0, bounds.height > 0
    else { return false }
    return configured.controls.contains {
      CGRect(
        x: $0.x * bounds.width, y: $0.y * bounds.height,
        width: $0.width * bounds.width, height: $0.height * bounds.height
      ).contains(point)
    }
  }
  func configure(_ map: ControlMap) throws -> ActivationReceipt {
    guard !disposed, !liveMode else { throw InputError.unavailable }
    // React may repeat the same configuration while replaying an effect. An
    // identical map acknowledges existing ownership without creating touches.
    if let previous = configured, let receipt = lastReceipt, Self.same(previous, map) {
      return receipt
    }
    let receipt = try surface.configure(map)
    configured = map
    lastReceipt = receipt
    return receipt
  }
  func practice(_ enabled: Bool) throws {
    guard !disposed, !liveMode else { throw InputError.unavailable }
    surface.setPractice(enabled)
  }
  func release(_ reason: ReleaseReason) {
    guard !disposed else { return }
    if reason == .disposed {
      disposed = true
      connection?.close()
      portal?.removeFromSuperview()
      portal = nil
      surface.removeFromSuperview()
      surface.dispose()
    } else {
      surface.release(reason)
    }
  }
  fileprivate func snapshot() -> BridgeSnapshot {
    BridgeSnapshot(
      generation: engine.generation, connected: engine.connected, practice: engine.practice,
      lastRelease: engine.lastRelease?.rawValue, state: engine.state)
  }
  override func draw(_ rect: CGRect) {
    super.draw(rect)
    guard let map = configured else { return }
    let state = feedbackState
    for control in map.controls {
      let frame = CGRect(
        x: control.x * bounds.width, y: control.y * bounds.height,
        width: control.width * bounds.width, height: control.height * bounds.height)
      let active =
        state.buttons.contains { $0.rawValue == control.action }
        || (control.action == "leftTrigger" && state.leftTrigger > 0)
        || (control.action == "rightTrigger" && state.rightTrigger > 0)
      if active {
        UIColor.systemBlue.withAlphaComponent(0.3).setFill()
        UIBezierPath(roundedRect: frame, cornerRadius: 12).fill()
      }
      if control.action == "leftStick" || control.action == "rightStick" {
        let left = control.action == "leftStick"
        let x = left ? state.leftStickX : state.rightStickX
        let y = left ? state.leftStickY : state.rightStickY
        let radius = min(frame.width, frame.height) * 0.18
        UIColor.systemBlue.withAlphaComponent(0.65).setFill()
        UIBezierPath(
          ovalIn: CGRect(
            x: frame.midX + x * frame.width * 0.32 - radius,
            y: frame.midY + y * frame.height * 0.32 - radius, width: radius * 2, height: radius * 2)
        ).fill()
      }
    }
  }
  private static func same(_ a: ControlMap, _ b: ControlMap) -> Bool {
    a.generation == b.generation && a.revision == b.revision && a.controls.count == b.controls.count
      && zip(a.controls, b.controls).allSatisfy {
        $0.id == $1.id && $0.action == $1.action && $0.x == $1.x && $0.y == $1.y
          && $0.width == $1.width && $0.height == $1.height
      }
  }
  fileprivate nonisolated static func decodeMap(_ value: [String: Any]) throws -> ControlMap {
    func exact(_ value: [String: Any], _ keys: [String]) throws {
      guard Set(value.keys) == Set(keys) else { throw InputError.invalidMap }
    }
    func number(_ value: Any?) throws -> Double {
      guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
        value.doubleValue.isFinite
      else { throw InputError.invalidMap }
      return value.doubleValue
    }
    try exact(value, ["version", "generation", "revision", "controls"])
    guard try number(value["version"]) == 1,
      let generation = value["generation"] as? String, generation.utf8.count <= 20,
      let revision = value["revision"] as? String, revision.utf8.count <= 20,
      let controls = value["controls"] as? [[String: Any]], (1...64).contains(controls.count)
    else { throw InputError.invalidMap }
    return try ControlMap(
      generation: generation, revision: revision,
      controls: controls.map { control in
        try exact(control, ["id", "action", "x", "y", "width", "height"])
        guard let id = control["id"] as? String, id.utf8.count <= 64,
          let action = control["action"] as? String, action.utf8.count <= 64
        else { throw InputError.invalidMap }
        return try ControlRegion(
          id: id, action: action, x: number(control["x"]), y: number(control["y"]),
          width: number(control["width"]), height: number(control["height"]))
      })
  }
}

/// Only controller regions accept a new touch. UIKit can still deliver taps to
/// navigation beneath the window sibling; existing controller streams stay native.
@MainActor private final class TouchPortal: UIView {
  private weak var anchor: ThumbleInputView?
  private let surface: InputSurface
  private var displayLink: CADisplayLink?
  init(anchor: ThumbleInputView, surface: InputSurface) {
    self.anchor = anchor
    self.surface = surface
    super.init(frame: .zero)
    isOpaque = false
    isMultipleTouchEnabled = true
    accessibilityElementsHidden = true
    addSubview(surface)
  }
  @available(*, unavailable) required init?(coder: NSCoder) { nil }
  override func didMoveToWindow() {
    super.didMoveToWindow()
    displayLink?.invalidate()
    displayLink = nil
    guard window != nil else {
      surface.release(.disconnected)
      return
    }
    let target = PortalDisplayTarget(portal: self)
    let link = CADisplayLink(target: target, selector: #selector(PortalDisplayTarget.tick(_:)))
    link.add(to: .main, forMode: .common)
    displayLink = link
  }
  func synchronize() {
    guard let anchor, let window, anchor.window === window else {
      removeFromSuperview()
      return
    }
    anchor.connectionTick()
    let nextFrame = anchor.convert(anchor.bounds, to: window)
    var visible = nextFrame
    var ancestor: UIView? = anchor
    var available = nextFrame.width > 0 && nextFrame.height > 0
    while let view = ancestor {
      if view.isHidden || view.alpha <= 0.01 { available = false }
      if view.clipsToBounds {
        visible = visible.intersection(view.convert(view.bounds, to: window))
      }
      ancestor = view.superview
    }
    var top = window.rootViewController
    while let presented = top?.presentedViewController, !presented.isBeingDismissed {
      top = presented
    }
    available =
      available && window.isKeyWindow && visible == nextFrame
      && top.map { anchor.isDescendant(of: $0.view) } == true
    if !available && !isHidden { surface.release(.disconnected) }
    isHidden = !available
    if frame != nextFrame {
      if frame.size != .zero { surface.release(.rotation) }
      frame = nextFrame
      surface.frame = bounds
    }
  }
  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    synchronize()
    guard !isHidden, let anchor else { return false }
    return anchor.controlContains(convert(point, to: anchor))
  }
}
@MainActor private final class PortalDisplayTarget: NSObject {
  private weak var portal: TouchPortal?
  init(portal: TouchPortal) { self.portal = portal }
  @objc func tick(_ link: CADisplayLink) {
    guard let portal else {
      link.invalidate()
      return
    }
    portal.synchronize()
  }
}

private struct BridgeSnapshot: Sendable {
  let generation: String
  let connected: Bool
  let practice: Bool
  let lastRelease: String?
  let state: GamepadStateV1
  var value: [String: Any] {
    [
      "generation": generation, "connected": connected, "practice": practice,
      "lastRelease": lastRelease.map { $0 as Any } ?? NSNull(),
      "state": [
        "buttons": state.buttons.map(\.rawValue), "leftStickX": state.leftStickX,
        "leftStickY": state.leftStickY, "rightStickX": state.rightStickX,
        "rightStickY": state.rightStickY,
        "leftTrigger": state.leftTrigger, "rightTrigger": state.rightTrigger,
      ],
    ]
  }
}

/// Expo 58.0.24 ViewDefinitionBuilder.buildExpression enforces `.runOnQueue(.main)`
/// for view AsyncFunctions, but its Swift API does not encode actor isolation.
/// This local alias bridges that audited synchronous callback only; the view is
/// never declared Sendable and no bridge dictionary crosses an actor boundary.
private func withInputView<Result: Sendable>(
  _ view: ThumbleInputView, _ body: @MainActor (ThumbleInputView) throws -> Result
) rethrows -> Result {
  nonisolated(unsafe) let uiView = view
  return try MainActor.assumeIsolated { try body(uiView) }
}
