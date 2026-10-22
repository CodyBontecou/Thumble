import Foundation
import MobileInputCore
import ThumbleContracts
import UIKit

/// App-owned native bootstrap. Invitation text, vault material and channels never enter React.
@MainActor final class PhoneConnection: NSObject, UITextFieldDelegate {
  private weak var anchor: UIView?
  private var prompt: UIAlertController?
  private var task: Task<Void, Never>?
  private var enrollment: PhoneEnrollmentClient?
  private var control: PhoneControlClient?
  private let storage = PhoneCredentialWorker()
  private var closed = false
  private let feedback: (GamepadStateV1) -> Void
  private let install: (InputEngine) throws -> Void
  private let status: (String) -> Void
  private static let endpointKey = "rewrite.phone.endpoint.v1"
  init(
    anchor: UIView, feedback: @escaping (GamepadStateV1) -> Void,
    install: @escaping (InputEngine) throws -> Void, status: @escaping (String) -> Void
  ) {
    self.anchor = anchor
    self.feedback = feedback
    self.install = install
    self.status = status
    super.init()
    NotificationCenter.default.addObserver(
      self, selector: #selector(background),
      name: UIApplication.willResignActiveNotification, object: nil)
  }
  func start(template: ControlMap) {
    guard !closed, prompt == nil, task == nil, let anchor,
      let root = anchor.window?.rootViewController
    else { return }
    var presenter = root
    while let next = presenter.presentedViewController { presenter = next }
    let alert = UIAlertController(
      title: "Connect to your computer",
      message: "Paste the pairing invitation from your agent. It stays on this phone.",
      preferredStyle: .alert)
    alert.addTextField { field in
      field.placeholder = "Pairing invitation"
      field.accessibilityIdentifier = "pairing-invitation"
      field.delegate = self
      field.isSecureTextEntry = true
      field.autocorrectionType = .no
      field.autocapitalizationType = .none
      field.smartQuotesType = .no
      field.smartDashesType = .no
      field.spellCheckingType = .no
    }
    alert.addAction(
      UIAlertAction(title: "Cancel", style: .cancel) { [weak self, weak alert] _ in
        alert?.textFields?.first?.text = nil
        self?.close()
        self?.status("cancelled")
      })
    if Self.savedEndpoint() != nil {
      alert.addAction(
        UIAlertAction(title: "Reconnect", style: .default) { [weak self] _ in
          self?.reconnect(template: template)
        })
    }
    alert.addAction(
      UIAlertAction(title: "Pair", style: .default) { [weak self, weak alert] _ in
        self?.submitInvitation(alert?.textFields?.first?.text ?? "", template: template)
      })
    prompt = alert
    status("waiting")
    presenter.present(alert, animated: true)
  }
  // Native camera/manual entry points have no secret-bearing React representation.
  func submitInvitation(_ text: String, template: ControlMap) {
    guard !closed else { return }
    prompt?.textFields?.first?.text = nil
    guard text.utf8.count <= 4096,
      let invitation = try? EnrollmentInvitation.decode(Data(text.utf8))
    else {
      fail()
      return
    }
    afterPrompt { [weak self] in self?.pair(invitation, template: template) }
  }
  func reconnect(template: ControlMap) {
    guard !closed, let endpoint = Self.savedEndpoint() else {
      fail()
      return
    }
    prompt?.textFields?.first?.text = nil
    afterPrompt { [weak self] in self?.connect(endpoint, template: template) }
  }
  private func afterPrompt(_ action: @escaping @MainActor () -> Void) {
    let previous = prompt
    prompt = nil
    if let previous { previous.dismiss(animated: true, completion: action) } else { action() }
  }
  private func pair(_ invitation: EnrollmentInvitation, template: ControlMap) {
    guard !closed, anchor?.window?.isKeyWindow == true,
      UIApplication.shared.applicationState == .active
    else { return }
    status("pairing")
    task = Task { [weak self] in
      guard let self else { return }
      do {
        let client = try PhoneEnrollmentClient(invitation: invitation, storage: storage)
        enrollment = client
        let defaults = UserDefaults.standard
        let phoneID = defaults.string(forKey: "rewrite.phone.id") ?? UUID().uuidString.lowercased()
        defaults.set(phoneID, forKey: "rewrite.phone.id")
        _ = try await client.enroll(phoneID: phoneID, label: "Thumble iPhone")
        client.close()
        enrollment = nil
        try Task.checkCancellation()
        guard !closed, anchor?.window?.isKeyWindow == true,
          UIApplication.shared.applicationState == .active
        else { throw InputError.unavailable }
        let endpoint = try TrustedHostEndpoint(
          host: invitation.host, port: invitation.port,
          certificatePin: invitation.certificatePin,
          authorityInstanceID: invitation.authorityInstanceID)
        Self.save(endpoint)
        try await bind(endpoint, template: template)
      } catch {
        fail()
      }
    }
  }
  private func connect(_ endpoint: TrustedHostEndpoint, template: ControlMap) {
    guard !closed, anchor?.window?.isKeyWindow == true,
      UIApplication.shared.applicationState == .active
    else { return }
    task = Task { [weak self] in
      guard let self else { return }
      do { try await bind(endpoint, template: template) } catch { fail() }
    }
  }
  private func bind(_ endpoint: TrustedHostEndpoint, template: ControlMap) async throws {
    try Task.checkCancellation()
    guard !closed, anchor?.window?.isKeyWindow == true,
      UIApplication.shared.applicationState == .active
    else { throw InputError.unavailable }
    status("connecting")
    let client = try PhoneControlClient(
      endpoint: endpoint, storage: storage,
      inputSessions: true, datagrams: true)
    control = client
    guard try await client.authenticate().inputSessionAvailable else {
      throw InputError.unavailable
    }
    let metadata = try await client.inputConfiguration()
    guard metadata.active else {
      throw InputError.unavailable
    }
    let map = ControlMap(
      generation: metadata.generation, revision: metadata.revision, controls: template.controls)
    let engine = try await client.bindInput(map, feedback: feedback)
    try Task.checkCancellation()
    guard !closed, anchor?.window?.isKeyWindow == true,
      UIApplication.shared.applicationState == .active
    else {
      engine.cancel(.disconnected)
      throw InputError.unavailable
    }
    try install(engine)
  }
  private func fail() {
    guard !closed else { return }
    close()
    status("unavailable")
  }
  func close() {
    guard !closed else { return }
    closed = true
    NotificationCenter.default.removeObserver(self)
    task?.cancel()
    task = nil
    enrollment?.close()
    enrollment = nil
    control?.close()
    control = nil
    prompt?.textFields?.first?.text = nil
    prompt?.dismiss(animated: false)
    prompt = nil
  }
  @objc private func background() {
    guard !closed else { return }
    close()
    status("disconnected")
  }
  func textField(
    _ textField: UITextField, shouldChangeCharactersIn range: NSRange,
    replacementString string: String
  ) -> Bool {
    let current = textField.text ?? ""
    guard string.utf8.count <= 4096, let boundedRange = Range(range, in: current)
    else { return false }
    return current.replacingCharacters(in: boundedRange, with: string).utf8.count <= 4096
  }
  private static func save(_ endpoint: TrustedHostEndpoint) {
    UserDefaults.standard.set(
      [
        "host": endpoint.host, "port": Int(endpoint.port),
        "pin": endpoint.certificatePin, "authority": endpoint.authorityInstanceID,
      ], forKey: endpointKey)
  }
  private static func savedEndpoint() -> TrustedHostEndpoint? {
    guard let value = UserDefaults.standard.dictionary(forKey: endpointKey),
      Set(value.keys) == Set(["host", "port", "pin", "authority"]),
      let host = value["host"] as? String, let port = value["port"] as? Int,
      let boundedPort = UInt16(exactly: port), let pin = value["pin"] as? String,
      let authority = value["authority"] as? String
    else { return nil }
    return try? TrustedHostEndpoint(
      host: host, port: boundedPort,
      certificatePin: pin, authorityInstanceID: authority)
  }
}
