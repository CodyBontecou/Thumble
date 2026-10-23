import UIKit

/// A route-scoped geometry request, never an input or viewport admission.
@MainActor enum ControllerOrientation {
  private struct Lease {
    let token: String
    weak var scene: UIWindowScene?
    let original: UIInterfaceOrientationMask
  }
  private static var lease: Lease?
  static func request() throws -> String {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .filter {
        $0.activationState == .foregroundActive && $0.windows.contains(where: \.isKeyWindow)
      }
    guard scenes.count == 1, let scene = scenes.first else { throw Failure.unavailable }
    let original: UIInterfaceOrientationMask
    if let previous = lease, previous.scene === scene {
      original = previous.original
    } else {
      switch scene.effectiveGeometry.interfaceOrientation {
      case .portrait: original = .portrait
      case .portraitUpsideDown: original = .portraitUpsideDown
      case .landscapeLeft: original = .landscapeLeft
      case .landscapeRight: original = .landscapeRight
      default: throw Failure.unavailable
      }
    }
    let token = UUID().uuidString.lowercased()
    lease = Lease(token: token, scene: scene, original: original)
    scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { _ in
      // Rejection leaves the existing rotate instruction and actual-size admission in force.
    }
    return token
  }
  @discardableResult static func restore(_ token: String) -> Bool {
    guard token.utf8.count <= 64, let current = lease, current.token == token else { return false }
    lease = nil
    guard let scene = current.scene else { return false }
    scene.requestGeometryUpdate(.iOS(interfaceOrientations: current.original)) { _ in }
    return true
  }
  private enum Failure: Error { case unavailable }
}
