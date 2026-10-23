#if canImport(UIKit)
  import UIKit
  import MobileInputCore

  @MainActor public enum TouchHapticPreferences {
    public static let intensityKey = "PocketPad.iOS.keypadHapticIntensity.v1"
    public static func intensity() -> Double {
      let defaults = UserDefaults.standard
      if defaults.object(forKey: intensityKey) == nil {
        return defaults.object(forKey: "PocketPad.iOS.keypadHapticsEnabled.v1") as? Bool == false
          ? 0 : 1
      }
      let value = defaults.double(forKey: intensityKey)
      return value.isFinite ? min(1, max(0, value)) : 0
    }
    public static func setEnabled(_ enabled: Bool) {
      UserDefaults.standard.set(enabled ? 1.0 : 0.0, forKey: intensityKey)
    }
  }
  /// UIKit's system feedback generator owns hardware/OS policy. No CoreHaptics or
  /// force-feedback bypass. Continuous patterns use the retained fallback impacts.
  @MainActor public final class TouchHapticPlayer {
    public var isActive: () -> Bool = { true }
    private let policy = TouchHapticPolicy()
    private let scale: () -> Double
    private let sink: ((TouchHapticFeedback.Style, Double) -> Void)?
    private var generators: [TouchHapticFeedback.Style: UIImpactFeedbackGenerator] = [:]
    private var pending: Task<Void, Never>?
    private var owner: UInt64?
    public init(
      intensityScale: @escaping () -> Double = { TouchHapticPreferences.intensity() },
      sink: ((TouchHapticFeedback.Style, Double) -> Void)? = nil
    ) {
      scale = intensityScale
      self.sink = sink
    }
    public func accepted(id: UInt64, feedback: TouchHapticFeedback) {
      guard isActive() else { return }
      let pulses = policy.schedule(
        feedback, nowMilliseconds: ProcessInfo.processInfo.systemUptime * 1000,
        intensityScale: scale())
      guard let first = pulses.first else { return }
      cancel()
      owner = id
      impact(feedback.style, first.intensity)
      guard pulses.count > 1 else { return }
      pending = Task { [weak self] in
        var previous = first.delayMilliseconds
        for pulse in pulses.dropFirst() {
          do { try await Task.sleep(for: .milliseconds(pulse.delayMilliseconds - previous)) } catch
          { return }
          guard let self, self.owner == id, self.scale() > 0, self.isActive() else { return }
          self.impact(feedback.style, pulse.intensity)
          previous = pulse.delayMilliseconds
        }
      }
    }
    public func ended(id: UInt64) { if owner == id { cancel() } }
    public func cancel() {
      pending?.cancel()
      pending = nil
      owner = nil
    }
    private func impact(_ style: TouchHapticFeedback.Style, _ intensity: Double) {
      if let sink {
        sink(style, intensity)
        return
      }
      let kind: UIImpactFeedbackGenerator.FeedbackStyle
      switch style {
      case .none: return
      case .light: kind = .light
      case .medium: kind = .medium
      case .heavy: kind = .heavy
      case .soft: kind = .soft
      case .rigid: kind = .rigid
      }
      let generator = generators[style] ?? UIImpactFeedbackGenerator(style: kind)
      generators[style] = generator
      generator.impactOccurred(intensity: intensity)
    }
  }
#endif
