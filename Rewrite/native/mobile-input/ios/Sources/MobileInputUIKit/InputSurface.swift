#if canImport(UIKit)
  import UIKit
  import MobileInputCore

  /// Transparent native touch surface composed over the React controller renderer.
  /// The output closure is a native transport/recording sink, never a JS event callback.
  @MainActor public final class InputSurface: UIView {
    public let engine: InputEngine
    private let haptics: TouchHapticPlayer
    public private(set) var configuration: ControlMap?
    private var wasAttached = false
    private var identities: [ObjectIdentifier: (UInt64, String)] = [:]
    private var nextIdentity: UInt64 = 0
    private var installedAt = 0.0
    private var lastSize = CGSize.zero
    private var displayLink: CADisplayLink?
    public init(engine: InputEngine, haptics: TouchHapticPlayer = TouchHapticPlayer()) {
      self.engine = engine
      self.haptics = haptics
      super.init(frame: .zero)
      haptics.isActive = { [weak engine] in engine.map { $0.connected || $0.practice } ?? false }
      isMultipleTouchEnabled = true
      isOpaque = false
      NotificationCenter.default.addObserver(
        self, selector: #selector(background), name: UIApplication.willResignActiveNotification,
        object: nil)
      NotificationCenter.default.addObserver(
        self, selector: #selector(locked),
        name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
    }
    /// Adopt the engine already activated by PhoneControlClient.bindInput.
    public convenience init(
      connectedEngine: InputEngine, haptics: TouchHapticPlayer = TouchHapticPlayer()
    ) throws {
      let map = try connectedEngine.claimTouchSurface()
      self.init(engine: connectedEngine, haptics: haptics)
      configuration = map
      installedAt = ProcessInfo.processInfo.systemUptime
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }
    @discardableResult public func configure(_ map: ControlMap) throws -> ActivationReceipt {
      let receipt = try engine.activate(map)
      configuration = map
      haptics.cancel()
      identities.removeAll()
      installedAt = ProcessInfo.processInfo.systemUptime
      return receipt
    }
    public func setPractice(_ enabled: Bool) {
      guard enabled != engine.practice else { return }
      haptics.cancel()
      identities.removeAll()
      engine.setPractice(enabled)
    }
    public func release(_ reason: ReleaseReason) {
      haptics.cancel()
      identities.removeAll()
      installedAt = ProcessInfo.processInfo.systemUptime
      engine.cancel(reason)
    }
    public func dispose() {
      haptics.cancel()
      identities.removeAll()
      displayLink?.invalidate()
      displayLink = nil
      NotificationCenter.default.removeObserver(self)
      engine.cancel(.disposed)
    }
    @objc private func background() {
      haptics.cancel()
      identities.removeAll()
      engine.cancel(.background)
    }
    @objc private func locked() {
      haptics.cancel()
      identities.removeAll()
      engine.cancel(.screenLock)
    }
    public override func didMoveToWindow() {
      super.didMoveToWindow()
      displayLink?.invalidate()
      displayLink = nil
      guard window != nil else {
        haptics.cancel()
        identities.removeAll()
        if wasAttached { engine.cancel(.disconnected) }
        return
      }
      wasAttached = true
      let target = DisplayTarget(surface: self)
      let link = CADisplayLink(target: target, selector: #selector(DisplayTarget.tick(_:)))
      link.preferredFramesPerSecond = 60
      link.add(to: .main, forMode: .common)
      displayLink = link
    }
    public override func layoutSubviews() {
      super.layoutSubviews()
      if lastSize != .zero && lastSize != bounds.size {
        haptics.cancel()
        identities.removeAll()
        engine.cancel(.rotation)
      }
      lastSize = bounds.size
    }
    fileprivate func sampleNativeInput() {
      engine.tick()
      if !engine.connected && !engine.practice { haptics.cancel() }
    }
    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
      guard bounds.width > 0, bounds.height > 0 else { return }
      for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
        guard identities[ObjectIdentifier(touch)] == nil, touch.timestamp > installedAt,
          nextIdentity < UInt64.max
        else { continue }
        let id = nextIdentity
        nextIdentity += 1
        let point = touch.location(in: self)
        let generation = engine.generation
        if engine.begin(
          id: id, generation: generation, x: point.x / bounds.width, y: point.y / bounds.height)
        {
          identities[ObjectIdentifier(touch)] = (id, generation)
          if engine.connected || engine.practice,
            let region = configuration?.controls.reversed().first(where: {
              point.x / bounds.width >= $0.x && point.x / bounds.width < $0.x + $0.width
                && point.y / bounds.height >= $0.y && point.y / bounds.height < $0.y + $0.height
            })
          {
            haptics.accepted(id: id, feedback: region.hapticFeedback ?? TouchHapticFeedback())
          }
        }
      }
    }
    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
      guard bounds.width > 0, bounds.height > 0 else {
        engine.cancel(.rotation)
        haptics.cancel()
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
        haptics.ended(id: id)
        engine.end(id: id, generation: generation)
      }
    }
    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
      haptics.cancel()
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
      surface.sampleNativeInput()
    }
  }
#endif
