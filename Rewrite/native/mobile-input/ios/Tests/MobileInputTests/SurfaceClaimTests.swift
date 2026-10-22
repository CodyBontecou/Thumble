import Testing

@testable import MobileInputCore

@MainActor private func claimMap(_ generation: String = "7") -> ControlMap {
  ControlMap(
    generation: generation, revision: "4",
    controls: [
      ControlRegion(id: "face", action: "south", x: 0, y: 0, width: 1, height: 1)
    ])
}
@Test @MainActor private func surfaceClaimPreservesTheBoundGenerationAndPacketSequence() throws {
  var samples: [InputSample] = []
  let engine = InputEngine(output: {
    samples.append($0)
    return true
  })
  try engine.activate(claimMap())
  try engine.connect(generation: "7")
  let map = try engine.claimTouchSurface()
  #expect(map.generation == "7" && map.revision == "4")
  #expect(map.controls.first?.id == "face")
  #expect(engine.connected && samples.count == 1 && samples[0].sequence == "0")
  #expect(engine.begin(id: 1, generation: "7", x: 0.5, y: 0.5))
  #expect(samples.count == 2 && samples[1].sequence == "1")
  #expect(throws: InputError.unavailable) { try engine.claimTouchSurface() }
  #expect(engine.connected && engine.state.buttons.count == 1)
  engine.cancel(.disconnected)
  try engine.activate(claimMap("8"))
  try engine.connect(generation: "8")
  #expect(throws: InputError.unavailable) { try engine.claimTouchSurface() }
}
@Test @MainActor private func surfaceClaimRejectsInactivePracticeAndPreviouslySampledEngines()
  throws
{
  let engine = InputEngine(output: { _ in true })
  #expect(throws: InputError.unavailable) { try engine.claimTouchSurface() }
  try engine.activate(claimMap())
  engine.setPractice(true)
  #expect(throws: InputError.unavailable) { try engine.claimTouchSurface() }
  engine.setPractice(false)
  try engine.connect(generation: "7")
  engine.tick()
  #expect(throws: InputError.unavailable) { try engine.claimTouchSurface() }
  #expect(engine.connected)
  let failed = InputEngine(output: { _ in false })
  try failed.activate(claimMap())
  try failed.connect(generation: "7")
  #expect(!failed.connected)
  #expect(throws: InputError.unavailable) { try failed.claimTouchSurface() }
}
@Test @MainActor private func surfaceClaimCannotReenterPublicationOrConsumeTheHandoffOnFailure()
  throws
{
  var reenter: (() -> Void)?
  let engine = InputEngine(output: { _ in true }, feedback: { _ in reenter?() })
  reenter = { #expect(throws: InputError.reentrant) { try engine.claimTouchSurface() } }
  try engine.activate(claimMap())
  try engine.connect(generation: "7")
  reenter = nil
  #expect(try engine.claimTouchSurface().generation == "7")
}
