import Foundation

/// One explicit scan's admission. Camera permission alone never grants trust or input.
public struct PairingQRSession: Sendable {
  private enum State: Sendable { case awaitingPermission, scanning, closed }
  private var state: State = .awaitingPermission
  public init() {}
  /// A late permission callback cannot reopen a cancelled or completed scan.
  public mutating func authorize(_ granted: Bool) -> Bool {
    guard state == .awaitingPermission else { return false }
    state = granted ? .scanning : .closed
    return granted
  }
  /// Invalid codes leave the scan available; only the native invitation codec admits a result.
  public mutating func receive(_ text: String) -> EnrollmentInvitation? {
    guard state == .scanning, text.utf8.count <= 4096,
      let invitation = try? EnrollmentInvitation.decode(Data(text.utf8))
    else { return nil }
    state = .closed
    return invitation
  }
  public mutating func close() { state = .closed }
}
