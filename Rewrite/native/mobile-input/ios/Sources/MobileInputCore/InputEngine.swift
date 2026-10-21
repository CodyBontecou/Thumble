import Foundation
import ThumbleContracts

/// Native UI-thread state. React is a configuration/inspection client, never the touch queue.
@MainActor public final class InputEngine {
  private struct Capture {
    let region: ControlRegion
    var x: Double
    var y: Double
  }
  private var map: ControlMap?
  private var epoch: UInt64 = 0
  private var revision: UInt64 = 0
  private var sequence: UInt64 = 0
  private var captures: [UInt64: Capture] = [:]
  private var admitted = false
  private var publishing = false
  private var disposed = false
  private let output: (InputSample) -> Bool
  private let feedback: (GamepadStateV1) -> Void
  public private(set) var connected = false
  public private(set) var practice = false
  public private(set) var state = GamepadStateV1.neutral
  public private(set) var lastRelease: ReleaseReason?
  public var generation: String { String(epoch) }

  public init(
    output: @escaping (InputSample) -> Bool, feedback: @escaping (GamepadStateV1) -> Void = { _ in }
  ) {
    self.output = output
    self.feedback = feedback
  }
  @discardableResult public func activate(_ next: ControlMap) throws -> ActivationReceipt {
    guard !publishing else { throw InputError.reentrant }
    guard !disposed else { throw InputError.unavailable }
    let (newEpoch, newRevision) = try next.validated()
    guard newEpoch > epoch, newRevision >= revision else { throw InputError.staleMap }
    cancel(.profileReplacement)
    map = next
    epoch = newEpoch
    revision = newRevision
    sequence = 0
    admitted = false
    return ActivationReceipt(version: 1, generation: next.generation, revision: next.revision)
  }
  public func connect(generation: String) throws {
    guard !publishing else { throw InputError.reentrant }
    guard !disposed, !practice, map != nil, generation == self.generation else {
      throw InputError.unavailable
    }
    guard !admitted else { throw InputError.freshGenerationRequired }
    admitted = true
    captures.removeAll()
    state = .neutral
    connected = true
    emit()
  }
  @discardableResult public func begin(id: UInt64, generation: String, x: Double, y: Double) -> Bool
  {
    guard accepts(generation), !publishing else { return false }
    guard validPoint(x, y), captures[id] == nil, captures.count < 16 else {
      cancel(.invalidTouch)
      return false
    }
    guard let region = map?.controls.reversed().first(where: { $0.contains(x, y) }) else {
      return false
    }
    if region.action.hasSuffix("Stick")
      && captures.values.contains(where: { $0.region.action == region.action })
    {
      return false
    }
    captures[id] = Capture(region: region, x: x, y: y)
    update()
    return true
  }
  public func move(id: UInt64, generation: String, x: Double, y: Double) {
    guard accepts(generation), !publishing, var capture = captures[id] else { return }
    guard validPoint(x, y) else {
      cancel(.invalidTouch)
      return
    }
    capture.x = x
    capture.y = y
    captures[id] = capture
    update()
  }
  public func end(id: UInt64, generation: String) {
    guard accepts(generation), !publishing, captures.removeValue(forKey: id) != nil else { return }
    update()
  }
  public func tick() { if !publishing && !disposed { emit() } }
  public func setPractice(_ enabled: Bool) {
    guard !publishing, !disposed, enabled != practice else { return }
    cancel(.practice)
    practice = enabled
  }
  public func cancel(_ reason: ReleaseReason) {
    guard !publishing, !disposed else { return }
    captures.removeAll()
    state = .neutral
    lastRelease = reason
    emit()
    connected = false
    if reason == .disposed { disposed = true }
  }
  private func accepts(_ generation: String) -> Bool {
    !disposed && map != nil && generation == self.generation && (connected || practice)
  }
  private func validPoint(_ x: Double, _ y: Double) -> Bool {
    x.isFinite && y.isFinite && abs(x) <= 16 && abs(y) <= 16
  }
  private func update() {
    var buttons = Set<GamepadButtonV1>()
    var lx = 0.0
    var ly = 0.0
    var rx = 0.0
    var ry = 0.0
    var lt = 0.0
    var rt = 0.0
    for capture in captures.values {
      let r = capture.region
      if r.action == "leftStick" || r.action == "rightStick" {
        var x = ((capture.x - r.x) / r.width - 0.5) * 2
        var y = ((capture.y - r.y) / r.height - 0.5) * 2
        let length = hypot(x, y)
        if length > 1 {
          x /= length
          y /= length
        }
        if r.action == "leftStick" {
          lx = x
          ly = y
        } else {
          rx = x
          ry = y
        }
      } else if r.contains(capture.x, capture.y) {
        if r.action == "leftTrigger" {
          lt = 1
        } else if r.action == "rightTrigger" {
          rt = 1
        } else if let button = GamepadButtonV1(rawValue: r.action) {
          buttons.insert(button)
        }
      }
    }
    state = GamepadStateV1(
      buttons: GamepadButtonV1.allCases.filter { buttons.contains($0) }, leftStickX: lx,
      leftStickY: ly, rightStickX: rx, rightStickY: ry, leftTrigger: lt, rightTrigger: rt)
    emit()
  }
  private func emit() {
    guard !publishing else { return }
    publishing = true
    defer { publishing = false }
    feedback(state)
    guard connected, !practice else { return }
    guard sequence < UInt64.max else {
      connected = false
      captures.removeAll()
      state = .neutral
      lastRelease = .sequenceExhausted
      feedback(state)
      return
    }
    let sample = InputSample(generation: generation, sequence: String(sequence), state: state)
    sequence += 1
    if !output(sample) {
      connected = false
      captures.removeAll()
      state = .neutral
      lastRelease = .transportFailure
      feedback(state)
    }
  }
}
