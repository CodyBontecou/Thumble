import Foundation
import Network
import Security

// All mutable transport/HID state is confined to this serial queue, independent of AppKit.
final class Receiver {
    let queue = DispatchQueue(label: "tapping.receiver.input", qos: .userInteractive)
    private let diagnostics = LatencyDiagnostics(path: ProcessInfo.processInfo.environment["TAPPING_LATENCY_FILE"])
    private let audit = InputAudit(path: ProcessInfo.processInfo.environment["TAPPING_INPUT_AUDIT_FILE"])
    private let profiles = ProfileBridge()
    private var access: AccessSession!
    private var accessInfo: [String: Any] = [:]
    private var playRequested = false
    private var accessDeadline = 0.0
    private var accessStarting = false
    private var pro: Bool { accessInfo["pro"] as? Bool == true }
    private var outputAllowed: Bool { playRequested && ProcessInfo.processInfo.systemUptime < accessDeadline }
    private func publishAccess() {
        guard let peer, accessInfo["v"] as? Int == 1 else { return }
        var value = accessInfo; value["type"] = "access"; value["enabled"] = playRequested
        send(value, to: peer)
    }
    private func pauseAccess() {
        playRequested = false; accessDeadline = 0; accessStarting = false
        chatTask?.cancel(); release(); access.pause(); publishAccess()
    }
    private var profileRevision = 0
    private var savedProfileRevision = 0
    private var activeProfile: [String: Any]?
    private var profileRequestBusy = false
    private var profileCapable = false
    private var layoutPending = false
    private var layoutDeadline = 0.0
    private var datagram: DatagramInput?
    private var listener: NWListener?
    private var listenerParameters: NWParameters?
    private var usingSavedPort = false
    private var timer: DispatchSourceTimer?
    private var gamepad: UnsafeMutableRawPointer?
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private var peer: NWConnection?
    private var leases: [String: TimeInterval] = [:]
    private var lastSequence = -1
    private var lastInput = 0.0
    private var activity: NSObjectProtocol?
    private var paused = false
    private var lastPause = 0.0
    private var rememberedPhone = RememberedPhone()
    private var token = ""
    private var expiry = 0.0
    private var fingerprint = ""
    private var state = PadState.neutral
    var onStatus: ((String) -> Void)?
    var onInvitation: ((String) -> Void)?
    var onPairingUnavailable: (() -> Void)?
    var onConsolePortSyncStatus: ((String) -> Void)?
    private var chatTask: Task<Void, Never>?
    private var chatBusy = false
    private var chatResults: [String: [String: Any]] = [:]
    private var port: UInt16 = 0
    private let secrets: ReceiverSecretStore
    private let copyBindingProposal: @MainActor (String) -> Bool
    init(secrets: ReceiverSecretStore = KeychainReceiverSecrets(), copyBindingProposal: @escaping @MainActor (String) -> Bool = { PhoneBindings.copy($0) }) {
        self.secrets = secrets
        self.copyBindingProposal = copyBindingProposal
    }
    private func status(_ text: String) { onStatus?(text) }
    func start() throws {
        guard let device = tapping_gamepad_create() else { throw ReceiverError.virtualGamepadUnavailable }
        gamepad = device
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TAPPING_PROFILE_DIR"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Tapping/profiles").path)
        let config = Bundle.main.url(forResource: "Monetization", withExtension: "json").flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        access = AccessSession(directory: directory, publicKey: config?["entitlementPublicKey"] as? String ?? "")
        access.onChange = { [weak self] info, deadline in
            self?.queue.async { [weak self] in
                guard let self else { return }
                let wasPro = self.pro
                self.accessInfo = info; self.accessStarting = false
                if !self.pro && (info["remaining"] as? Double ?? 0) <= 0 {
                    self.playRequested = false; self.chatTask?.cancel()
                }
                self.publishAccess()
                self.accessDeadline = self.playRequested ? deadline : 0
                if !self.outputAllowed { self.release() }
                if wasPro != self.pro {
                    self.playRequested = false; self.accessDeadline = 0; self.release()
                    self.chatTask?.cancel(); self.leases.removeAll(); self.paused = true
                    if let peer = self.peer, !self.layoutPending { self.acknowledge(peer, type: "paused", sequence: self.lastSequence) }
                }
                self.publishAccess(); self.publishProfileStatus()
            }
        }
        access.begin()
        let identity = try ReceiverIdentity.create(secrets: secrets); fingerprint = identity.fingerprint
        try rememberedPhone.restore(from: secrets)
        let tls = NWProtocolTLS.Options()
        guard let local = sec_identity_create(identity.identity) else { throw ReceiverError.message("TLS identity unavailable.") }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, local)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        let websocket = NWProtocolWebSocket.Options(); websocket.autoReplyPing = true; websocket.maximumMessageSize = 65536
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        // An unreadable saved port is not worth refusing to start over; pick a fresh one.
        let savedPort = (try? secrets.load("listener-port")).flatMap { $0 }.flatMap { UInt16(String(decoding: $0, as: UTF8.self)) }.flatMap(NWEndpoint.Port.init(rawValue:))
        listenerParameters = parameters
        usingSavedPort = savedPort != nil
        let listener = try makeListener(on: savedPort ?? .any)
        profiles.onActivation = { [weak self] revision, profile in
            self?.queue.async { [weak self] in self?.activateLayout(revision: revision, profile: profile) }
        }
        profiles.onStatusTick = { [weak self] in self?.queue.async { [weak self] in self?.publishProfileStatus() } }
        profiles.onError = { [weak self] error in self?.onStatus?(error) }
        profiles.onConsolePortSyncStatus = { [weak self] text in self?.onConsolePortSyncStatus?(text) }
        profiles.start()
        listener.start(queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if self.playRequested && self.accessDeadline > 0 && now >= self.accessDeadline {
                self.accessDeadline = 0; self.playRequested = false
                self.chatTask?.cancel(); self.release(); self.access.pause(); self.publishAccess()
            }
            if self.layoutPending {
                if now > self.layoutDeadline { self.disconnect("Phone did not acknowledge layout · reconnect to retry") }
                return
            }
            if self.peer != nil && now - self.lastInput > 2 { self.disconnect("Input timed out · controls released") }
            else if let peer = self.peer, InputTiming.shouldPause(now: now, lastInput: self.lastInput) {
                if !self.paused { self.diagnostics?.note("pauses"); self.release(); self.accessDeadline = 0; self.access.pause(); self.paused = true; self.leases.removeAll(); self.status("Wi-Fi paused · controls released") }
                if now - self.lastPause > 0.08 { self.acknowledge(peer, type: "paused", sequence: self.lastSequence); self.lastPause = now }
            }
            if self.peer == nil && Date().timeIntervalSince1970 > self.expiry { self.newInvitation() }
        }
        self.timer = timer; timer.resume()
    }
    private func makeListener(on port: NWEndpoint.Port) throws -> NWListener {
        guard let listenerParameters else { throw ReceiverError.message("Receiver network settings unavailable.") }
        let listener = try NWListener(using: listenerParameters, on: port)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] phase in self?.handleListenerState(phase, port: listener?.port?.rawValue) }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        return listener
    }
    func stop() {
        access.stop()
        queue.sync { if let activity = self.activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }; self.release(); self.datagram?.stop(); self.datagram = nil; self.timer?.cancel(); self.listener?.cancel(); self.clients.values.forEach { $0.cancel() }; self.clients.removeAll(); if let gamepad = self.gamepad { tapping_gamepad_destroy(gamepad); self.gamepad = nil } }
        profiles.stop()
    }
    // Called on the receiver queue by the listener's state callback.
    func handleListenerState(_ phase: NWListener.State, port: UInt16?) {
        if case .ready = phase, let port {
            do { try secrets.save(Data(String(port).utf8), account: "listener-port") }
            catch { listener?.cancel(); status("Could not save receiver port · restart to retry"); return }
            self.port = port; newInvitation(); status("Ready · scan to connect")
        }
        if case .failed(let error) = phase {
            // Another app may hold the saved port. Remembered phones must pair again
            // on the new port, but the receiver itself stays usable.
            if usingSavedPort, let failed = listener {
                usingSavedPort = false
                failed.stateUpdateHandler = nil; failed.cancel()
                try? secrets.remove("listener-port")
                if let replacement = try? makeListener(on: .any) { replacement.start(queue: queue); return }
            }
            self.port = 0; token = ""; release(); profiles.updatePairingCode("")
            onPairingUnavailable?()
            status("Network error: \(error.localizedDescription)")
        }
    }
    func suspend() { queue.async { self.disconnect("Computer sleeping · controls released") } }
    func resetPairing() { queue.async {
        do { try self.rememberedPhone.reset() }
        catch { self.disconnect("Could not forget phone · unlock Keychain and retry"); return }
        self.disconnect("Ready · scan to connect"); self.newInvitation()
    } }
    private func newInvitation() {
        guard port > 0 else { return }
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { status("Secure random generator unavailable"); return }
        token = random.map { String(format: "%02x", $0) }.joined(); expiry = Date().timeIntervalSince1970 + 120
        let host = Host.current().localizedName.map { _ in ProcessInfo.processInfo.hostName } ?? ""
        // The DNS name works on both platforms via .local mDNS; an IPv4 fallback is included by the UI helper.
        let address = localIPv4() ?? host
        let payload: [String: Any] = ["v": 1, "url": "wss://\(address):\(port)/controller", "pin": fingerprint, "token": token, "expires": Int(expiry)]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let invitation = "thumble://pair?data=\(encoded)"
        profiles.updatePairingCode(invitation, expires: expiry)
        onInvitation?(invitation)
    }
    private func accept(_ connection: NWConnection) {
        guard clients.count < 4 else { connection.cancel(); return }
        let key = ObjectIdentifier(connection); clients[key] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] phase in
            guard let self, let connection else { return }
            switch phase {
            case .ready: self.receive(connection)
            case .failed, .cancelled:
                self.clients.removeValue(forKey: key)
                if self.peer === connection { self.disconnect("Disconnected · controls released") }
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { [weak self, weak connection] in
            guard let self, let connection, self.peer !== connection else { return }; connection.cancel()
        }
    }
    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, context, _, error in
            guard let self, let connection else { return }
            let receivedMs = ProcessInfo.processInfo.systemUptime * 1000
            guard error == nil, let data, data.count <= 65536,
                  let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
                  metadata.opcode == .text,
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { connection.cancel(); return }
            guard data.count <= 4096 || (self.peer === connection && ["profile-adopt", "profile-save", "bindings-copy"].contains(message["type"] as? String ?? "")) else { connection.cancel(); return }
            self.handle(message, connection: connection, receivedMs: receivedMs)
            if self.clients[ObjectIdentifier(connection)] != nil { self.receive(connection) }
        }
    }
    private func handle(_ message: [String: Any], connection: NWConnection, receivedMs: Double, udp: NWConnection? = nil) {
        if peer !== connection {
            guard udp == nil, message["type"] as? String == "hello", message["v"] as? Int == 3,
                  let phoneID = message["phoneId"] as? String, UUID(uuidString: phoneID) != nil else { connection.cancel(); return }
            let resuming = (message["reconnectToken"] as? String).map { rememberedPhone.accepts(phoneID: phoneID, credential: $0) } ?? false
            let pairing = peer == nil && !token.isEmpty && Date().timeIntervalSince1970 <= expiry && message["token"] as? String == token
            guard resuming || pairing else {
                // Tell a phone holding a stale reconnect credential to stop retrying and rescan.
                if message["reconnectToken"] != nil { forget(connection) } else { connection.cancel() }
                return
            }
            // Only the authenticated remembered phone may replace its lingering old socket.
            if resuming, peer != nil { disconnect("Reconnecting phone · controls released") }
            var reconnectToken: String?
            if pairing {
                guard let credential = rememberedPhone.pair(phoneID) else { connection.cancel(); return }
                reconnectToken = credential
            }
            token = "" // Consumed or superseded QR credentials never authorize reconnect.
            profiles.updatePairingCode("")
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Receive real-time phone controller input")
            chatResults.removeAll(); chatBusy = false; profileRequestBusy = false
            accessInfo = [:]; profileRevision = 0
            peer = connection; paused = false; lastSequence = -1; lastInput = ProcessInfo.processInfo.systemUptime; leases.removeAll(); release()
            profileCapable = true
            playRequested = false; accessDeadline = 0; accessStarting = false
            let mirrored = (message["demoUsed"] as? Double).flatMap { $0.isFinite && (0...1800).contains($0) ? $0 : nil } ?? 0
            access.pair(phoneID: phoneID, mirroredUsed: mirrored)
            acknowledge(connection, type: "ready", sequence: -1, reconnectToken: reconnectToken)
            if activeProfile != nil { pushLayout() }
            if message["datagram"] as? Int == 1 && ProcessInfo.processInfo.environment["TAPPING_INPUT_TRANSPORT"] == "udp" { offerDatagram(connection) }
            publishAccess()
            status("Connected · start demo or restore Pro")
            onInvitation?("")
            return
        }
        if message["type"] as? String == "access-pause" { pauseAccess(); return }
        if message["type"] as? String == "access-resume" {
            guard !layoutPending, pro || (accessInfo["remaining"] as? Double ?? 0) > 0 else { publishAccess(); return }
            playRequested = true; publishAccess(); return
        }
        if message["type"] as? String == "access-grant", let grant = message["grant"] as? [String: Any] {
            access.submitGrant(grant); return
        }
        if message["type"] as? String == "probe", let udp { datagram?.send(["type": "udp-ready"], to: udp); return }
        if udp != nil && message["type"] as? String != "input" { return }
        if message["type"] as? String == "latency", let diagnostics { diagnostics.append(message); return }
        if message["type"] as? String == "bye" { disconnect("Disconnected · controls released"); return }
        if message["type"] as? String == "layout-ready" {
            guard profileCapable, let revision = message["revision"] as? Int, revision <= profileRevision else { disconnect("Invalid layout acknowledgement"); return }
            // A previous render can acknowledge while a newer activation is in flight.
            guard revision == profileRevision, layoutPending else { return }
            layoutPending = false; paused = true; leases.removeAll(); lastInput = ProcessInfo.processInfo.systemUptime
            acknowledge(connection, type: "paused", sequence: lastSequence)
            publishProfileStatus()
            return
        }
        if let type = message["type"] as? String, ["bindings-read", "bindings-copy"].contains(type) {
            handleBindings(message, connection: connection); return
        }
        if let type = message["type"] as? String, ["profiles-list", "profile-select", "profile-adopt", "profile-save"].contains(type) {
            handleProfiles(message, connection: connection)
            return
        }
        if message["type"] as? String == "chat" {
            handleChat(message, connection: connection)
            return
        }
        // Ignore in-flight packets from the previous layout without refreshing freshness.
        if layoutPending { return }
        if profileCapable && message["revision"] as? Int != profileRevision { return }
        let now = ProcessInfo.processInfo.systemUptime
        if udp != nil, let sequence = message["seq"] as? Int, sequence <= lastSequence { return }
        guard message["type"] as? String == "input", let sequence = message["seq"] as? Int, sequence > lastSequence, sequence <= 9_007_199_254_740_991,
              let object = message["state"] as? [String: Any], let next = PadState.parse(object)
        else { disconnect("Invalid or stale input · controls released"); return }
        // Expired packets are discarded without refreshing the watchdog. The peer can
        // recover only through a fresh server-clock lease and neutral input.
        guard let lease = message["lease"] as? String, let deadline = leases[lease], InputTiming.leaseIsFresh(now: now, deadline: deadline) else { diagnostics?.note(udp == nil ? "wssExpiredLease" : "udpExpiredLease"); return }
        guard !paused || next == .neutral else { return }
        let wasPaused = paused; paused = false
        diagnostics?.note(udp == nil ? "wssAccepted" : "udpAccepted")
        lastSequence = sequence; lastInput = now
        if wasPaused { status("Connected · Xbox gamepad ready") }
        if playRequested && !accessStarting && accessDeadline == 0 {
            accessStarting = true; access.start()
        }
        if !apply(chatBusy || !outputAllowed ? .neutral : next) { disconnect("Virtual gamepad report failed"); return }
        acknowledge(connection, type: "ack", sequence: sequence, timing: diagnostics == nil ? nil : ["receivedMs": receivedMs, "hidMs": ProcessInfo.processInfo.systemUptime * 1000], udp: udp)
    }
    private func handleProfiles(_ message: [String: Any], connection: NWConnection) {
        guard let request = message["id"] as? String, !request.isEmpty, request.utf8.count <= 80 else { return }
        guard !profileRequestBusy else {
            send(["type": "profiles-result", "id": request, "error": "Another profile request is in progress."], to: connection)
            return
        }
        var selection: (String, Int, Int)?
        let adopting = message["type"] as? String == "profile-adopt"
        if adopting || message["type"] as? String == "profile-save" {
            let source = adopting ? message["source"] as? [String: Any] : nil
            guard !adopting || source != nil, adopting || ProfileCatalog.revision(message["expectedProfileRevision"]) != nil, let profile = message["profile"] as? [String: Any],
                  let activation = ProfileCatalog.revision(message["expectedActivationRevision"]),
                  !layoutPending, !chatBusy,
                  let lease = message["lease"] as? String, let deadline = leases[lease],
                  InputTiming.leaseIsFresh(now: ProcessInfo.processInfo.systemUptime, deadline: deadline) else {
                send(["type": "profiles-result", "id": request, "error": "Connection changed. Refresh and try again."], to: connection); return
            }
            profileRequestBusy = true
            pauseAccess()
            profiles.saveAndActivate(profile: profile, source: source, expectedActivationRevision: activation, expectedProfileRevision: ProfileCatalog.revision(message["expectedProfileRevision"]) ?? 0) { [weak self, weak connection] result in
                guard let self, let connection else { return }
                self.queue.async {
                    guard self.peer === connection else { return }
                    self.profileRequestBusy = false
                    switch result {
                    case .success(let catalog): self.send(["type": "profiles-result", "id": request, "catalog": catalog], to: connection)
                    case .failure(let error): self.send(["type": "profiles-result", "id": request, "error": error.localizedDescription], to: connection)
                    }
                }
            }
            return
        }
        if message["type"] as? String == "profile-select" {
            guard let id = message["profileId"] as? String, id.utf8.count <= 64,
                  let revision = ProfileCatalog.revision(message["profileRevision"]), revision > 0,
                  let activation = ProfileCatalog.revision(message["expectedActivationRevision"]),
                  let lease = message["lease"] as? String, let deadline = leases[lease],
                  InputTiming.leaseIsFresh(now: ProcessInfo.processInfo.systemUptime, deadline: deadline) else {
                send(["type": "profiles-result", "id": request, "error": "Connection changed. Refresh and try again."], to: connection)
                return
            }
            selection = (id, revision, activation)
        }
        profileRequestBusy = true
        profiles.catalog(selection: selection) { [weak self, weak connection] result in
            guard let self, let connection else { return }
            self.queue.async {
                guard self.peer === connection else { return }
                self.profileRequestBusy = false
                switch result {
                case .success(let catalog): self.send(["type": "profiles-result", "id": request, "catalog": catalog], to: connection)
                case .failure(let error): self.send(["type": "profiles-result", "id": request, "error": error.localizedDescription], to: connection)
                }
            }
        }
    }
    private func handleBindings(_ message: [String: Any], connection: NWConnection) {
        guard let id = message["id"] as? String, !id.isEmpty, id.utf8.count <= 80 else { return }
        func finish(_ result: Result<[String: Any], Error>) {
            queue.async { [weak self, weak connection] in
                guard let self, let connection, self.peer === connection else { return }
                self.profileRequestBusy = false
                switch result {
                case .success(let data): self.send(["type": "bindings-result", "id": id, "data": data], to: connection)
                case .failure(let error): self.send(["type": "bindings-result", "id": id, "error": error.localizedDescription], to: connection)
                }
            }
        }
        guard !profileRequestBusy else {
            send(["type": "bindings-result", "id": id, "error": "Another controller request is in progress."], to: connection); return
        }
        if message["type"] as? String == "bindings-read" {
            guard let offset = ProfileCatalog.revision(message["offset"]), offset <= 2048,
                  message["snapshotId"] == nil || message["snapshotId"] is String else { finish(.failure(PhoneBindings.Failure.invalid)); return }
            profileRequestBusy = true
            profiles.bindingPage(offset: offset, snapshot: message["snapshotId"] as? String, completion: finish)
        } else {
            guard let plan = message["plan"] as? [String: Any], !layoutPending, !chatBusy,
                  let lease = message["lease"] as? String, let deadline = leases[lease],
                  InputTiming.leaseIsFresh(now: ProcessInfo.processInfo.systemUptime, deadline: deadline) else { finish(.failure(PhoneBindings.Failure.changed)); return }
            profileRequestBusy = true
            pauseAccess()
            profiles.bindingPlan(plan) { result in
                switch result {
                case .failure(let error): finish(.failure(error))
                case .success(let text):
                    Task { @MainActor in
                        if self.copyBindingProposal(text) { finish(.success(["planId": plan["id"]!])) }
                        else { finish(.failure(PhoneBindings.Failure.invalid)) }
                    }
                }
            }
        }
    }
    private func handleChat(_ message: [String: Any], connection: NWConnection) {
        guard let id = message["id"] as? String, !id.isEmpty, id.utf8.count <= 80 else { return }
        if let previous = chatResults[id] { send(previous, to: connection); return }
        func reject(_ reason: String) {
            let result: [String: Any] = ["type": "chat-result", "id": id, "error": reason]
            send(result, to: connection)
        }
        guard outputAllowed else { reject("Start or resume your controller demo, or unlock Pro."); return }
        guard !chatBusy else { reject("Another chat message is being delivered. Please wait."); return }
        guard !layoutPending, message["revision"] as? Int == profileRevision,
              let lease = message["lease"] as? String, let deadline = leases[lease], ProcessInfo.processInfo.systemUptime <= deadline,
              let text = message["text"] as? String, let channel = message["channel"] as? String else {
            reject("Connection changed. Review your message and try again."); return
        }
        // Bound memory and disallow unlimited replays for the lifetime of a pairing.
        guard chatResults.count < 1000 else { reject("Reconnect your phone to continue chatting."); return }
        chatBusy = true
        chatResults[id] = ["type": "chat-result", "id": id, "error": "This message is already being delivered. Check WoW before trying again."]
        release()
        chatTask = Task { @MainActor [weak self, weak connection] in
            let error = await ChatDelivery.send(text: text, channel: channel)
            guard let self, let connection else { return }
            self.finishChat(id: id, error: error, connection: connection)
        }
    }
    private func finishChat(id: String, error: String?, connection: NWConnection) {
        queue.async { [weak self] in
            guard let self, self.peer === connection else { return }
            self.chatBusy = false
            var result: [String: Any] = ["type": "chat-result", "id": id]
            if let error { result["error"] = error }
            self.chatResults[id] = result
            self.send(result, to: connection)
        }
    }
    private func offerDatagram(_ control: NWConnection) {
        guard let input = try? DatagramInput(queue: queue) else { return }
        datagram = input
        input.onReady = { [weak self, weak input, weak control] port in
            guard let self, let input, let control, self.peer === control else { return }
            self.send(["type": "udp-offer", "port": Int(port), "key": input.key.base64EncodedString()], to: control)
        }
        input.onMessage = { [weak self, weak control] message, receivedMs, endpoint in
            guard let self, let control, self.peer === control else { return }
            self.handle(message, connection: control, receivedMs: receivedMs, udp: endpoint)
        }
        input.start()
    }
    private func activateLayout(revision: Int, profile: [String: Any]) {
        guard revision > profileRevision else { return }
        activeProfile = profile; savedProfileRevision = revision
        profileRevision = revision
        if peer != nil {
            if profileCapable { pushLayout() }
            else { disconnect("Update the phone app to receive custom layouts") }
        }
        publishProfileStatus()
    }
    private func pushLayout() {
        guard let peer, let activeProfile else { return }
        // Reconnect restores the saved layout for demo and Pro alike.
        profileRevision = savedProfileRevision
        guard apply(.neutral) else { disconnect("Could not release controls before changing layout"); return }
        leases.removeAll(); layoutPending = true; paused = true
        layoutDeadline = ProcessInfo.processInfo.systemUptime + 5
        send(["type": "layout", "revision": profileRevision, "profile": activeProfile], to: peer)
        publishProfileStatus()
    }
    private func publishProfileStatus() {
        profiles.writeStatus(["updatedAt": Date().timeIntervalSince1970 * 1000, "connected": peer != nil,
                              "ready": peer != nil && !layoutPending && (profileCapable || profileRevision == 0), "revision": profileRevision, "pro": pro, "receiverId": accessInfo["receiverId"] ?? ""])
    }
    private func acknowledge(_ connection: NWConnection, type: String, sequence: Int, timing: [String: Double]? = nil, udp: NWConnection? = nil, reconnectToken: String? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        leases = leases.filter { $0.value > now }
        // Server-clock leases prevent delayed TCP packets from reviving old held buttons.
        let lease = UUID().uuidString; leases[lease] = InputTiming.leaseDeadline(issuedAt: now)
        if leases.count > 256 { disconnect("Input rate exceeded"); return }
        var response: [String: Any] = ["type": type, "seq": sequence, "lease": lease]
        if type == "ready" { response["chat"] = 1; response["profiles"] = 1; response["access"] = 1; response["cloudAdoption"] = 1; response["phoneProfileSave"] = 1; response["phoneBindings"] = 1 }
        if let reconnectToken { response["reconnectToken"] = reconnectToken }
        if type == "ready", diagnostics != nil { response["diagnostics"] = true }
        if var timing { timing["ackMs"] = ProcessInfo.processInfo.systemUptime * 1000; response["timing"] = timing }
        if let udp { datagram?.send(response, to: udp) } else { send(response, to: connection) }
    }
    private func forget(_ connection: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["type": "forgotten"]) else { connection.cancel(); return }
        let context = NWConnection.ContentContext(identifier: "input", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }
    private func send(_ object: [String: Any], to connection: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let context = NWConnection.ContentContext(identifier: "input", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self, weak connection] error in
            if error != nil, let self, let connection, self.peer === connection { self.disconnect("Connection lost · controls released") }
        })
    }
    @discardableResult private func apply(_ next: PadState) -> Bool {
        guard let gamepad else { return false }
        let result = next.report.withUnsafeBufferPointer { tapping_gamepad_send(gamepad, $0.baseAddress!) }
        audit?.record(next.report, result: result)
        state = next
        return result == 0
    }
    private func release() { apply(.neutral) }
    private func disconnect(_ reason: String) {
        pauseAccess()
        chatTask?.cancel(); chatTask = nil; chatBusy = false
        datagram?.stop(); datagram = nil; layoutPending = false; release(); if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }; let old = peer; peer = nil; leases.removeAll(); old?.cancel()
        if old != nil { newInvitation() }; publishProfileStatus(); status(reason)
    }
}

import Darwin
func localIPv4() -> String? {
    var addresses: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addresses) == 0 else { return nil }
    defer { freeifaddrs(addresses) }
    var cursor = addresses
    while let item = cursor?.pointee {
        defer { cursor = item.ifa_next }
        guard let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_INET), (item.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
              (item.ifa_flags & UInt32(IFF_UP)) != 0, String(cString: item.ifa_name).hasPrefix("en") else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
            let value = String(cString: host)
            let octets = value.split(separator: ".").compactMap { Int($0) }
            guard octets.count == 4 else { continue }
            if octets[0] == 10 || (octets[0] == 192 && octets[1] == 168) || (octets[0] == 172 && (16...31).contains(octets[1])) { return value }
        }
    }
    return nil
}
