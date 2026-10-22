import Foundation

/// Canonical retained local-feedback metadata; it never changes input reports.
public struct TouchHapticFeedback: Sendable, Decodable, Equatable {
  public enum Style: String, Sendable, Decodable, Hashable {
    case none, light, medium, heavy, soft, rigid
  }
  public enum Pattern: String, Sendable, Decodable { case single, double, pulse, buzz }
  public let style: Style
  public let pattern: Pattern
  public let intensity: Double
  public let sharpness: Double
  public let duration: Double
  public init(
    style: Style = .light, pattern: Pattern = .single, intensity: Double? = nil,
    sharpness: Double? = nil, duration: Double = 0.06
  ) {
    self.style = style
    self.pattern = pattern
    let defaults: (Double, Double)
    switch style {
    case .none: defaults = (0, 0)
    case .light: defaults = (0.45, 0.48)
    case .medium: defaults = (0.62, 0.56)
    case .heavy: defaults = (0.82, 0.66)
    case .soft: defaults = (0.38, 0.24)
    case .rigid: defaults = (0.70, 0.92)
    }
    self.intensity = intensity ?? defaults.0
    self.sharpness = sharpness ?? defaults.1
    self.duration = duration
  }
  public init(from decoder: any Decoder) throws {
    struct Key: CodingKey {
      let stringValue: String
      var intValue: Int? { nil }
      init?(stringValue: String) { self.stringValue = stringValue }
      init?(intValue: Int) { return nil }
    }
    let c = try decoder.container(keyedBy: Key.self)
    guard
      Set(c.allKeys.map(\.stringValue))
        == Set(["style", "pattern", "intensity", "sharpness", "duration"])
    else { throw InputError.invalidMap }
    style = try c.decode(Style.self, forKey: Key(stringValue: "style")!)
    pattern = try c.decode(Pattern.self, forKey: Key(stringValue: "pattern")!)
    intensity = try c.decode(Double.self, forKey: Key(stringValue: "intensity")!)
    sharpness = try c.decode(Double.self, forKey: Key(stringValue: "sharpness")!)
    duration = try c.decode(Double.self, forKey: Key(stringValue: "duration")!)
    guard valid else { throw InputError.invalidMap }
  }
  public var normalized: Self {
    style == .none
      ? Self(style: .none, pattern: .single, intensity: 0, sharpness: 0, duration: duration) : self
  }
  public var valid: Bool {
    [intensity, sharpness, duration].allSatisfy(\.isFinite)
      && (0...1).contains(intensity) && (0...1).contains(sharpness)
      && (0.02...0.30).contains(duration)
  }
}
public struct TouchHapticPulse: Sendable, Equatable {
  public let delayMilliseconds: Double
  public let intensity: Double
}
/// Bounded fallback impacts, matching the retained player. Platform feedback APIs
/// decide hardware delivery and may approximate continuous patterns/sharpness.
@MainActor public final class TouchHapticPolicy {
  private var lastObserved: Double?
  private var lastStarted: Double?
  public init() {}
  public func schedule(
    _ feedback: TouchHapticFeedback, nowMilliseconds: Double,
    intensityScale: Double = 1, enabled: Bool = true
  ) -> [TouchHapticPulse] {
    guard nowMilliseconds.isFinite, nowMilliseconds >= 0,
      nowMilliseconds <= 9_007_199_254_740_991,
      lastObserved.map({ nowMilliseconds >= $0 }) ?? true
    else { return [] }
    lastObserved = nowMilliseconds
    guard enabled, feedback.valid, feedback.style != .none,
      intensityScale.isFinite, (0...1).contains(intensityScale),
      feedback.intensity * intensityScale > 0,
      lastStarted.map({ nowMilliseconds - $0 >= 50 }) ?? true
    else { return [] }
    lastStarted = nowMilliseconds
    let intensity = feedback.intensity * intensityScale
    switch feedback.pattern {
    case .single, .pulse:
      return [TouchHapticPulse(delayMilliseconds: 0, intensity: intensity)]
    case .double:
      return [
        TouchHapticPulse(delayMilliseconds: 0, intensity: intensity),
        TouchHapticPulse(
          delayMilliseconds: min(max(feedback.duration, 0.045), 0.18) * 1000,
          intensity: intensity * 0.85),
      ]
    case .buzz:
      let count = max(2, min(6, Int(ceil(max(feedback.duration, 0.08) / 0.045))))
      return (0..<count).map { index in
        TouchHapticPulse(
          delayMilliseconds: Double(index) * 45,
          intensity: intensity * (index.isMultiple(of: 2) ? 0.92 : 0.68))
      }
    }
  }
}
