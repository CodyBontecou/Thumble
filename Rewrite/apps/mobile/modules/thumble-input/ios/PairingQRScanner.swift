@preconcurrency import AVFoundation
import MobileInputCore
import UIKit

/// Explicitly presented by the native pairing prompt. No invitation crosses React.
@MainActor final class PairingQRScanner: UIViewController {
  private var admission = PairingQRSession()
  private var finished = false
  private var authorized = false
  private let completion: (EnrollmentInvitation?) -> Void
  private var camera: PairingQRCamera?
  private var preview: AVCaptureVideoPreviewLayer?
  private let instruction = UILabel()
  init(completion: @escaping (EnrollmentInvitation?) -> Void) {
    self.completion = completion
    super.init(nibName: nil, bundle: nil)
    // Keep the native connection anchor attached; its existing window-detach guard
    // must still retire real navigation/removal. This modal owns all foreground touches.
    modalPresentationStyle = .overFullScreen
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    instruction.text = "Preparing QR scanner."
    instruction.textColor = .white
    instruction.backgroundColor = UIColor.black.withAlphaComponent(0.7)
    instruction.numberOfLines = 0
    instruction.textAlignment = .center
    instruction.font = .preferredFont(forTextStyle: .body)
    instruction.accessibilityIdentifier = "pairing-qr-instruction"
    let manual = UIButton(type: .system)
    manual.setTitle("Enter invitation instead", for: .normal)
    manual.accessibilityIdentifier = "pairing-qr-manual"
    manual.addTarget(self, action: #selector(manualEntry), for: .touchUpInside)
    let cancel = UIButton(type: .system)
    cancel.setTitle("Cancel", for: .normal)
    cancel.accessibilityIdentifier = "pairing-qr-cancel"
    cancel.addTarget(self, action: #selector(manualEntry), for: .touchUpInside)
    let actions = UIStackView(arrangedSubviews: [instruction, manual, cancel])
    actions.axis = .vertical
    actions.spacing = 12
    actions.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(actions)
    NSLayoutConstraint.activate([
      actions.leadingAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
      actions.trailingAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
      actions.bottomAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
      manual.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
      cancel.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
    ])
    let camera = PairingQRCamera { [weak self] event in self?.receive(event) }
    self.camera = camera
    let preview = AVCaptureVideoPreviewLayer(session: camera.session)
    preview.videoGravity = .resizeAspectFill
    view.layer.insertSublayer(preview, at: 0)
    self.preview = preview
    NotificationCenter.default.addObserver(
      self, selector: #selector(becameActive), name: UIApplication.didBecomeActiveNotification,
      object: nil)
  }
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !finished, !authorized else { return }
    instruction.text = "Checking camera access."
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: authorize(true)
    case .notDetermined:
      instruction.text = "Allow camera access to scan your Mac’s code."
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        Task { @MainActor in self?.authorize(granted) }
      }
    default: authorize(false)
    }
  }
  private func authorize(_ granted: Bool) {
    guard !finished else { return }
    guard admission.authorize(granted) else {
      instruction.text = "Camera access is unavailable. You can enter the invitation instead."
      return
    }
    authorized = true
    becameActive()
  }
  @objc private func becameActive() {
    guard !finished, authorized else { return }
    guard UIApplication.shared.applicationState == .active else {
      instruction.text = "Return to the app to start the camera."
      return
    }
    instruction.text = "Starting camera."
    camera?.start()
  }
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    preview?.frame = view.bounds
  }
  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    close()
  }
  private func receive(_ event: PairingQRCamera.Event) {
    guard !finished else { return }
    switch event {
    case .ready:
      instruction.text = "Camera ready. Point at the pairing code on your Mac."
      camera?.resume()
    case .unavailable:
      instruction.text = "QR scanning is unavailable. You can enter the invitation instead."
    case .text(let text):
      guard let invitation = admission.receive(text) else {
        instruction.text = "That is not a Thumble pairing code. Scan the code from your Mac."
        camera?.resume()
        return
      }
      finish(invitation)
    }
  }
  @objc private func manualEntry() { finish(nil) }
  private func finish(_ invitation: EnrollmentInvitation?) {
    guard !finished else { return }
    close()
    dismiss(animated: true) { [completion] in completion(invitation) }
  }
  /// Also called by the connection owner before dismissal/background; terminal on the UI actor.
  func close() {
    instruction.text = "Camera stopped."
    finished = true
    admission.close()
    NotificationCenter.default.removeObserver(self)
    camera?.close()
  }
}

/// AVFoundation configuration, metadata callbacks, start and stop are serialized on this queue.
/// The immutable session is attached to its preview before any configuration is enqueued.
private final class PairingQRCamera: NSObject, @unchecked Sendable,
  AVCaptureMetadataOutputObjectsDelegate
{
  enum Event: Sendable {
    case text(String)
    case ready
    case unavailable
  }
  let session = AVCaptureSession()
  private let queue = DispatchQueue(label: "Thumble.PairingQR.Camera")
  private let deliver: @MainActor @Sendable (Event) -> Void
  private var closed = false
  private var started = false
  private var pending = false
  init(deliver: @escaping @MainActor @Sendable (Event) -> Void) { self.deliver = deliver }
  func start() {
    queue.async { [self] in
      guard !closed, !started else { return }
      started = true
      do {
        guard let device = AVCaptureDevice.default(for: .video) else {
          throw CameraError.unavailable
        }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureMetadataOutput()
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
          session.commitConfiguration()
          throw CameraError.unavailable
        }
        session.addInput(input)
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: queue)
        guard output.availableMetadataObjectTypes.contains(.qr) else {
          session.commitConfiguration()
          throw CameraError.unavailable
        }
        output.metadataObjectTypes = [.qr]
        session.commitConfiguration()
        session.startRunning()
        if !session.isRunning { throw CameraError.unavailable }
        publish(.ready)
      } catch { publish(.unavailable) }
    }
  }
  func resume() { queue.async { [self] in if !closed { pending = false } } }
  func close() {
    queue.async { [self] in
      guard !closed else { return }
      closed = true
      if session.isRunning { session.stopRunning() }
      for output in session.outputs.compactMap({ $0 as? AVCaptureMetadataOutput }) {
        output.setMetadataObjectsDelegate(nil, queue: nil)
      }
    }
  }
  private func publish(_ event: Event) {
    guard !closed, !pending else { return }
    pending = true
    Task { @MainActor [deliver] in deliver(event) }
  }
  func metadataOutput(
    _ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
    from connection: AVCaptureConnection
  ) {
    guard !closed, !pending else { return }
    for case let code as AVMetadataMachineReadableCodeObject in metadataObjects.prefix(8) {
      guard code.type == .qr, let text = code.stringValue, text.utf8.count <= 4096 else { continue }
      publish(.text(text))
      break
    }
  }
  private enum CameraError: Error { case unavailable }
}
