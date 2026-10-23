import Foundation
import MobileInputCore
import MobileInputUIKit
import ThumbleContracts
import UIKit

#if DEBUG
  import os
#endif

/// App-owned native bootstrap. Invitation text, vault material and channels never enter React.
@MainActor final class PhoneConnection: NSObject, UITextFieldDelegate {
  // [DEBUG-renewal-app] Temporary bounded admission evidence, never bridged to JS.
  enum DiagnosticPhase: String {
    case idle
    case pairRequested = "pair-requested"
    case enrolling
    case enrollmentIdle = "enrollment-idle"
    case enrollmentConnecting = "enrollment-connecting"
    case enrollmentNegotiating = "enrollment-negotiating"
    case enrollmentCredential = "enrollment-credential"
    case enrollmentStoring = "enrollment-storing"
    case enrollmentAcknowledging = "enrollment-acknowledging"
    case enrollmentConfirming = "enrollment-confirming"
    case enrollmentComplete = "enrollment-complete"
    case endpointSaved = "endpoint-saved"
    case controlRequested = "control-requested"
    case authenticating, configuration, input, installing, connected
  }
  private(set) var diagnosticPhase: DiagnosticPhase = .idle
  private(set) var diagnosticConnectOutcome: ControlTLSConnectOutcome = .idle
  #if DEBUG
    private enum SavedReadDiagnostic: String { case none, catalog, controls }
    private enum SavedReadFailure: String {
      case none, rejected, transport, other
      case busy = "saved_map_busy"
      case timeout = "saved_map_timeout"
      case unavailable = "saved_map_unavailable"
      case reactivation = "saved_map_reactivation_required"
      case unsupported = "saved_map_unsupported_profile"
      case oversized = "saved_map_response_too_large"
    }
    private var savedReadFailure: SavedReadFailure = .none
    private var savedReadDiagnostic: SavedReadDiagnostic = .none
  #endif
  private var lastControlFailure: PhoneControlFailureStage = .none
  private var lastRuntimeOutcome: ControlTLSRuntimeOutcome = .idle
  var diagnosticControlFailure: PhoneControlFailureStage {
    control?.diagnosticFailureStage ?? lastControlFailure
  }
  var diagnosticRuntimeOutcome: ControlTLSRuntimeOutcome {
    control?.diagnosticRuntimeOutcome ?? lastRuntimeOutcome
  }

  private weak var anchor: UIView?
  private var prompt: UIAlertController?
  private var scanner: PairingQRScanner?
  private var task: Task<Void, Never>?
  private var enrollment: PhoneEnrollmentClient?
  private var catalogClient: PhoneCatalogClient?
  private var savedMapClient: SavedControllerClient?
  private var presentationPoller: PhonePresentationPoller?
  private var authorityResolver: PhoneAuthorityResolver?
  private var control: PhoneControlClient?
  private let storage = PhoneCredentialWorker()
  private var closed = false
  private let feedback: (GamepadStateV1) -> Void
  private let install: (InputEngine) throws -> Void
  private let status: (String) -> Void
  private let catalogResult: ([String: Any]) -> Void
  private let installedMap: ([String: Any], String?) -> Void
  private let presentationResult: ([String: Any]) -> Void
  private let outputMode: PhoneOutputMode
  // Native test-host injection only. The product view never supplies this port.
  private let testOnlyMapProvider: ((PhoneInputConfiguration, CGSize) throws -> ControlMap)?
  private static let endpointKey = "rewrite.phone.endpoint.v1"
  init(
    anchor: UIView, feedback: @escaping (GamepadStateV1) -> Void,
    install: @escaping (InputEngine) throws -> Void, status: @escaping (String) -> Void,
    catalogResult: @escaping ([String: Any]) -> Void = { _ in },
    installedMap: @escaping ([String: Any], String?) -> Void = { _, _ in },
    presentationResult: @escaping ([String: Any]) -> Void = { _ in },
    testOnlyMapProvider: ((PhoneInputConfiguration, CGSize) throws -> ControlMap)? = nil,
    outputMode: PhoneOutputMode = .recording
  ) {
    self.anchor = anchor
    self.feedback = feedback
    self.install = install
    self.status = status
    self.catalogResult = catalogResult
    self.installedMap = installedMap
    self.presentationResult = presentationResult
    self.outputMode = outputMode
    self.testOnlyMapProvider = testOnlyMapProvider
    super.init()
    NotificationCenter.default.addObserver(
      self, selector: #selector(background),
      name: UIApplication.willResignActiveNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(enteredBackground),
      name: UIApplication.didEnterBackgroundNotification, object: nil)
  }
  func start(template: ControlMap? = nil) {
    guard !closed, prompt == nil, task == nil, let anchor,
      let root = anchor.window?.rootViewController
    else { return }
    var presenter = root
    while let next = presenter.presentedViewController { presenter = next }
    let alert = UIAlertController(
      title: outputMode == .macosHID ? "Connect to Mac" : "Test your connection",
      message: "Paste the pairing invitation from your agent. It stays on this phone.",
      preferredStyle: .alert)
    alert.addTextField { field in
      field.placeholder = "Pairing invitation"
      field.isEnabled = false
      field.accessibilityIdentifier = "pairing-invitation"
      field.delegate = self
      field.isSecureTextEntry = true
      field.returnKeyType = .done
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
    alert.addAction(
      UIAlertAction(title: "Scan Mac QR code", style: .default) { [weak self] _ in
        self?.afterPrompt { [weak self] in self?.scanInvitation(template: template) }
      })
    if Self.savedEndpoint() != nil {
      alert.addAction(
        UIAlertAction(title: "Reconnect", style: .default) { [weak self] _ in
          self?.reconnect(template: template)
        })
    }
    alert.addAction(
      UIAlertAction(
        title: TouchHapticPreferences.intensity() > 0
          ? "Turn touch feedback off" : "Turn touch feedback on", style: .default
      ) { [weak self, weak alert] _ in
        alert?.textFields?.first?.text = nil
        TouchHapticPreferences.setEnabled(TouchHapticPreferences.intensity() == 0)
        self?.afterPrompt { [weak self] in self?.start(template: template) }
      })
    alert.addAction(
      UIAlertAction(title: "Pair", style: .default) { [weak self, weak alert] _ in
        self?.submitInvitation(alert?.textFields?.first?.text ?? "", template: template)
      })
    prompt = alert
    status("waiting")
    presenter.present(alert, animated: true) { [weak alert] in
      // Keep native actions visible in landscape; invitation entry remains tap-to-edit.
      alert?.textFields?.first?.isEnabled = true
      alert?.textFields?.first?.resignFirstResponder()
    }
  }
  private func scanInvitation(template: ControlMap?) {
    guard !closed, scanner == nil, let root = anchor?.window?.rootViewController else { return }
    var presenter = root
    while let next = presenter.presentedViewController { presenter = next }
    let scanner = PairingQRScanner { [weak self] invitation in
      guard let self, !self.closed else { return }
      self.scanner = nil
      if let invitation {
        self.pair(invitation, template: template)
      } else {
        self.start(template: template)
      }
    }
    self.scanner = scanner
    presenter.present(scanner, animated: true)
  }
  // Native camera/manual entry points have no secret-bearing React representation.
  func submitInvitation(_ text: String, template: ControlMap? = nil) {
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
  func reconnect(template: ControlMap? = nil) {
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
  private func pair(_ invitation: EnrollmentInvitation, template: ControlMap? = nil) {
    diagnosticPhase = .pairRequested
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
        diagnosticPhase = .enrolling
        _ = try await client.enroll(phoneID: phoneID, label: "Thumble iPhone")
        diagnosticPhase = .enrollmentComplete
        diagnosticConnectOutcome = client.diagnosticConnectOutcome ?? .idle
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
        diagnosticPhase = .endpointSaved
        Self.save(endpoint)
        try await bind(endpoint, template: template)
      } catch {
        fail()
      }
    }
  }
  private func connect(_ endpoint: TrustedHostEndpoint, template: ControlMap? = nil) {
    guard !closed, anchor?.window?.isKeyWindow == true,
      UIApplication.shared.applicationState == .active
    else { return }
    task = Task { [weak self] in
      guard let self else { return }
      do {
        let resolver = try PhoneAuthorityResolver(endpoint: endpoint)
        authorityResolver = resolver
        let current = try await resolver.resolve()
        authorityResolver = nil
        try Task.checkCancellation()
        guard !closed else { throw InputError.unavailable }
        try await bind(current, template: template)
      } catch { fail() }
    }
  }
  private func bind(_ endpoint: TrustedHostEndpoint, template: ControlMap? = nil) async throws {
    diagnosticPhase = .controlRequested
    try Task.checkCancellation()
    guard !closed, anchor?.window?.isKeyWindow == true,
      UIApplication.shared.applicationState == .active
    else { throw InputError.unavailable }
    status("connecting")
    let client = try PhoneControlClient(
      endpoint: endpoint, storage: storage,
      inputSessions: true, datagrams: true, renewals: true, outputMode: outputMode)
    control = client
    diagnosticPhase = .authenticating
    guard try await client.authenticate().inputSessionAvailable else {
      throw InputError.unavailable
    }
    diagnosticPhase = .configuration
    let metadata = try await client.inputConfiguration()
    guard metadata.active else {
      throw InputError.unavailable
    }
    guard let anchor else { throw InputError.unavailable }
    let viewport = anchor.bounds.size
    let map: ControlMap
    var delivered: SavedControllerMap?
    var savedRequest: SavedControllerRequest?
    var catalogPage: PhoneCatalogResult?
    if let testOnlyMapProvider {
      map = try testOnlyMapProvider(metadata, viewport)
      guard map.generation == metadata.generation, map.revision == metadata.revision else {
        throw InputError.invalidMap
      }
      // bindInput below performs the same full map validation before any grant.
    } else {
      let catalog = try PhoneCatalogClient(endpoint: endpoint, storage: storage)
      catalogClient = catalog
      #if DEBUG
        savedReadDiagnostic = .catalog
      #endif
      let result = try await catalog.read()
      catalogClient = nil
      try Task.checkCancellation()
      guard case .catalog(let page) = result else { throw SavedControllerError.rejected }
      catalogPage = result
      let request = try SavedControllerRequest(
        catalog: page, configuration: metadata, width: viewport.width, height: viewport.height)
      let maps = try SavedControllerClient(endpoint: endpoint, storage: storage)
      savedMapClient = maps
      #if DEBUG
        savedReadDiagnostic = .controls
      #endif
      let resultMap: SavedControllerMap
      do { resultMap = try await maps.read(request) } catch {
        #if DEBUG
          if let error = error as? SavedControllerError {
            switch error {
            case .rejected: savedReadFailure = .rejected
            case .unavailable(let code):
              savedReadFailure = SavedReadFailure(rawValue: code) ?? .rejected
            }
          } else if error is ControlTLSError {
            savedReadFailure = .transport
          } else {
            savedReadFailure = .other
          }
        #endif
        throw error
      }
      savedMapClient = nil
      try Task.checkCancellation()
      #if DEBUG
        savedReadDiagnostic = .none
      #endif
      delivered = resultMap
      savedRequest = request
      map = resultMap.map
    }
    guard !closed, anchor.bounds.size == viewport, anchor.window?.isKeyWindow == true,
      UIApplication.shared.applicationState == .active
    else { throw InputError.unavailable }
    diagnosticPhase = .input
    let engine = try await client.bindInput(map, feedback: feedback)
    diagnosticPhase = .installing
    try Task.checkCancellation()
    guard !closed, anchor.window?.isKeyWindow == true,
      UIApplication.shared.applicationState == .active
    else {
      engine.cancel(.disconnected)
      throw InputError.unavailable
    }
    guard anchor.bounds.size == viewport else {
      engine.cancel(.rotation)
      throw InputError.unavailable
    }
    try install(engine)
    if let delivered { installedMap(delivered.bridgeMap, delivered.configurationSha256) }
    if let delivered, let savedRequest {
      // Optional cosmetic reads have a separate native connection/task and never fail this input owner.
      do {
        let request = try PhonePresentationRequest(
          saved: savedRequest, map: delivered,
          colorScheme: anchor.traitCollection.userInterfaceStyle == .dark ? "dark" : "light")
        let poller = PhonePresentationPoller(
          endpoint: endpoint, storage: storage, request: request,
          colorScheme: { [weak anchor] in
            anchor?.traitCollection.userInterfaceStyle == .dark ? "dark" : "light"
          },
          active: { [weak self, weak client, weak engine, weak anchor] in
            guard let self, let client, let engine, let anchor else { return false }
            return !self.closed && self.control === client && engine.connected
              && anchor.window?.isKeyWindow == true && anchor.bounds.size == viewport
              && UIApplication.shared.applicationState == .active
          },
          notification: { [weak self, weak client] value in
            guard let self, let client, !self.closed, self.control === client else { return }
            self.presentationResult(value)
          })
        presentationPoller = poller
        poller.start()
      } catch {
        presentationResult([
          "kind": "error", "error": "presentation_unavailable",
          "generation": map.generation, "revision": map.revision,
          "configurationSha256": delivered.configurationSha256,
        ])
      }
    }
    if let catalogPage { catalogResult(catalogPage.bridgeMetadata) }
    diagnosticPhase = .connected
  }
  func refreshPresentation() { presentationPoller?.refreshTheme() }

  private func fail() {
    guard !closed else { return }
    // [DEBUG-enrollment-admission] Preserve the failed native phase before cleanup.
    if let enrollment {
      diagnosticConnectOutcome = enrollment.diagnosticConnectOutcome ?? .idle
      diagnosticPhase =
        switch enrollment.diagnosticPhase {
        case .idle: .enrollmentIdle
        case .connecting: .enrollmentConnecting
        case .negotiating: .enrollmentNegotiating
        case .credential: .enrollmentCredential
        case .storing: .enrollmentStoring
        case .acknowledging: .enrollmentAcknowledging
        case .confirming: .enrollmentConfirming
        case .complete: .enrollmentComplete
        }
    }
    #if DEBUG
      Logger(subsystem: "com.thumble.rewrite", category: "PhoneAdmission").error(
        "phone_admission_failed phase=\(self.diagnosticPhase.rawValue, privacy: .public) savedRead=\(self.savedReadDiagnostic.rawValue, privacy: .public) mapStage=\(self.savedMapClient?.diagnosticReadStage.rawValue ?? "none", privacy: .public) mapFailure=\(self.savedReadFailure.rawValue, privacy: .public) connect=\(self.diagnosticConnectOutcome.rawValue, privacy: .public) control=\(self.diagnosticControlFailure.rawValue, privacy: .public) runtime=\(self.diagnosticRuntimeOutcome.rawValue, privacy: .public)"
      )
    #endif
    close()
    status("unavailable")
  }
  func close() {
    guard !closed else { return }
    if let control {
      lastControlFailure = control.diagnosticFailureStage
      lastRuntimeOutcome = control.diagnosticRuntimeOutcome
    }
    closed = true
    scanner?.close()
    scanner?.dismiss(animated: false)
    scanner = nil
    NotificationCenter.default.removeObserver(self)
    authorityResolver?.close()
    authorityResolver = nil
    catalogClient?.close()
    catalogClient = nil
    savedMapClient?.close()
    savedMapClient = nil
    presentationPoller?.close()
    presentationPoller = nil
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
    // The explicit pre-auth camera permission sheet may briefly make the app inactive.
    // No input/control channel exists in this phase; actual background still closes below.
    if scanner != nil, control == nil, enrollment == nil { return }
    enteredBackground()
  }
  @objc private func enteredBackground() {
    guard !closed else { return }
    close()
    status("disconnected")
  }
  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    textField.resignFirstResponder()
    return true
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
