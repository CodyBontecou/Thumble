#if os(macOS)
  import Foundation
  import Testing
  @testable import MobileInputCore

  private actor SavedAnalogServiceCredential: ControlCredentialSource, EnrollmentCredentialSink {
    private var credential: PhoneCredential?
    func save(_ credential: PhoneCredential) { self.credential = credential }
    func load(hostPin: String, now: UInt64) -> PhoneCredential? {
      guard let credential, credential.metadata.hostPin == hostPin,
        credential.metadata.expiresAt > now
      else {
        return nil
      }
      return credential
    }
  }
  @MainActor private final class SavedAnalogServiceBlackhole: NativeDatagramIO {
    private var closed = false
    func connect() async throws {}
    func offer(_ packet: Data) -> Bool { !closed }
    func close() { closed = true }
  }
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["THUMBLE_REAL_SERVICE_PHONE_PROBE"] != nil),
    arguments: ["udp", "tls-fallback", "unsupported"])
  @MainActor
  private func actualSavedAnalogServiceMapDeliversCombinedNativeInputAndRejectsUnsupportedProfile(
    mode: String
  ) async throws {
    let tlsFallback = mode == "tls-fallback"
    let unsupported = mode == "unsupported"
    let process = NativeProbeProcess(
      path: try #require(ProcessInfo.processInfo.environment["THUMBLE_REAL_SERVICE_PHONE_PROBE"]),
      arguments: [
        unsupported ? "--saved-controller-analog-unsupported" : "--saved-controller-analog"
      ],
      timeout: .seconds(30))
    do {
      try await process.start()
      func line() async throws -> [String: Any] {
        let data = try await process.line()
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
      }
      let offer = try await line()
      #expect(offer["backend"] as? String == "real-bun-service")
      #expect(offer["profileCount"] as? Int == 2)
      let invitation = try EnrollmentInvitation(
        host: "127.0.0.1", port: UInt16(try #require(offer["port"] as? Int)),
        certificatePin: try #require(offer["pin"] as? String),
        authorityInstanceID: try #require(offer["authorityInstanceId"] as? String),
        windowID: try #require(offer["windowId"] as? String),
        secret: try #require(offer["secret"] as? String),
        expiresAt: UInt64(try #require(offer["expiresAt"] as? Int)))
      let storage = SavedAnalogServiceCredential()
      let now = { UInt64(Date().timeIntervalSince1970 * 1000) }
      let enrollment = PhoneEnrollmentClient(
        invitation: invitation,
        io: try ControlTLSClient(
          host: invitation.host, port: invitation.port, certificatePin: invitation.certificatePin),
        sink: storage, now: now)
      _ = try await enrollment.enroll(phoneID: "phone-a", label: "Synthetic real service witness")
      enrollment.close()
      let endpoint = try TrustedHostEndpoint(
        host: invitation.host, port: invitation.port, certificatePin: invitation.certificatePin,
        authorityInstanceID: invitation.authorityInstanceID)
      let control = PhoneControlClient(
        endpoint: endpoint,
        io: try ControlTLSClient(
          host: endpoint.host, port: endpoint.port, certificatePin: endpoint.certificatePin),
        storage: storage, now: now, controlVersion: 6,
        datagramFactory: { host, port in
          if tlsFallback { return SavedAnalogServiceBlackhole() }
          return try NativeDatagramClient(host: host, port: port)
        })
      defer { control.close() }
      #expect(try await control.authenticate().inputSessionAvailable)
      try await process.send(97)
      let active = try await line()
      #expect(active["generation"] as? String == "1")
      let metadata = try await control.inputConfiguration()
      #expect(
        metadata.active && !metadata.inputEnabled && metadata.generation == "1"
          && metadata.revision == "1")
      let catalogBefore = PhoneCatalogClient(
        endpoint: endpoint,
        io: try ControlTLSClient(
          host: endpoint.host, port: endpoint.port, certificatePin: endpoint.certificatePin),
        storage: storage, now: now)
      guard case .catalog(let selected) = try await catalogBefore.read() else {
        throw SavedControllerError.rejected
      }
      let maps = SavedControllerClient(
        endpoint: endpoint,
        io: try ControlTLSClient(
          host: endpoint.host, port: endpoint.port, certificatePin: endpoint.certificatePin),
        storage: storage, now: now)
      let request = try SavedControllerRequest(
        catalog: selected, configuration: metadata, width: 874, height: 393)
      if unsupported {
        await #expect(throws: SavedControllerError.unavailable("saved_map_unsupported_profile")) {
          try await maps.read(request)
        }
        control.close()
        try await process.send(102)
        #expect(try await line()["completed"] as? Bool == true)
        #expect(await process.wait() == 0)
        await process.stop()
        return
      }
      let delivered = try await maps.read(request)
      #expect(
        delivered.map.controls.map(\.action) == [
          "leftStandardStick", "rightStandardStick", "leftVerticalTrigger",
          "rightHorizontalTrigger", "south",
        ])
      #expect(abs(delivered.map.controls[0].width * 874 - 117.9) < 0.00001)
      #expect(abs(delivered.map.controls[2].height * 393 - 43.23) < 0.00001)
      let engine = try await control.bindInput(delivered.map)
      _ = try engine.claimTouchSurface()
      try await process.send(122)
      #expect(try await line()["freshNeutral"] as? Bool == true)
      let positions = [(0.736, 0.5), (0.5, 0.264), (0.5, 0.582), (0.418, 0.5), (0.5, 0.5)]
      for (index, control) in delivered.map.controls.enumerated() {
        let point = positions[index]
        #expect(
          engine.begin(
            id: UInt64(index + 1), generation: "1", x: control.x + point.0 * control.width,
            y: control.y + point.1 * control.height))
      }
      #expect(GamepadReport.hex(engine.state) == "0014001066663333000000003333000000000000")
      let sampling = Task { @MainActor in
        while !Task.isCancelled {
          engine.tick()
          do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
        }
      }
      defer {
        sampling.cancel()
        if engine.connected { engine.cancel(.disposed) }
      }
      try await process.send(107)
      #expect(try await line()["watching"] as? Bool == true)
      // A dedicated role7 connection shares only the verified host/credential authority.
      let catalog = PhoneCatalogClient(
        endpoint: endpoint,
        io: try ControlTLSClient(
          host: endpoint.host, port: endpoint.port, certificatePin: endpoint.certificatePin),
        storage: storage, now: now)
      defer { catalog.close() }
      let result = try await catalog.read()
      guard case .catalog(let page) = result else {
        Issue.record("real saved catalog unavailable")
        throw PhoneCatalogError.rejected
      }
      #expect(
        page.revision == "1" && page.activeProfileID == "bbbbbbbb-0000-0000-0000-000000000002"
          && page.defaultProfileID == nil && page.nextOffset == nil)
      #expect(
        page.profiles.map(\.id) == [
          "aaaaaaaa-0000-0000-0000-000000000001", "bbbbbbbb-0000-0000-0000-000000000002",
        ])
      #expect(result.bridgeMetadata["profileCount"] as? Int == 2)
      try await Task.sleep(for: .milliseconds(1600))
      #expect(engine.connected)
      try await process.send(111)
      let held = try await line()
      #expect(
        held["analogHeld"] as? Bool == true && held["neutralPulses"] as? Int == 0
          && held["inputTtlMs"] as? Int == 350 && held["inputEnabled"] as? Bool == false)
      #expect((held["durationMs"] as? Int ?? 0) >= 1500 && (held["samples"] as? Int ?? 0) > 0)
      engine.cancel(.background)
      sampling.cancel()
      await sampling.value
      try await process.send(110)
      #expect(try await line()["reason"] as? String == "native_input_released")
      #expect(!engine.connected)
      try await process.send(102)
      #expect(try await line()["completed"] as? Bool == true)
      #expect(await process.wait() == 0)
      await process.stop()
    } catch {
      await process.stop()
      throw error
    }
  }
#endif
