#if canImport(UIKit)
  import UIKit
  import MobileInputCore

  /// Transparent native touch surface composed over the React controller renderer.
  /// The output closure is a native transport/recording sink, never a JS event callback.
  @MainActor public final class InputSurface: UIView {
    public let engine: InputEngine
    private var identities: [ObjectIdentifier: (UInt64, String)] = [:]
    private var nextIdentity: UInt64 = 0
    private var installedAt = 0.0
    private var lastSize = CGSize.zero
    private var displayLink: CADisplayLink?
    public init(engine: InputEngine) {
      self.engine = engine
      super.init(frame: .zero)
      isMultipleTouchEnabled = true
      isOpaque = false
      NotificationCenter.default.addObserver(
        self, selector: #selector(background), name: UIApplication.willResignActiveNotification,
        object: nil)
      NotificationCenter.default.addObserver(
        self, selector: #selector(locked),
        name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }
    @discardableResult public func configure(_ map: ControlMap) throws -> ActivationReceipt {
      let receipt = try engine.activate(map)
      identities.removeAll()
      installedAt = ProcessInfo.processInfo.systemUptime
      return receipt
    }
    public func setPractice(_ enabled: Bool) {
      guard enabled != engine.practice else { return }
      identities.removeAll()
      engine.setPractice(enabled)
    }
    public func dispose() {
      identities.removeAll()
      displayLink?.invalidate()
      displayLink = nil
      NotificationCenter.default.removeObserver(self)
      engine.cancel(.disposed)
    }
    @objc private func background() {
      identities.removeAll()
      engine.cancel(.background)
    }
    @objc private func locked() {
      identities.removeAll()
      engine.cancel(.screenLock)
    }
    public override func didMoveToWindow() {
      super.didMoveToWindow()
      displayLink?.invalidate()
      displayLink = nil
      guard window != nil else {
        identities.removeAll()
        engine.cancel(.disconnected)
        return
      }
      let target = DisplayTarget(surface: self)
      let link = CADisplayLink(target: target, selector: #selector(DisplayTarget.tick(_:)))
      link.preferredFramesPerSecond = 60
      link.add(to: .main, forMode: .common)
      displayLink = link
    }
    public override func layoutSubviews() {
      super.layoutSubviews()
      if lastSize != .zero && lastSize != bounds.size {
        identities.removeAll()
        engine.cancel(.rotation)
      }
      lastSize = bounds.size
    }
    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
      guard bounds.width > 0, bounds.height > 0 else { return }
      for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
        guard touch.timestamp > installedAt, nextIdentity < UInt64.max else { continue }
        let id = nextIdentity
        nextIdentity += 1
        let point = touch.location(in: self)
        let generation = engine.generation
        if engine.begin(
          id: id, generation: generation, x: point.x / bounds.width, y: point.y / bounds.height)
        {
          identities[ObjectIdentifier(touch)] = (id, generation)
        }
      }
    }
    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
      guard bounds.width > 0, bounds.height > 0 else {
        engine.cancel(.rotation)
        identities.removeAll()
        return
      }
      for touch in touches {
        guard let (id, generation) = identities[ObjectIdentifier(touch)] else { continue }
        let point = touch.location(in: self)
        engine.move(
          id: id, generation: generation, x: point.x / bounds.width, y: point.y / bounds.height)
      }
    }
    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
      for touch in touches {
        guard let (id, generation) = identities.removeValue(forKey: ObjectIdentifier(touch)) else {
          continue
        }
        engine.end(id: id, generation: generation)
      }
    }
    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
      identities.removeAll()
      engine.cancel(.touchCancelled)
    }
  }
  @MainActor private final class DisplayTarget: NSObject {
    weak var surface: InputSurface?
    init(surface: InputSurface) { self.surface = surface }
    @objc func tick(_ link: CADisplayLink) {
      guard let surface else {
        link.invalidate()
        return
      }
      surface.engine.tick()
    }
  }
#endif
