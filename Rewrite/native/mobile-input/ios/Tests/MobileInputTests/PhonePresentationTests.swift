import Foundation
import Testing
import zlib

@testable import MobileInputCore

private func presentationFixture() throws -> [String: Any] {
  let url = try #require(
    Bundle.module.url(
      forResource: "saved-controller-presentation-control-v10",
      withExtension: "json", subdirectory: "Fixtures"))
  return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}
private func presentationRequest(count: Int = 2) throws -> PhonePresentationRequest {
  let ids =
    count == 2 ? ["synthetic-south", "synthetic-east"] : (0..<count).map { "synthetic-\($0)" }
  let regions = ids.enumerated().map { index, id in
    ControlRegion(
      id: id, action: "south", x: Double(index % 8) * 0.1,
      y: Double(index / 8) * 0.1, width: 0.03, height: 0.03)
  }
  return try PhonePresentationRequest(
    saved: SavedControllerRequest(
      configurationRevision: "3",
      sourceHash: String(repeating: "a", count: 64),
      profileID: "aaaaaaaa-0000-0000-0000-000000000001",
      generation: "7", revision: "2", viewportWidth: "874", viewportHeight: "393"),
    map: SavedControllerMap(
      map: ControlMap(generation: "7", revision: "2", controls: regions),
      configurationSha256: String(repeating: "b", count: 64)), colorScheme: "light")
}
private func presentationFields(_ value: [String: Any]) throws -> [String: EnrollmentJSON.Value] {
  try EnrollmentJSON.parse(JSONSerialization.data(withJSONObject: value))
}
private func presentationMetadata(
  _ fields: [String: Any]? = nil,
  request: PhonePresentationRequest? = nil
) throws -> PhonePresentationMetadata {
  try PhonePresentationWire.metadata(
    presentationFields(try fields ?? #require(presentationFixture()["reply"] as? [String: Any])),
    request: try request ?? presentationRequest(), authority: "synthetic-authority",
    connection: String(repeating: "cd", count: 16))
}
@Test private func presentationGoldenKeepsInstalledAndCosmeticPinsSeparateAndVerifiesIcon() throws {
  let fixture = try presentationFixture()
  let request = try presentationRequest()
  let fields = request.fields(connection: String(repeating: "cd", count: 16))
  #expect(
    NSDictionary(dictionary: fields).isEqual(to: try #require(fixture["request"] as? [String: Any]))
  )
  let metadata = try presentationMetadata()
  #expect(metadata.controls.count == 2 && metadata.freshness == "observed")
  #expect(metadata.bridgeEvent["expectedConfigurationRevision"] as? String == "3")
  #expect(metadata.bridgeEvent["presentationRevision"] as? String == "4")
  #expect(
    metadata.bridgeEvent["authorityInstanceId"] == nil
      && metadata.bridgeEvent["connectionId"] == nil)
  let icon = try PhonePresentationWire.icon(
    presentationFields(try #require(fixture["iconReply"] as? [String: Any])),
    metadata: metadata, control: metadata.controls[0], authority: "synthetic-authority",
    connection: String(repeating: "cd", count: 16))
  #expect(icon.byteCount == 104)
  let notification = try icon.notification(metadata: metadata, controlId: "synthetic-south")
  #expect(notification["kind"] as? String == "icon" && notification["bank"] as? String == "base")
  #expect(notification["freshness"] == nil && notification["controls"] == nil)
  #expect(throws: PhonePresentationError.self) {
    try icon.notification(metadata: metadata, controlId: "synthetic-east")
  }
}
@Test(arguments: [
  "unknown", "epoch", "source", "sha", "viewport", "scheme", "revision", "ids", "duplicate",
  "label", "partial-icon", "icon-size",
])
private func presentationMetadataRejectsMalformedOrDifferentInstalledMap(_ fault: String) throws {
  var row = try #require(presentationFixture()["reply"] as? [String: Any])
  switch fault {
  case "unknown": row["extra"] = "no"
  case "epoch": row["generation"] = "8"
  case "source": row["expectedSourceHash"] = String(repeating: "d", count: 64)
  case "sha": row["configurationSha256"] = String(repeating: "d", count: 64)
  case "viewport": row["viewportWidth"] = "874.0"
  case "scheme": row["colorScheme"] = "dark"
  case "revision": row["presentationRevision"] = "2"
  case "ids": row["control1Id"] = "another-control"
  case "duplicate": row["control1Id"] = row["control0Id"]
  case "label": row["control0Label"] = String(repeating: "😀", count: 33)
  case "partial-icon": row.removeValue(forKey: "control0IconName")
  default: row["control0IconByteCount"] = 8193
  }
  #expect(throws: PhonePresentationError.self) { try presentationMetadata(row) }
}
@Test(arguments: [
  "hash", "size", "base64", "revision", "control", "unknown", "duplicate-key", "utf8",
])
private func presentationIconRejectsTamperingAndMalformedFrames(_ fault: String) throws {
  let metadata = try presentationMetadata()
  var row = try #require(presentationFixture()["iconReply"] as? [String: Any])
  switch fault {
  case "hash": row["iconSHA256"] = String(repeating: "d", count: 64)
  case "size": row["byteCount"] = 103
  case "base64": row["pngBase64"] = "abcd=xyz"
  case "revision": row["presentationRevision"] = "5"
  case "control": row["controlId"] = "synthetic-east"
  case "unknown": row["extra"] = 1
  case "duplicate-key":
    #expect(throws: (any Error).self) {
      try EnrollmentJSON.parse(Data(#"{"kind":"icon","kind":"icon"}"#.utf8))
    }
    return
  default:
    #expect(throws: (any Error).self) {
      try EnrollmentJSON.parse(Data([123, 34, 97, 34, 58, 34, 255, 34, 125]))
    }
    return
  }
  #expect(throws: PhonePresentationError.self) {
    try PhonePresentationWire.icon(
      presentationFields(row), metadata: metadata, control: metadata.controls[0],
      authority: "synthetic-authority", connection: String(repeating: "cd", count: 16))
  }
}
private func pngChunk(_ type: String, _ payload: Data) -> Data {
  var result = Data()
  func append(_ value: UInt32) {
    for shift in [24, 16, 8, 0] { result.append(UInt8(truncatingIfNeeded: value >> shift)) }
  }
  append(UInt32(payload.count))
  result.append(Data(type.utf8))
  result.append(payload)
  let crc = result.dropFirst(4).withUnsafeBytes {
    crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt($0.count))
  }
  append(UInt32(truncatingIfNeeded: crc))
  return result
}
private func pngData(
  scan: Data, color: UInt8 = 6, beforeData: Data = Data(), afterData: Data = Data(),
  suffix: Data = Data()
) throws -> Data {
  var compressed = [UInt8](repeating: 0, count: Int(compressBound(uLong(scan.count))))
  var length = uLong(compressed.count)
  let code = compressed.withUnsafeMutableBufferPointer { output in
    scan.withUnsafeBytes { input in
      compress2(
        output.baseAddress, &length, input.bindMemory(to: UInt8.self).baseAddress,
        uLong(input.count), Z_BEST_COMPRESSION)
    }
  }
  #expect(code == Z_OK)
  let header = Data([0, 0, 0, 32, 0, 0, 0, 32, 8, color, 0, 0, 0])
  return Data([137, 80, 78, 71, 13, 10, 26, 10]) + pngChunk("IHDR", header) + beforeData
    + pngChunk("IDAT", Data(compressed.prefix(Int(length))) + suffix) + afterData
    + pngChunk("IEND", Data())
}
@Test private func presentationPngBoundsCrcDeflateFiltersAndContainerOrder() throws {
  let fixture = try #require(presentationFixture()["iconReply"] as? [String: Any])
  let encoded = try #require(fixture["pngBase64"] as? String)
  let valid = try #require(Data(base64Encoded: encoded))
  try PhonePresentationPNG.verify(valid)
  let rgba = Data(repeating: 0, count: 32 * 129)
  try PhonePresentationPNG.verify(pngData(scan: rgba))
  try PhonePresentationPNG.verify(pngData(scan: Data(repeating: 0, count: 32 * 97), color: 2))
  var crc = valid
  crc[crc.count - 1] ^= 1
  var filter = rgba
  filter[129] = 5
  for bad in [
    Data(), crc, valid + Data([0]), Data(repeating: 0, count: 8193),
    try pngData(scan: rgba + Data([0])), try pngData(scan: filter),
    try pngData(scan: rgba, suffix: Data([0])),
    try pngData(scan: rgba, beforeData: pngChunk("acTL", Data(repeating: 0, count: 8))),
    try pngData(scan: rgba, afterData: pngChunk("IHDR", Data(repeating: 0, count: 13))),
    try pngData(scan: rgba, beforeData: pngChunk("NOPE", Data())),
    try pngData(scan: rgba, beforeData: pngChunk("iCCP", Data([1, 0, 0]))),
    try pngData(scan: rgba, beforeData: pngChunk("zTXt", Data([1, 0, 0]))),
    try pngData(scan: rgba, beforeData: pngChunk("iTXt", Data([1, 0, 1]))),
  ] {
    #expect(throws: PhonePresentationError.self) { try PhonePresentationPNG.verify(bad) }
  }
}

private actor PresentationStorage: ControlCredentialSource {
  private(set) var calls = 0
  func load(hostPin: String, now: UInt64) throws -> PhoneCredential? {
    calls += 1
    return try PhoneCredential(
      hostPin: hostPin, phoneID: "phone-a", epoch: 1,
      expiresAt: 100_000, token: Data(repeating: 34, count: 32))
  }
}
@MainActor private final class PresentationIO: EnrollmentFrameIO {
  var frames: [ControlTLSFrame]
  var sent: [[String: EnrollmentJSON.Value]] = []
  var closed = false, pauseMetadata = false, waiting = false
  var received = 0
  var wall: UInt64 = 100
  var beforeReceive: ((Int) -> Void)?
  init(_ fields: [[String: Any]]) throws {
    frames = try fields.map {
      try ControlTLSFrame(kind: .control, payload: JSONSerialization.data(withJSONObject: $0))
    }
  }
  func connect() async throws {}
  func offer(_ frame: ControlTLSFrame) -> Bool {
    guard !closed, frame.kind == .control, let value = try? EnrollmentJSON.parse(frame.payload)
    else { return false }
    sent.append(value)
    return true
  }
  func receive() async throws -> ControlTLSFrame {
    received += 1
    beforeReceive?(received)
    if pauseMetadata && received == 3 {
      waiting = true
      while !closed { try await Task.sleep(for: .milliseconds(5)) }
    }
    guard !closed, !frames.isEmpty else { throw PhonePresentationError.rejected }
    return frames.removeFirst()
  }
  func close() { closed = true }
}
@MainActor private func presentationSetup(fault: String = "") throws -> (
  PhonePresentationClient, PresentationIO, PresentationStorage
) {
  let fixture = try presentationFixture()
  var hello: [String: Any] = [
    "version": 1, "command": "hello", "authorityInstanceId": "synthetic-authority",
    "controlVersion": 10, "role": "management", "inputVersion": 1, "documentVersion": 1,
    "capabilitiesVersion": 1, "inputEnabled": false,
  ]
  var admission: [String: Any] = [
    "version": 1, "command": "authenticated", "authorityInstanceId": "synthetic-authority",
    "phoneId": "phone-a", "credentialEpoch": "1",
    "connectionId": String(repeating: "cd", count: 16),
    "expiresAt": 61100, "inputSessionAvailable": false, "inputEnabled": false, "role": "management",
  ]
  var reply = try #require(fixture["reply"] as? [String: Any])
  switch fault {
  case "input-role": hello["role"] = "input"
  case "wrong-version": hello["controlVersion"] = 9
  case "input-enabled": admission["inputEnabled"] = true
  case "wrong-phone": admission["phoneId"] = "other-phone"
  case "credential-expiry": admission["expiresAt"] = 100001
  case "unknown-error":
    reply = [
      "version": 1, "command": "configuration-presentation-result",
      "connectionId": String(repeating: "cd", count: 16), "kind": "error",
      "error": "raw failure text",
    ]
  default: break
  }
  let io = try PresentationIO([
    hello, admission, reply, try #require(fixture["iconReply"] as? [String: Any]),
  ])
  if fault == "metadata-size" {
    var data = io.frames[2].payload
    data.append(contentsOf: repeatElement(32, count: 32769 - data.count))
    io.frames[2] = try ControlTLSFrame(kind: .control, payload: data)
  }
  if fault == "icon-size" {
    var data = io.frames[3].payload
    data.append(contentsOf: repeatElement(32, count: 16385 - data.count))
    io.frames[3] = try ControlTLSFrame(kind: .control, payload: data)
  }
  let storage = PresentationStorage()
  let endpoint = try TrustedHostEndpoint(
    host: "127.0.0.1", port: 1234, certificatePin: String(repeating: "1", count: 64),
    authorityInstanceID: "synthetic-authority")
  return (
    PhonePresentationClient(endpoint: endpoint, io: io, storage: storage, now: { io.wall }), io,
    storage
  )
}
@Test @MainActor private func presentationClientUsesSeparateRoleTenBatchAndClosesWithoutInputApi()
  async throws
{
  let (client, io, storage) = try presentationSetup()
  defer { client.close() }
  let metadata = try await client.read(presentationRequest())
  #expect(!io.closed && io.sent.count == 3)
  #expect(
    io.sent[0]["controlVersion"] == .integer(10) && io.sent[0]["role"] == .string("management"))
  let icon = try await client.icon(metadata.controls[0])
  #expect(icon.byteCount == 104 && io.sent.count == 4)
  #expect(io.sent[3]["command"] == .string("configuration-presentation-icon"))
  #expect(await storage.calls == 1)
  await #expect(throws: PhonePresentationError.self) { try await client.icon(metadata.controls[0]) }
  client.close()
  #expect(io.closed)
  await #expect(throws: PhonePresentationError.self) {
    try await client.read(presentationRequest())
  }
}
@Test(arguments: [
  "input-role", "wrong-version", "input-enabled", "wrong-phone", "credential-expiry",
  "unknown-error", "metadata-size", "icon-size", "rollback", "local-cap",
])
@MainActor private func presentationClientRejectsRolePinsBoundsAndClockFaults(_ fault: String)
  async throws
{
  let (client, io, storage) = try presentationSetup(fault: fault)
  if fault == "rollback" { io.beforeReceive = { if $0 == 3 { io.wall = 99 } } }
  if fault == "local-cap" { io.beforeReceive = { if $0 == 3 { io.wall = 60100 } } }
  if fault == "icon-size" {
    let metadata = try await client.read(presentationRequest())
    await #expect(throws: (any Error).self) { try await client.icon(metadata.controls[0]) }
  } else {
    await #expect(throws: (any Error).self) { try await client.read(presentationRequest()) }
  }
  #expect(io.closed)
  if fault == "input-role" || fault == "wrong-version" { #expect(await storage.calls == 0) }
}
@Test @MainActor private func presentationClientCancellationClosesOnlyItsManagementChannel()
  async throws
{
  let (client, io, _) = try presentationSetup()
  io.pauseMetadata = true
  let task = Task { try await client.read(presentationRequest()) }
  for _ in 0..<100 {
    if io.waiting { break }
    try await Task.sleep(for: .milliseconds(5))
  }
  #expect(io.waiting)
  client.close()
  task.cancel()
  await #expect(throws: (any Error).self) { try await task.value }
  #expect(io.closed)
  // There is deliberately no input owner/channel on this API or in its cleanup.
}
private final class PresentationStackResult: @unchecked Sendable {
  private let lock = NSLock()
  private var failure: String?
  func fail() {
    lock.lock()
    failure = "constrained_presentation_failed"
    lock.unlock()
  }
  func read() -> String? {
    lock.lock()
    defer { lock.unlock() }
    return failure
  }
}
@Test private func presentationMaximum64ControlsAndPngDecodeOnConstrainedThread() throws {
  let result = PresentationStackResult()
  let done = DispatchSemaphore(value: 0)
  let thread = Thread {
    defer { done.signal() }
    do {
      var fields = try #require(presentationFixture()["reply"] as? [String: Any])
      fields = fields.filter { !$0.key.hasPrefix("control") }
      fields["controlCount"] = 64
      for index in 0..<64 {
        fields["control\(index)Id"] = "synthetic-\(index)"
        fields["control\(index)Label"] = String(repeating: "x", count: 128)
      }
      let metadata = try presentationMetadata(fields, request: presentationRequest(count: 64))
      guard metadata.controls.count == 64 else { throw PhonePresentationError.rejected }
      let fixture = try #require(presentationFixture()["iconReply"] as? [String: Any])
      let encoded = try #require(fixture["pngBase64"] as? String)
      let data = try #require(Data(base64Encoded: encoded))
      for _ in 0..<64 { try PhonePresentationPNG.verify(data) }
    } catch { result.fail() }
  }
  thread.stackSize = 512 * 1024
  thread.start()
  #expect(done.wait(timeout: .now() + 10) == .success)
  #expect(result.read() == nil)
}

@MainActor private final class PresentationBatchFake: PhonePresentationBatch {
  var closed = false, waiting = false, returned = false
  var fail = false, paused = false
  var reads = 0, icons = 0
  var metadata: PhonePresentationMetadata?
  var beforeReturn: (() -> Void)?
  func read(_ request: PhonePresentationRequest) async throws -> PhonePresentationMetadata {
    reads += 1
    if paused {
      waiting = true
      while !closed { try? await Task.sleep(for: .milliseconds(5)) }
    }
    if fail { throw PhonePresentationError.unavailable("presentation_stale") }
    var fields = try #require(presentationFixture()["reply"] as? [String: Any])
    fields["colorScheme"] = request.colorScheme
    let result = try presentationMetadata(fields, request: request)
    metadata = result
    beforeReturn?()
    returned = true
    return result
  }
  func icon(_ control: PhonePresentationControl) async throws -> PhonePresentationIcon {
    icons += 1
    let metadata = try #require(metadata)
    var fields = try #require(presentationFixture()["iconReply"] as? [String: Any])
    fields["colorScheme"] = metadata.request.colorScheme
    return try PhonePresentationWire.icon(
      presentationFields(fields), metadata: metadata, control: control,
      authority: "synthetic-authority", connection: String(repeating: "cd", count: 16))
  }
  func close() { closed = true }
}
@MainActor private func awaitPresentation(_ condition: () -> Bool) async throws {
  for _ in 0..<1000 {
    if condition() { return }
    try await Task.sleep(for: .milliseconds(5))
  }
  Issue.record("presentation_test_barrier_not_reached")
}
@Test @MainActor
private func
  presentationPollerRefreshesUnchangedMetadataCachesVerifiedIconsAndKeepsFailureCosmetic()
  async throws
{
  var active = true
  var batches: [PresentationBatchFake] = []
  var events: [[String: Any]] = []
  let poller = PhonePresentationPoller(
    request: try presentationRequest(),
    factory: {
      let batch = PresentationBatchFake()
      batch.fail = batches.count == 2
      batches.append(batch)
      return batch
    }, colorScheme: { "light" }, active: { active },
    notification: { event in
      events.append(event)
      if event["kind"] as? String == "error" { active = false }
    }, pause: { await Task.yield() })
  defer { poller.close() }
  poller.start()
  try await awaitPresentation { events.contains(where: { $0["kind"] as? String == "error" }) }
  #expect(events.filter { $0["kind"] as? String == "presentation" }.count == 2)
  #expect(events.filter { $0["kind"] as? String == "icon" }.count == 2)
  #expect(events.last?["error"] as? String == "presentation_stale")
  #expect(batches.count == 3 && batches.allSatisfy(\.closed))
  #expect(batches.map(\.icons) == [1, 0, 0])
  #expect(events.last?["presentationRevision"] == nil)  // A failed refresh never replays cached metadata.
}
@Test @MainActor private func presentationPollerRejectsLateOwnerAndClosedCallbacks() async throws {
  for ownerChanged in [false, true] {
    var active = true
    let batch = PresentationBatchFake()
    batch.paused = !ownerChanged
    if ownerChanged { batch.beforeReturn = { active = false } }
    var events = 0
    let poller = PhonePresentationPoller(
      request: try presentationRequest(), factory: { batch },
      colorScheme: { "light" }, active: { active }, notification: { _ in events += 1 },
      pause: { await Task.yield() })
    poller.start()
    if ownerChanged {
      try await awaitPresentation { batch.closed }
    } else {
      try await awaitPresentation { batch.waiting }
      poller.close()
      try await awaitPresentation { batch.returned }
    }
    #expect(events == 0 && batch.closed)
    poller.close()
  }
}
@Test @MainActor private func presentationPollerRefreshesThemeBeforePublishingSupersededMetadata()
  async throws
{
  var theme = "light"
  var active = true
  var batches: [PresentationBatchFake] = []
  var events: [[String: Any]] = []
  let poller = PhonePresentationPoller(
    request: try presentationRequest(),
    factory: {
      let batch = PresentationBatchFake()
      if batches.isEmpty { batch.beforeReturn = { theme = "dark" } }
      batches.append(batch)
      return batch
    }, colorScheme: { theme }, active: { active },
    notification: { event in
      events.append(event)
      if event["kind"] as? String == "icon" { active = false }
    }, pause: { await Task.yield() })
  defer { poller.close() }
  poller.start()
  try await awaitPresentation { events.contains(where: { $0["kind"] as? String == "icon" }) }
  #expect(batches.count == 2 && batches.allSatisfy(\.closed))
  #expect(events.count == 2 && events.allSatisfy { $0["colorScheme"] as? String == "dark" })
}

@Test(arguments: ["in-flight", "sleeping"])
@MainActor private func presentationPollerThemeRefreshCancelsOnlyCosmeticWaitAndRestartsPromptly(
  _ mode: String
) async throws {
  var theme = "light"
  var active = true
  var sleeping = false
  var batches: [PresentationBatchFake] = []
  var events: [[String: Any]] = []
  let poller = PhonePresentationPoller(
    request: try presentationRequest(),
    factory: {
      let batch = PresentationBatchFake()
      batch.paused = mode == "in-flight" && batches.isEmpty
      batches.append(batch)
      return batch
    }, colorScheme: { theme }, active: { active },
    notification: { event in
      events.append(event)
      if event["kind"] as? String == "icon" && event["colorScheme"] as? String == "dark" {
        active = false
      }
    },
    pause: {
      sleeping = true
      try await Task.sleep(for: .seconds(10))
    })
  defer { poller.close() }
  poller.start()
  try await awaitPresentation { mode == "in-flight" ? batches.first?.waiting == true : sleeping }
  theme = "dark"
  poller.refreshTheme()
  try await awaitPresentation {
    events.contains(where: {
      $0["kind"] as? String == "icon" && $0["colorScheme"] as? String == "dark"
    })
  }
  #expect(batches.count == 2 && batches.allSatisfy(\.closed))
  if mode == "in-flight" { #expect(events.allSatisfy { $0["colorScheme"] as? String == "dark" }) }
  #expect(!events.contains(where: { $0["kind"] as? String == "error" }))
}
