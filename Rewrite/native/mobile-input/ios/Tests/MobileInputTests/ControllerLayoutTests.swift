import Foundation
import Testing
import ThumbleContracts

@testable import MobileInputCore

private struct ControllerFixture: Decodable {
  let map: ControlMap
  let probes: [Probe]
  let chord: Chord
  struct Chord: Decodable {
    let ids: [String]
    let reportHex: String
  }
  struct Probe: Decodable {
    let id: String
    let x: Double
    let y: Double
    let reportHex: String
  }
}
@Test @MainActor private func standardControllerNativeHitTestingAndPracticeFeedback() throws {
  let url = try #require(
    Bundle.module.url(
      forResource: "controller-layout-v1", withExtension: "json", subdirectory: "Fixtures"))
  let fixture = try JSONDecoder().decode(ControllerFixture.self, from: Data(contentsOf: url))
  #expect(fixture.probes.count == 19)
  for practice in [false, true] {
    for probe in fixture.probes {
      var samples: [InputSample] = []
      var feedback: [String] = []
      let engine = InputEngine(
        output: {
          samples.append($0)
          return true
        }, feedback: { feedback.append(GamepadReport.hex($0)) })
      try engine.activate(fixture.map)
      if practice {
        engine.setPractice(true)
      } else {
        try engine.connect(generation: fixture.map.generation)
      }
      #expect(engine.begin(id: 1, generation: fixture.map.generation, x: probe.x, y: probe.y))
      engine.tick()
      #expect(GamepadReport.hex(engine.state) == probe.reportHex, "\(probe.id)")
      #expect(feedback.last == probe.reportHex)
      #expect(
        practice
          ? samples.isEmpty : samples.last.map { GamepadReport.hex($0.state) } == probe.reportHex)
      engine.cancel(.background)
      engine.move(id: 1, generation: fixture.map.generation, x: probe.x, y: probe.y)
      #expect(GamepadReport.hex(engine.state) == GamepadReport.hex(.neutral))
      #expect(feedback.last == GamepadReport.hex(.neutral))
      #expect(!engine.connected)
    }
    var sent: [String] = []
    let chordEngine = InputEngine(output: {
      sent.append(GamepadReport.hex($0.state))
      return true
    })
    try chordEngine.activate(fixture.map)
    if practice {
      chordEngine.setPractice(true)
    } else {
      try chordEngine.connect(generation: fixture.map.generation)
    }
    for (index, id) in fixture.chord.ids.enumerated() {
      let probe = try #require(fixture.probes.first { $0.id == id })
      #expect(
        chordEngine.begin(
          id: UInt64(index + 1), generation: fixture.map.generation, x: probe.x, y: probe.y))
    }
    for _ in 0..<100 {
      chordEngine.tick()
      #expect(GamepadReport.hex(chordEngine.state) == fixture.chord.reportHex)
    }
    #expect(practice ? sent.isEmpty : sent.last == fixture.chord.reportHex)
    chordEngine.cancel(.rotation)
    #expect(GamepadReport.hex(chordEngine.state) == GamepadReport.hex(.neutral))
    if !practice { #expect(sent.last == GamepadReport.hex(.neutral)) }
  }
}
