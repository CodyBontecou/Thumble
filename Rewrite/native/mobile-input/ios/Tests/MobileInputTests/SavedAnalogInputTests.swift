import Foundation
import Testing

@testable import MobileInputCore

private func savedAnalogGolden() throws -> ControlMap {
  let url = try #require(
    Bundle.module.url(
      forResource: "saved-controller-analog-control-v8", withExtension: "json",
      subdirectory: "Fixtures"))
  let fixture = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  let request = try #require(fixture["request"] as? [String: Any])
  let fields = try #require(fixture["reply"] as? [String: Any])
  func text(_ key: String) throws -> String { try #require(request[key] as? String) }
  return try SavedControllerWire.decode(
    EnrollmentJSON.parse(JSONSerialization.data(withJSONObject: fields), allowNull: true),
    request: SavedControllerRequest(
      configurationRevision: text("expectedConfigurationRevision"),
      sourceHash: text("expectedSourceHash"), profileID: text("profileId"),
      generation: text("generation"), revision: text("revision"),
      viewportWidth: text("viewportWidth"), viewportHeight: text("viewportHeight")),
    authority: "synthetic-authority", connection: text("connectionId")
  ).map
}
@MainActor private func analogEngine(_ map: ControlMap) throws -> InputEngine {
  let engine = InputEngine(output: { _ in true })
  try engine.activate(map)
  try engine.connect(generation: map.generation)
  return engine
}
@MainActor private func begin(
  _ engine: InputEngine, _ region: ControlRegion, id: UInt64 = 1, x: Double, y: Double
) -> Bool {
  engine.begin(
    id: id, generation: engine.generation, x: region.x + x * region.width,
    y: region.y + y * region.height)
}
@MainActor private func move(
  _ engine: InputEngine, _ region: ControlRegion, id: UInt64 = 1, x: Double, y: Double
) {
  engine.move(
    id: id, generation: engine.generation, x: region.x + x * region.width,
    y: region.y + y * region.height)
}
private func near(_ actual: Double, _ expected: Double) -> Bool {
  abs(actual - expected) < 0.0000001
}

@Test @MainActor func savedAnalogGoldenUsesRetainedPadGeometryAndRadialDeadzone() throws {
  let map = try savedAnalogGolden()
  #expect(
    map.controls.map(\.action) == [
      "leftStandardStick", "rightStandardStick", "leftVerticalTrigger", "rightHorizontalTrigger",
      "south",
    ])
  #expect(near(map.controls[0].width * 874, 117.9))
  #expect(near(map.controls[2].height * 393, 43.23))
  for index in [0, 1] {
    let region = map.controls[index]
    let engine = try analogEngine(map)
    #expect(begin(engine, region, x: 0.55, y: 0.5))
    for (x, y, expectedX, expectedY) in [
      (0.55, 0.5, 0.0, 0.0), (0.78, 0.5, 0.5, 0.0), (1.0, 1.0, sqrt(0.5), sqrt(0.5)),
      (0.0, 0.5, -1.0, 0.0), (-2.0, 0.5, -1.0, 0.0),
    ] {
      move(engine, region, x: x, y: y)
      #expect(near(index == 0 ? engine.state.leftStickX : engine.state.rightStickX, expectedX))
      #expect(near(index == 0 ? engine.state.leftStickY : engine.state.rightStickY, expectedY))
    }
    engine.end(id: 1, generation: map.generation)
    #expect(GamepadReport.hex(engine.state) == GamepadReport.hex(.neutral))
    #expect(engine.connected)
  }
}
@Test(arguments: [
  "leftVerticalTrigger", "rightVerticalTrigger", "leftHorizontalTrigger", "rightHorizontalTrigger",
])
@MainActor func savedAnalogSlidersAreContinuousCapturedAndNeutralOnEnd(_ action: String) throws {
  let region = ControlRegion(id: "slider", action: action, x: 0.1, y: 0.1, width: 0.8, height: 0.8)
  let engine = try analogEngine(ControlMap(generation: "7", revision: "2", controls: [region]))
  #expect(begin(engine, region, x: 0.5, y: 0.5))
  let vertical = action.hasSuffix("VerticalTrigger")
  for (raw, expected) in [(0.02, 0.0), (0.515, 0.5), (1.0, 1.0), (2.0, 1.0), (-1.0, 0.0)] {
    move(engine, region, x: vertical ? 0.5 : raw, y: vertical ? 1 - raw : 0.5)
    #expect(
      near(
        action.hasPrefix("left") ? engine.state.leftTrigger : engine.state.rightTrigger, expected))
  }
  engine.end(id: 1, generation: "7")
  #expect(GamepadReport.hex(engine.state) == GamepadReport.hex(.neutral))
}
@Test @MainActor func savedAnalogAliasesCannotStealAnExistingPhysicalCapture() throws {
  for (old, new) in [
    ("leftStick", "leftStandardStick"), ("rightStick", "rightStandardStick"),
    ("leftTrigger", "leftVerticalTrigger"), ("rightTrigger", "rightHorizontalTrigger"),
  ] {
    let a = ControlRegion(id: "old", action: old, x: 0, y: 0, width: 0.4, height: 1)
    let b = ControlRegion(id: "new", action: new, x: 0.5, y: 0, width: 0.4, height: 1)
    for first in [a, b] {
      let other = first.id == a.id ? b : a
      let engine = try analogEngine(ControlMap(generation: "7", revision: "2", controls: [a, b]))
      #expect(begin(engine, first, x: 0.75, y: 0.5))
      let held = GamepadReport.hex(engine.state)
      #expect(!begin(engine, other, id: 2, x: 0.75, y: 0.5))
      #expect(GamepadReport.hex(engine.state) == held)
      engine.end(id: 1, generation: "7")
      #expect(begin(engine, other, id: 2, x: 0.75, y: 0.5))
      engine.cancel(.background)
      #expect(!engine.connected && GamepadReport.hex(engine.state) == GamepadReport.hex(.neutral))
      move(engine, other, id: 2, x: 1, y: 0)
      #expect(GamepadReport.hex(engine.state) == GamepadReport.hex(.neutral))
    }
  }
}
@Test @MainActor func savedAnalogLegacyLinearStickAndBinaryTriggerRemainUnchanged() throws {
  for action in ["leftStick", "rightStick", "leftTrigger", "rightTrigger"] {
    let region = ControlRegion(
      id: "legacy", action: action, x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    let engine = try analogEngine(ControlMap(generation: "7", revision: "2", controls: [region]))
    #expect(begin(engine, region, x: 0.55, y: 0.5))
    if action.hasSuffix("Stick") {
      #expect(
        near(action.hasPrefix("left") ? engine.state.leftStickX : engine.state.rightStickX, 0.1))
    } else {
      #expect(
        (action.hasPrefix("left") ? engine.state.leftTrigger : engine.state.rightTrigger) == 1)
      move(engine, region, x: 1.1, y: 0.5)
      #expect(GamepadReport.hex(engine.state) == GamepadReport.hex(.neutral))
    }
  }
}
