import Foundation
import UIKit

/// Temporary simulator diagnostic, never linked into the product or SDK.
@main @MainActor final class ProbeApp: UIResponder, UIApplicationDelegate {
  var window: UIWindow?
  struct Result: Codable {
    let client: String
    let ok: Bool
    let errorCode: Int
  }
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = UIViewController()
    window.makeKeyAndVisible()
    self.window = window
    guard CommandLine.arguments.count == 2,
      let port = UInt16(CommandLine.arguments[1]), port > 0,
      let url = URL(string: "http://127.0.0.1:\(port)/health")
    else { return false }
    Task { await run(url) }
    return true
  }
  private func run(_ url: URL) async {
    let ephemeral = URLSession(configuration: .ephemeral)
    defer { ephemeral.invalidateAndCancel() }
    var results: [Result] = []
    for (name, session) in [("shared", URLSession.shared), ("ephemeral", ephemeral)] {
      var request = URLRequest(url: url)
      request.timeoutInterval = 6
      do {
        let (data, response) = try await session.data(for: request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Bool]
        let ok = (response as? HTTPURLResponse)?.statusCode == 200 && object == ["ok": true]
        results.append(Result(client: name, ok: ok, errorCode: 0))
      } catch {
        results.append(Result(client: name, ok: false, errorCode: (error as NSError).code))
      }
    }
    // Only fixed client names, booleans and numeric error codes leave this app.
    do {
      let documents = try FileManager.default.url(
        for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      try JSONEncoder().encode(results).write(
        to: documents.appendingPathComponent("result.json"), options: .atomic)
    } catch { /* The runner separately fails if a bounded result is missing. */  }
  }
}
