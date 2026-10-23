import Foundation
import Testing

@testable import MobileInputCore

private let qrInvitation = """
  {"host":"192.0.2.1","port":8765,"certificatePin":"\(String(repeating:"a",count:64))","authorityInstanceId":"synthetic-authority","windowId":"synthetic-window","secret":"\(String(repeating:"b",count:64))","expiresAt":100000}
  """
@Test func qrScanRequiresPermissionAndAcceptsExactlyOneStrictNativeInvitation() throws {
  var scan = PairingQRSession()
  let result1 = scan.receive(qrInvitation)
  #expect(result1 == nil)
  let result2 = scan.authorize(true)
  #expect(result2)
  let result3 = scan.receive("{\"type\":\"pocketpad-pair\",\"urls\":[\"ws://192.0.2.1\"]}")
  #expect(result3 == nil)
  let result4 = scan.receive(String(repeating: "x", count: 4097))
  #expect(result4 == nil)
  let duplicate = scan.receive(
    qrInvitation.replacingOccurrences(of: "\"port\":8765", with: "\"port\":8765,\"port\":8765"))
  #expect(duplicate == nil)
  let received = scan.receive(qrInvitation)
  let admitted = try #require(received)
  #expect(admitted.host == "192.0.2.1" && admitted.port == 8765)
  #expect(admitted.authorityInstanceID == "synthetic-authority")
  #expect(String(describing: admitted) == "EnrollmentInvitation([redacted])")
  let result5 = scan.receive(qrInvitation)
  #expect(result5 == nil)
  let result6 = scan.authorize(true)
  #expect(!result6)
}
@Test func cancelledOrDeniedQrPermissionCannotStartOrDeliverLater() {
  var cancelled = PairingQRSession()
  cancelled.close()
  let result7 = cancelled.authorize(true)
  #expect(!result7)
  let result8 = cancelled.receive(qrInvitation)
  #expect(result8 == nil)
  var denied = PairingQRSession()
  let result9 = denied.authorize(false)
  #expect(!result9)
  let result10 = denied.authorize(true)
  #expect(!result10)
  let result11 = denied.receive(qrInvitation)
  #expect(result11 == nil)
  var active = PairingQRSession()
  let result12 = active.authorize(true)
  #expect(result12)
  active.close()
  let result13 = active.receive(qrInvitation)
  #expect(result13 == nil)
}
