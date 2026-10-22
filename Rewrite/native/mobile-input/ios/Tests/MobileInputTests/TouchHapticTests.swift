import Foundation
import Testing

@testable import MobileInputCore

@Test @MainActor private func touchHapticsUseRetainedBoundedFallbackSchedules() {
  let double = TouchHapticPolicy().schedule(
    TouchHapticFeedback(pattern: .double, intensity: 1, duration: 0.3), nowMilliseconds: 0)
  #expect(double.map(\.delayMilliseconds) == [0, 180])
  #expect(double.map(\.intensity) == [1, 0.85])
  let buzz = TouchHapticPolicy().schedule(
    TouchHapticFeedback(pattern: .buzz, duration: 0.3), nowMilliseconds: 0)
  #expect(buzz.count == 6)
  #expect(buzz.last?.delayMilliseconds == 225)
  for pattern in [TouchHapticFeedback.Pattern.single, .pulse] {
    #expect(
      TouchHapticPolicy().schedule(TouchHapticFeedback(pattern: pattern), nowMilliseconds: 0).count
        == 1)
  }
}
@Test @MainActor private func touchHapticOptoutNoneAndRateGateCannotBeBypassedWithRollback() {
  let p = TouchHapticPolicy()
  let f = TouchHapticFeedback()
  #expect(p.schedule(f, nowMilliseconds: 0, intensityScale: 0).isEmpty)
  #expect(p.schedule(f, nowMilliseconds: 0, enabled: false).isEmpty)
  #expect(p.schedule(TouchHapticFeedback(style: .none), nowMilliseconds: 0).isEmpty)
  #expect(p.schedule(f, nowMilliseconds: 100, intensityScale: 0.5).first?.intensity == 0.225)
  #expect(p.schedule(f, nowMilliseconds: 149).isEmpty)
  #expect(p.schedule(f, nowMilliseconds: 99).isEmpty)
  #expect(p.schedule(f, nowMilliseconds: 150).count == 1)
}
@Test private func touchHapticMetadataRejectsUnknownFieldsAndInvalidNumbers() throws {
  let valid =
    #"{"style":"light","pattern":"single","intensity":0.45,"sharpness":0.48,"duration":0.06}"#
  #expect(
    try JSONDecoder().decode(TouchHapticFeedback.self, from: Data(valid.utf8))
      == TouchHapticFeedback())
  for source in [
    valid.replacingOccurrences(of: "\"light\"", with: "\"invalid\""),
    valid.replacingOccurrences(of: "0.06", with: "0.31"),
    valid.replacingOccurrences(of: "0.45", with: "true"),
    valid.replacingOccurrences(of: "0.48", with: "-1"),
    valid.replacingOccurrences(of: "}", with: ",\"extra\":true}"),
  ] {
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(TouchHapticFeedback.self, from: Data(source.utf8))
    }
  }
  #expect(!TouchHapticFeedback(intensity: .nan).valid)
  #expect(!TouchHapticFeedback(duration: .infinity).valid)
}
