import Foundation
import Testing
import ThumbleContracts

@testable import MobileInputCore

private func bankFixture() throws -> [String: Any] {
  let url = try #require(
    Bundle.module.url(
      forResource: "saved-controller-presentation-control-v11", withExtension: "json",
      subdirectory: "Fixtures"))
  return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}
private func bankRequest(_ fields: [String: Any]) throws -> PhonePresentationRequest {
  let name = try #require(fields["bank"] as? String)
  let bank = try #require(PhonePresentationBank(rawValue: name))
  return try PhonePresentationRequest(
    saved: SavedControllerRequest(
      configurationRevision: "3", sourceHash: String(repeating: "a", count: 64),
      profileID: "aaaaaaaa-0000-0000-0000-000000000001", generation: "7", revision: "2",
      viewportWidth: "874", viewportHeight: "393"),
    map: SavedControllerMap(
      map: ControlMap(
        generation: "7", revision: "2",
        controls: [
          ControlRegion(
            id: "synthetic-south", action: "south", x: 0.1, y: 0.2, width: 0.15, height: 0.3),
          ControlRegion(
            id: "synthetic-east", action: "east", x: 0.5, y: 0.2, width: 0.15, height: 0.3),
        ]), configurationSha256: String(repeating: "b", count: 64)),
    colorScheme: try #require(fields["colorScheme"] as? String), bank: bank)
}
private func bankFields(_ fields: [String: Any]) throws -> [String: EnrollmentJSON.Value] {
  try EnrollmentJSON.parse(JSONSerialization.data(withJSONObject: fields))
}
@Test private func bankPresentationAllEightSharedVariantsKeepFullContextAndVerifiedIcons() throws {
  let variants = try #require(bankFixture()["variants"] as? [[String: Any]])
  #expect(variants.count == 8)
  var hashes: Set<String> = []
  for variant in variants {
    let requestFields = try #require(variant["request"] as? [String: Any])
    let request = try bankRequest(requestFields)
    #expect(
      NSDictionary(dictionary: request.fields(connection: String(repeating: "cd", count: 16)))
        .isEqual(to: requestFields))
    let metadata = try PhonePresentationWire.metadata(
      bankFields(try #require(variant["reply"] as? [String: Any])), request: request,
      authority: "synthetic-authority", connection: String(repeating: "cd", count: 16))
    let event = metadata.bridgeEvent
    #expect(event["presentationProtocol"] as? Int == 2)
    #expect(event["authorityInstanceId"] as? String == "synthetic-authority")
    #expect(event["bank"] as? String == request.bank?.rawValue)
    #expect(
      event["viewportWidth"] as? String == "874" && event["viewportHeight"] as? String == "393")
    let selection = try request.bankNotification(authority: "synthetic-authority")
    #expect(
      selection["kind"] as? String == "bank" && selection["presentationRevision"] == nil
        && selection["controls"] == nil)
    let icon = try PhonePresentationWire.icon(
      bankFields(try #require(variant["iconReply"] as? [String: Any])), metadata: metadata,
      control: metadata.controls[0], authority: "synthetic-authority",
      connection: String(repeating: "cd", count: 16))
    hashes.insert(icon.sha256)
    let iconEvent = try icon.notification(metadata: metadata, controlId: "synthetic-south")
    #expect(iconEvent["bank"] as? String == request.bank?.rawValue)
    #expect(iconEvent["authorityInstanceId"] as? String == "synthetic-authority")
    #expect(iconEvent["profileName"] == nil && iconEvent["freshness"] == nil)
  }
  #expect(hashes.count == 8)
}
@Test(arguments: ["version", "bank", "missing-bank", "authority", "viewport", "epoch", "extra"])
private func bankPresentationRejectsCrossContextAndProtocolDowngrade(_ fault: String) throws {
  let fixture = try bankFixture()
  let request = try bankRequest(try #require(fixture["request"] as? [String: Any]))
  var reply = try #require(fixture["reply"] as? [String: Any])
  switch fault {
  case "version": reply["version"] = 1
  case "bank": reply["bank"] = "left-trigger"
  case "missing-bank": reply.removeValue(forKey: "bank")
  case "authority": reply["authorityInstanceId"] = "other-authority"
  case "viewport": reply["viewportWidth"] = "874.0"
  case "epoch": reply["generation"] = "8"
  default: reply["unknown"] = true
  }
  #expect(throws: PhonePresentationError.self) {
    try PhonePresentationWire.metadata(
      bankFields(reply), request: request, authority: "synthetic-authority",
      connection: String(repeating: "cd", count: 16))
  }
}
@Test private func bankSelectionUsesSemanticThresholdNotRoundedWireValue() {
  func state(_ left: Double, _ right: Double) -> GamepadStateV1 {
    GamepadStateV1(
      buttons: [], leftStickX: 0, leftStickY: 0, rightStickX: 0, rightStickY: 0, leftTrigger: left,
      rightTrigger: right)
  }
  #expect(PhonePresentationBank(accepted: state(0.5, 0.5)) == .base)
  #expect(PhonePresentationBank(accepted: state(0.500001, 0.5)) == .leftTrigger)
  #expect(PhonePresentationBank(accepted: state(0.5, 0.500001)) == .rightTrigger)
  #expect(PhonePresentationBank(accepted: state(1, 1)) == .bothTriggers)
  #expect(PhonePresentationBank(accepted: .neutral) == .base)
}
