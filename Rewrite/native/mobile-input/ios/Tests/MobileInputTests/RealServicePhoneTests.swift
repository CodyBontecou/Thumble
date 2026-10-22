#if os(macOS)
  import Foundation
  import Testing
  @testable import MobileInputCore

  private actor RealServiceCredential: ControlCredentialSource, EnrollmentCredentialSink {
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
  @MainActor private final class RealServiceBlackhole: NativeDatagramIO {
    private var closed = false
    func connect() async throws {}
    func offer(_ packet: Data) -> Bool { !closed }
    func close() { closed = true }
  }
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["THUMBLE_REAL_SERVICE_PHONE_PROBE"] != nil),
    arguments: [false, true])
  @MainActor private func actualRealServiceCatalogReadPreservesNativePhoneHeldInput(
    tlsFallback: Bool
  ) async throws {
    let process = NativeProbeProcess(
      path: try #require(ProcessInfo.processInfo.environment["THUMBLE_REAL_SERVICE_PHONE_PROBE"]),
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
      let storage = RealServiceCredential()
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
          if tlsFallback { return RealServiceBlackhole() }
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
      let engine = try await control.bindInput(
        ControlMap(
          generation: "1", revision: "1",
          controls: [ControlRegion(id: "south", action: "south", x: 0, y: 0, width: 1, height: 1)]))
      _ = try engine.claimTouchSurface()
      try await process.send(122)
      #expect(try await line()["freshNeutral"] as? Bool == true)
      #expect(engine.begin(id: 1, generation: "1", x: 0.5, y: 0.5))
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
      try await process.send(113)
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
      #expect(page.profiles.map(\.name) == ["First", "Second"])
      #expect(result.bridgeMetadata["profileCount"] as? Int == 2)
      try await Task.sleep(for: .milliseconds(1600))
      #expect(engine.connected)
      try await process.send(106)
      let held = try await line()
      #expect(
        held["catalogHeld"] as? Bool == true && held["neutralPulses"] as? Int == 0
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
