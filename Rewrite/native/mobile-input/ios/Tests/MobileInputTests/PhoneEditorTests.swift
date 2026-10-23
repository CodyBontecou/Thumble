import Foundation
import Testing

@testable import MobileInputCore

private let editorClientPin = String(repeating: "a", count: 64)
private let editorClientAuthority = "11111111-1111-1111-1111-111111111111"
private let editorClientConnection = String(repeating: "ab", count: 16)
private func editorClientScope() throws -> EditorHostScope {
  try EditorHostScope(
    certificateSHA256: editorClientPin, authorityInstanceID: editorClientAuthority)
}
private func editorClientFixture() throws -> [String: Any] {
  let file = try #require(
    Bundle.module.url(
      forResource: "phone-editor-control-v1", withExtension: "json", subdirectory: "Fixtures"))
  return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
}
struct PhoneEditorTests {
  @Test func sharedStrictVectorsAndHostileReplyRequests() throws {
    let fixture = try editorClientFixture()
    let scope = try editorClientScope()
    let cases = try #require(fixture["cases"] as? [[String: Any]])
    for vector in cases {
      let requestData = try JSONSerialization.data(withJSONObject: #require(vector["request"]))
      let request = try EditorWire.request(
        requestData, scope: scope, connection: editorClientConnection)
      let produced = try request.fields(connection: editorClientConnection)
      #expect(
        try NSDictionary(dictionary: produced).isEqual(
          to: #require(vector["request"] as? [String: Any])))
      let replyData = try JSONSerialization.data(withJSONObject: #require(vector["reply"]))
      _ = try EditorWire.reply(replyData, request: request, connection: editorClientConnection)
    }
    for vector in try #require(fixture["invalidRequests"] as? [[String: Any]]) {
      let text = try #require(vector["utf8"] as? String)
      #expect(throws: (any Error).self) {
        _ = try EditorWire.request(
          Data(text.utf8), scope: scope, connection: editorClientConnection)
      }
    }
    for vector in try #require(fixture["invalidReplies"] as? [[String: Any]]) {
      let request = try EditorWire.request(
        JSONSerialization.data(withJSONObject: #require(vector["request"])), scope: scope,
        connection: editorClientConnection)
      let text = try #require(vector["utf8"] as? String)
      #expect(throws: (any Error).self) {
        _ = try EditorWire.reply(
          Data(text.utf8), request: request, connection: editorClientConnection)
      }
    }
  }
}
private final class EditorClientMemoryStore: EditorJournalStorage {
  var bytes: Data?
  var fail = false
  func load() -> Data? { bytes }
  func save(_ candidate: Data, replacing expected: Data?) throws {
    guard !fail else { throw EditorJournalError.unavailable }
    guard bytes == expected else { throw EditorJournalError.changedOnDisk }
    bytes = candidate
  }
}
private func editorClientIntent(_ op: String = "edit-A-1", label: String? = "Move 🦊") throws
  -> EditorLabelIntent
{
  try EditorLabelIntent(
    scope: editorClientScope(), operationID: op, expectedRevision: "7",
    profileID: "aaaaaaaa-0000-0000-0000-000000000001",
    controlID: "ce000000-0000-0000-0000-000000000001", label: label)
}
private func editorClientVector(_ name: String) throws -> Data {
  let rows = try #require(editorClientFixture()["cases"] as? [[String: Any]])
  let row = try #require(rows.first { $0["name"] as? String == name })
  return try JSONSerialization.data(withJSONObject: #require(row["reply"]))
}
private actor EditorScriptTransport: EditorRPCTransport {
  struct Step: Sendable {
    let bytes: Data
    var phone: String = "phone-a"
    var epoch: UInt64 = 1
  }
  var steps: [Step]
  var requests: [EditorRequest] = []
  var paused = false
  private var continuation: CheckedContinuation<Void, Never>?
  init(_ steps: [Step], paused: Bool = false) {
    self.steps = steps
    self.paused = paused
  }
  func exchange(_ request: EditorRequest) async throws -> EditorAuthenticatedReply {
    requests.append(request)
    if paused { await withCheckedContinuation { continuation = $0 } }
    guard !steps.isEmpty else { throw PhoneEditorError.unavailable }
    let step = steps.removeFirst()
    return EditorAuthenticatedReply(
      scope: request.scope, phoneID: step.phone, credentialEpoch: step.epoch,
      connectionID: editorClientConnection,
      reply: try EditorWire.reply(step.bytes, request: request, connection: editorClientConnection))
  }
  func cancel() {}
  func release() {
    paused = false
    continuation?.resume()
    continuation = nil
  }
  func count() -> Int { requests.count }
}
extension PhoneEditorTests {
  @Test func dispatchPersistsUncertaintyAndExactStatusRetiresWithoutCacheMutation() async throws {
    let store = EditorClientMemoryStore()
    let journal = try EditorJournal(certificateSHA256: editorClientPin, storage: store)
    let intent = try editorClientIntent()
    try journal.enqueue(intent)
    let transport = EditorScriptTransport([
      .init(bytes: try editorClientVector("label-admitted")),
      .init(bytes: try editorClientVector("status-receipt")),
    ])
    let coordinator = PhoneEditorCoordinator(journal: journal, transport: transport)
    #expect(
      try await coordinator.submit(intent.operationID, endpointScope: editorClientScope())
        == .retained)
    #expect(await coordinator.snapshot().entries.first?.status == .uncertain)
    #expect(
      try await coordinator.submit(intent.operationID, endpointScope: editorClientScope())
        == .retained)
    #expect(await transport.count() == 1)
    #expect(
      try await coordinator.reconcile(intent.operationID, endpointScope: editorClientScope())
        == .committed)
    #expect(await coordinator.snapshot().entries.isEmpty)
    #expect(await coordinator.snapshot().profiles.isEmpty)
  }
  @Test func failedDurableMarkerAndChangedOriginNeverDispatch() async throws {
    let store = EditorClientMemoryStore()
    let journal = try EditorJournal(certificateSHA256: editorClientPin, storage: store)
    let intent = try editorClientIntent()
    try journal.enqueue(intent)
    store.fail = true
    let transport = EditorScriptTransport([])
    let coordinator = PhoneEditorCoordinator(journal: journal, transport: transport)
    await #expect(throws: EditorJournalError.unavailable) {
      _ = try await coordinator.submit(intent.operationID, endpointScope: editorClientScope())
    }
    #expect(await transport.count() == 0)
    let changed = try EditorHostScope(
      certificateSHA256: editorClientPin,
      authorityInstanceID: "22222222-2222-2222-2222-222222222222")
    await #expect(throws: PhoneEditorError.originReconciliationRequired) {
      _ = try await coordinator.reconcile(intent.operationID, endpointScope: changed)
    }
    #expect(await transport.count() == 0)
  }
  @Test func cancellationFencesLateReceiptAndKeepsSlotUntilSettled() async throws {
    let journal = try EditorJournal(
      certificateSHA256: editorClientPin, storage: EditorClientMemoryStore())
    let intent = try editorClientIntent()
    try journal.enqueue(intent)
    let transport = EditorScriptTransport(
      [.init(bytes: try editorClientVector("label-committed"))], paused: true)
    let coordinator = PhoneEditorCoordinator(journal: journal, transport: transport)
    let pending = Task {
      try await coordinator.submit(intent.operationID, endpointScope: editorClientScope())
    }
    for _ in 0..<100 {
      if await transport.count() > 0 { break }
      try await Task.sleep(for: .milliseconds(1))
    }
    try #require(await transport.count() == 1)
    await coordinator.cancel()
    await #expect(throws: PhoneEditorError.busy) {
      _ = try await coordinator.reconcile(intent.operationID, endpointScope: editorClientScope())
    }
    await transport.release()
    await #expect(throws: PhoneEditorError.unavailable) { _ = try await pending.value }
    #expect(await coordinator.snapshot().entries.first?.status == .uncertain)
  }
}
private func editorClientPages() throws -> [Data] {
  let first = try editorClientVector("profile-first-page")
  let last = try editorClientVector("profile-final-page")
  var middle = try #require(JSONSerialization.jsonObject(with: first) as? [String: Any])
  middle["offset"] = 8
  middle["nextOffset"] = 16
  middle["controls"] = (9...16).map {
    [
      "id": String(format: "ce000000-0000-0000-0000-%012d", $0), "generatedLabel": "Control \($0)",
      "labelOverride": NSNull(),
    ] as [String: Any]
  }
  // Shared final-page vector is independently valid, not a complete paginated snapshot.
  // Give this synthetic assembled profile distinct final control IDs.
  var final = try #require(JSONSerialization.jsonObject(with: last) as? [String: Any])
  final["controls"] = (17...18).map {
    [
      "id": String(format: "ce000000-0000-0000-0000-%012d", $0), "generatedLabel": "Control \($0)",
      "labelOverride": NSNull(),
    ] as [String: Any]
  }
  return [
    first, try JSONSerialization.data(withJSONObject: middle),
    try JSONSerialization.data(withJSONObject: final),
  ]
}
private actor EditorTestCredentials: ControlCredentialSource {
  let credential: PhoneCredential
  private(set) var calls = 0
  init() throws {
    credential = try PhoneCredential(
      hostPin: editorClientPin, phoneID: "phone-a", epoch: 1, expiresAt: 100_000,
      token: Data(repeating: 34, count: 32))
  }
  func load(hostPin: String, now: UInt64) -> PhoneCredential? {
    calls += 1
    return credential
  }
}
@MainActor private final class EditorFrameScript: EnrollmentFrameIO {
  var frames: [ControlTLSFrame]
  var commands: [String] = []
  var closed = false
  init(_ fields: [[String: Any]]) throws {
    frames = try fields.map {
      try ControlTLSFrame(kind: .control, payload: JSONSerialization.data(withJSONObject: $0))
    }
  }
  func connect() async throws {}
  func offer(_ frame: ControlTLSFrame) -> Bool {
    guard !closed, let fields = try? EditorWire.parse(frame.payload),
      let command = fields["command"]?.text
    else { return false }
    commands.append(command)
    return true
  }
  func receive() async throws -> ControlTLSFrame {
    guard !closed, !frames.isEmpty else { throw PhoneEditorError.unavailable }
    return frames.removeFirst()
  }
  func close() { closed = true }
}
private func editorClientHello(version: Int = 12) -> [String: Any] {
  [
    "version": 1, "command": "hello", "controlVersion": version, "role": "management",
    "authorityInstanceId": editorClientAuthority, "inputVersion": 1, "documentVersion": 1,
    "capabilitiesVersion": 1, "inputEnabled": false,
  ]
}
private func editorClientAdmission(input: Bool = false) -> [String: Any] {
  [
    "version": 1, "command": "authenticated", "authorityInstanceId": editorClientAuthority,
    "phoneId": "phone-a", "credentialEpoch": "1", "connectionId": editorClientConnection,
    "expiresAt": 60_100, "role": "management", "inputSessionAvailable": false,
    "inputEnabled": input,
  ]
}
extension PhoneEditorTests {
  @Test func completePinnedReadOnlyPublishesAfterAllPagesAndRejectsDrift() async throws {
    let pages = try editorClientPages()
    let pin = try EditorReadPin(
      scope: editorClientScope(), revision: "7", sourceHash: String(repeating: "a", count: 64),
      profileID: "aaaaaaaa-0000-0000-0000-000000000001")
    let transport = EditorScriptTransport(pages.map { .init(bytes: $0) })
    let coordinator = PhoneEditorCoordinator(
      journal: try EditorJournal(
        certificateSHA256: editorClientPin, storage: EditorClientMemoryStore()),
      transport: transport)
    #expect(try await coordinator.readProfile(pin).controls.count == 18)
    #expect(await coordinator.snapshot().profiles.count == 1)
    for mode in ["phone", "epoch", "name", "total", "duplicate"] {
      var steps = pages.map { EditorScriptTransport.Step(bytes: $0) }
      if mode == "phone" {
        steps[1].phone = "phone-b"
      } else if mode == "epoch" {
        steps[1].epoch = 2
      } else {
        var fields = try #require(JSONSerialization.jsonObject(with: pages[1]) as? [String: Any])
        if mode == "name" { fields["name"] = "Changed name" }
        if mode == "total" { fields["totalControls"] = 19 }
        if mode == "duplicate" {
          var rows = try #require(fields["controls"] as? [[String: Any]])
          rows[0]["id"] = "ce000000-0000-0000-0000-000000000001"
          fields["controls"] = rows
        }
        steps[1] = .init(bytes: try JSONSerialization.data(withJSONObject: fields))
      }
      let isolated = PhoneEditorCoordinator(
        journal: try EditorJournal(
          certificateSHA256: editorClientPin, storage: EditorClientMemoryStore()),
        transport: EditorScriptTransport(steps))
      await #expect(throws: (any Error).self) { _ = try await isolated.readProfile(pin) }
      #expect(await isolated.snapshot().profiles.isEmpty)
    }
  }
  @Test @MainActor func exactRole12HandshakeOneRequestAndNoInputAuthority() async throws {
    let endpoint = try TrustedHostEndpoint(
      host: "127.0.0.1", port: 1234, certificatePin: editorClientPin,
      authorityInstanceID: editorClientAuthority)
    let admitted = try #require(
      JSONSerialization.jsonObject(with: editorClientVector("label-admitted")) as? [String: Any])
    let source = try EditorTestCredentials()
    let io = try EditorFrameScript([editorClientHello(), editorClientAdmission(), admitted])
    let client = PhoneEditorRPC(
      endpoint: endpoint, credentials: source, makeIO: { io }, now: { 100 })
    let result = try await client.exchange(.label(editorClientIntent()))
    #expect(result.phoneID == "phone-a")
    #expect(result.credentialEpoch == 1)
    #expect(io.commands == ["hello", "authenticate", "configuration-set-control-label"])
    #expect(io.closed)
    for wrongHello in [
      editorClientHello(version: 11),
      editorClientHello().merging(["private": "not-allowed"]) { _, b in b },
    ] {
      let storage = try EditorTestCredentials()
      let badIO = try EditorFrameScript([wrongHello])
      let rejected = PhoneEditorRPC(
        endpoint: endpoint, credentials: storage, makeIO: { badIO }, now: { 100 })
      await #expect(throws: (any Error).self) {
        _ = try await rejected.exchange(.label(editorClientIntent()))
      }
      #expect(await storage.calls == 0)
      #expect(badIO.commands == ["hello"])
      #expect(badIO.closed)
    }
    let badIO = try EditorFrameScript([editorClientHello(), editorClientAdmission(input: true)])
    let rejected = PhoneEditorRPC(
      endpoint: endpoint, credentials: source, makeIO: { badIO }, now: { 100 })
    await #expect(throws: (any Error).self) {
      _ = try await rejected.exchange(.label(editorClientIntent()))
    }
    #expect(badIO.commands == ["hello", "authenticate"])
  }
}
private actor EditorPausedCredentials: ControlCredentialSource {
  private var continuation: CheckedContinuation<PhoneCredential?, Never>?
  private(set) var calls = 0
  func load(hostPin: String, now: UInt64) async -> PhoneCredential? {
    calls += 1
    return await withCheckedContinuation { continuation = $0 }
  }
  func release() throws {
    continuation?.resume(
      returning: try PhoneCredential(
        hostPin: editorClientPin, phoneID: "phone-a", epoch: 1, expiresAt: 100_000,
        token: Data(repeating: 34, count: 32)))
    continuation = nil
  }
}
extension PhoneEditorTests {
  @Test @MainActor func cancellationDuringCredentialLoadCannotOfferAuthenticationOrWrite()
    async throws
  {
    let endpoint = try TrustedHostEndpoint(
      host: "127.0.0.1", port: 1234, certificatePin: editorClientPin,
      authorityInstanceID: editorClientAuthority)
    let source = EditorPausedCredentials()
    let io = try EditorFrameScript([editorClientHello(), editorClientAdmission()])
    let client = PhoneEditorRPC(
      endpoint: endpoint, credentials: source, makeIO: { io }, now: { 100 })
    let task = Task { try await client.exchange(.label(editorClientIntent())) }
    for _ in 0..<100 {
      if await source.calls > 0 { break }
      try await Task.sleep(for: .milliseconds(1))
    }
    try #require(await source.calls == 1)
    client.cancel()
    try await source.release()
    await #expect(throws: (any Error).self) { _ = try await task.value }
    #expect(io.commands == ["hello"])
    #expect(io.closed)
  }
}
// Only this lock-protected test result crosses the constrained-thread boundary.
private final class EditorWireThreadResult: @unchecked Sendable {
  private let lock = NSLock()
  private var failed = false
  let done = DispatchSemaphore(value: 0)
  func finish(_ value: Bool) {
    lock.withLock { failed = value }
    done.signal()
  }
  var isFailure: Bool { lock.withLock { failed } }
}
extension PhoneEditorTests {
  @Test func worstEscapedPageFitsConstrainedThreadAndInlineBudgets() throws {
    var fields = try #require(
      JSONSerialization.jsonObject(with: editorClientVector("profile-first-page")) as? [String: Any]
    )
    fields["name"] = String(repeating: "\u{0000}", count: 256)
    fields["totalControls"] = 8
    fields["nextOffset"] = NSNull()
    fields["controls"] = (1...8).map {
      [
        "id": String(format: "ce000000-0000-0000-0000-%012d", $0),
        "generatedLabel": String(repeating: "\u{0000}", count: 128),
        "labelOverride": String(repeating: "\u{0000}", count: 128),
      ]
    }
    let data = try JSONSerialization.data(withJSONObject: fields)
    try #require(data.count <= 16_384)
    let pin = try EditorReadPin(
      scope: editorClientScope(), revision: "7", sourceHash: String(repeating: "a", count: 64),
      profileID: "aaaaaaaa-0000-0000-0000-000000000001")
    let result = EditorWireThreadResult()
    let thread = Thread {
      do {
        guard
          case .profile(let page) = try EditorWire.reply(
            data, request: .profile(pin, 0), connection: editorClientConnection),
          page.controls.count == 8
        else { throw PhoneEditorError.rejected }
        result.finish(false)
      } catch { result.finish(true) }
    }
    thread.stackSize = 512 * 1024
    thread.start()
    try #require(result.done.wait(timeout: .now() + 5) == .success)
    #expect(!result.isFailure)
    #expect(MemoryLayout<EditorProfilePage>.size <= 256)
    #expect(MemoryLayout<EditorReceipt>.size <= 128)
  }
}
extension PhoneEditorTests {
  @Test func conflictErrorsUnknownAndPendingNeverRetire() async throws {
    for vector in ["label-conflict", "editor_unavailable", "unknown"] {
      let journal = try EditorJournal(
        certificateSHA256: editorClientPin, storage: EditorClientMemoryStore())
      let intent = try editorClientIntent()
      try journal.enqueue(intent)
      let steps: [EditorScriptTransport.Step] =
        vector == "unknown" ? [] : [.init(bytes: try editorClientVector(vector))]
      let coordinator = PhoneEditorCoordinator(
        journal: journal, transport: EditorScriptTransport(steps))
      if vector == "unknown" {
        await #expect(throws: (any Error).self) {
          _ = try await coordinator.submit(intent.operationID, endpointScope: editorClientScope())
        }
      } else {
        _ = try await coordinator.submit(intent.operationID, endpointScope: editorClientScope())
      }
      #expect(await coordinator.snapshot().entries.count == 1)
    }
    let journal = try EditorJournal(
      certificateSHA256: editorClientPin, storage: EditorClientMemoryStore())
    let intent = try editorClientIntent()
    try journal.enqueue(intent)
    let coordinator = PhoneEditorCoordinator(
      journal: journal,
      transport: EditorScriptTransport([
        .init(bytes: try editorClientVector("label-admitted")),
        .init(bytes: try editorClientVector("status-pending-unknown")),
      ]))
    _ = try await coordinator.submit(intent.operationID, endpointScope: editorClientScope())
    #expect(
      try await coordinator.reconcile(intent.operationID, endpointScope: editorClientScope())
        == .retained)
    #expect(await coordinator.snapshot().entries.first?.status == .uncertain)
  }
}
