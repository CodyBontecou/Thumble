import Foundation
import Testing
import ThumbleContracts

@testable import MobileInputCore

private struct MobileFixture: Decodable {
  let map: ControlMap
  let scenarios: [Scenario]
}
private struct Scenario: Decodable, Sendable, CustomTestStringConvertible {
  let name: String
  let controls: [ControlRegion]?
  let events: [Step]
  var testDescription: String { name }
}
private struct Step: Decodable, Sendable {
  let type: String
  let id: UInt64?
  let generation: String?
  let x: Double?
  let y: Double?
  let enabled: Bool?
  let reason: String?
  let error: String?
  let expected: Expected
}
private struct Expected: Decodable, Sendable {
  let state: GamepadStateV1
  let connected: Bool
  let practice: Bool
  let hostSamples: Int
  let reportHex: String
}
private func fixture<T: Decodable>(_ name: String, as: T.Type) throws -> T {
  let url = try #require(
    Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
  return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
}
// Resource preparation is part of the build. Invalid/missing canonical fixtures must fail the test executable.
private let mobileFixture = try! fixture("mobile-input-v1", as: MobileFixture.self)
private func code(_ error: InputError) -> String {
  switch error {
  case .invalidMap: "invalid_map"
  case .staleMap: "stale_map"
  case .unavailable: "unavailable"
  case .freshGenerationRequired: "fresh_generation_required"
  case .reentrant: "reentrant"
  }
}
@Test @MainActor private func sharedNativeScenarios() throws {
  #expect(mobileFixture.scenarios.count == 15)
}
@Test(arguments: mobileFixture.scenarios) @MainActor private func nativeTouchLifecycle(
  _ scenario: Scenario
) throws {
  var samples: [InputSample] = []
  let engine = InputEngine(output: {
    samples.append($0)
    return true
  })
  let controls = scenario.controls ?? mobileFixture.map.controls
  try engine.activate(ControlMap(generation: "1", revision: "1", controls: controls))
  for step in scenario.events {
    var failure: String?
    do {
      switch step.type {
      case "connect": try engine.connect(generation: step.generation ?? engine.generation)
      case "activate":
        try engine.activate(
          ControlMap(generation: try #require(step.generation), revision: "1", controls: controls))
      case "begin":
        engine.begin(
          id: try #require(step.id), generation: step.generation ?? engine.generation,
          x: try #require(step.x), y: try #require(step.y))
      case "move":
        engine.move(
          id: try #require(step.id), generation: step.generation ?? engine.generation,
          x: try #require(step.x), y: try #require(step.y))
      case "end":
        engine.end(id: try #require(step.id), generation: step.generation ?? engine.generation)
      case "cancel":
        let reason = try #require(step.reason)
        engine.cancel(try #require(ReleaseReason(rawValue: reason)))
      case "practice": engine.setPractice(try #require(step.enabled as Bool?))
      case "tick": engine.tick()
      default:
        Issue.record("Unknown fixture event")
        return
      }
    } catch let error as InputError { failure = code(error) }
    #expect(failure == step.error)
    #expect(engine.state.isValid)
    #expect(engine.state.buttons == step.expected.state.buttons)
    let actual = engine.state
    let expected = step.expected.state
    for (a, b) in zip(
      [
        actual.leftStickX, actual.leftStickY, actual.rightStickX, actual.rightStickY,
        actual.leftTrigger, actual.rightTrigger,
      ],
      [
        expected.leftStickX, expected.leftStickY, expected.rightStickX, expected.rightStickY,
        expected.leftTrigger, expected.rightTrigger,
      ])
    { #expect(abs(a - b) < 1e-9) }
    #expect(GamepadReport.hex(engine.state) == step.expected.reportHex)
    #expect(engine.connected == step.expected.connected)
    #expect(engine.practice == step.expected.practice)
    #expect(samples.count == step.expected.hostSamples)
    #expect(samples.allSatisfy { $0.state.isValid })
  }
  for (index, sample) in samples.enumerated() {
    if index > 0 && samples[index - 1].generation == sample.generation {
      let sequence = try #require(UInt64(sample.sequence))
      let previous = try #require(UInt64(samples[index - 1].sequence))
      #expect(sequence > previous)
    }
  }
}
private struct NativeVectors: Decodable {
  let vectors: [Vector]
  struct Vector: Decodable {
    let name: String
    let hex: String
    let buttons: [GamepadButtonV1]?
    let leftStickX: Double?
    let leftStickY: Double?
    let rightStickX: Double?
    let rightStickY: Double?
    let leftTrigger: Double?
    let rightTrigger: Double?
    var state: GamepadStateV1 {
      GamepadStateV1(
        buttons: buttons ?? [], leftStickX: leftStickX ?? 0, leftStickY: leftStickY ?? 0,
        rightStickX: rightStickX ?? 0, rightStickY: rightStickY ?? 0, leftTrigger: leftTrigger ?? 0,
        rightTrigger: rightTrigger ?? 0)
    }
  }
}
@Test private func allRetainedNativeVectors() throws {
  let vectors = try fixture("gamepad-v2", as: NativeVectors.self).vectors
  #expect(vectors.count == 34)
  for vector in vectors { #expect(GamepadReport.hex(vector.state) == vector.hex, "\(vector.name)") }
  let bad = GamepadStateV1(
    buttons: [], leftStickX: .nan, leftStickY: .infinity, rightStickX: 0, rightStickY: 0,
    leftTrigger: .nan, rightTrigger: .infinity)
  #expect(!bad.isValid)
  #expect(GamepadReport.hex(bad) == GamepadReport.hex(.neutral))
}
@Test @MainActor private func invalidConfigurationPreservesCurrentActivationAndHeldState() throws {
  let engine = InputEngine(output: { _ in true })
  try engine.activate(mobileFixture.map)
  try engine.connect(generation: "1")
  engine.begin(id: 1, generation: "1", x: 0.67, y: 0.1)
  let region = ControlRegion(id: "bad", action: "south", x: 0, y: 0, width: .nan, height: 1)
  #expect(throws: InputError.invalidMap) {
    try engine.activate(ControlMap(generation: "2", revision: "1", controls: [region]))
  }
  #expect(engine.connected && engine.state.buttons == [.south])
  #expect(throws: InputError.invalidMap) {
    try engine.activate(
      ControlMap(
        generation: "18446744073709551616", revision: "1", controls: mobileFixture.map.controls))
  }
  #expect(engine.generation == "1")
}
@Test @MainActor private func touchBoundAndNonfiniteValuesFailClosed() throws {
  let engine = InputEngine(output: { _ in true })
  try engine.activate(mobileFixture.map)
  try engine.connect(generation: "1")
  for id in 0..<16 { #expect(engine.begin(id: UInt64(id), generation: "1", x: 0.67, y: 0.1)) }
  #expect(!engine.begin(id: 16, generation: "1", x: 0.67, y: 0.1))
  #expect(!engine.connected && engine.state.buttons.isEmpty)
  try engine.activate(
    ControlMap(generation: "2", revision: "1", controls: mobileFixture.map.controls))
  try engine.connect(generation: "2")
  #expect(!engine.begin(id: 1, generation: "2", x: .nan, y: 0.1))
  #expect(!engine.connected)
}
@Test @MainActor private func nativeTransportFailureCannotKeepOrReplayHeldTouches() throws {
  var available = true
  let engine = InputEngine(output: { _ in available })
  try engine.activate(mobileFixture.map)
  try engine.connect(generation: "1")
  engine.begin(id: 1, generation: "1", x: 0.67, y: 0.1)
  available = false
  engine.tick()
  #expect(
    !engine.connected && engine.state.buttons.isEmpty && engine.lastRelease == .transportFailure)
  #expect(throws: InputError.freshGenerationRequired) { try engine.connect(generation: "1") }
}
@Test @MainActor private func disposalStopsCallbacksAndPreservesItsTerminalReason() throws {
  var emissions = 0
  let engine = InputEngine(output: { _ in
    emissions += 1
    return true
  })
  try engine.activate(mobileFixture.map)
  try engine.connect(generation: "1")
  engine.setPractice(false)
  engine.begin(id: 1, generation: "1", x: 0.67, y: 0.1)
  #expect(engine.state.buttons == [.south])
  engine.cancel(.disposed)
  let finalCount = emissions
  engine.tick()
  engine.cancel(.background)
  #expect(emissions == finalCount && engine.lastRelease == .disposed)
  #expect(MemoryLayout<GamepadStateV1>.size <= 64)
  #expect(MemoryLayout<ControlMap>.size <= 64)
}
