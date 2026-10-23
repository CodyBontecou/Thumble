import Foundation
import Testing
import ThumbleContracts

@testable import MobileInputCore

@MainActor private func routeGrant(_ session: UInt8 = 3) throws -> InputPacketGrant {
  try InputPacketGrant(
    key: Data(repeating: 4, count: 32), session: Data(repeating: session, count: 16),
    noncePrefix: Data(repeating: 5, count: 4), generation: 1)
}
private func routeProgress(_ sequence: UInt64?, active: Bool = true) throws -> PhoneInputProgress {
  let value: [String: EnrollmentJSON.Value] = [
    "version": .integer(1), "command": .string("input-status"),
    "connectionId": .string("connection"),
    "sessionId": .string("session"), "generation": .string("1"), "revision": .string("1"),
    "active": .boolean(active), "inputEnabled": .boolean(false),
    "lastAcceptedSequence": sequence.map { .string(String($0)) } ?? .null,
  ]
  return try PhoneInputProgress(
    value, connection: "connection", session: "session",
    map: ControlMap(generation: "1", revision: "1", controls: []), lastOffered: sequence,
    previous: nil)
}
@Test @MainActor private func acknowledgedDatagramsStayNativeWithOneReliableNeutral() throws {
  var time: UInt64 = 0
  var tls: [Data] = []
  var udp: [Data] = []
  let route = NativeInputRoute(
    now: { time },
    udp: {
      udp.append($0)
      return true
    },
    tls: {
      tls.append($0)
      return true
    })
  let sender = try InputPacketSender(grant: routeGrant())
  #expect(route.offer(try sender.seal(.neutral)))
  #expect(route.observe(try routeProgress(0)))
  for sequence in 1...60 {
    time += 50
    #expect(route.offer(try sender.seal(.neutral)))
    #expect(route.observe(try routeProgress(UInt64(sequence))))
  }
  #expect(tls.count == 1 && udp.count == 60 && !route.reliable && !route.closed)
}
@Test @MainActor private func blackholedDatagramsFallbackAtBoundWithoutResetOrResealing() throws {
  var time: UInt64 = 0
  var tls: [Data] = []
  var udp: [Data] = []
  let route = NativeInputRoute(
    now: { time },
    udp: {
      udp.append($0)
      return true
    },
    tls: {
      tls.append($0)
      return true
    })
  let sender = try InputPacketSender(grant: routeGrant())
  let packets = try (0..<5).map { _ in try sender.seal(.neutral) }
  #expect(route.offer(packets[0]))
  #expect(route.observe(try routeProgress(0)))
  time = 20
  #expect(route.offer(packets[1]))
  time = 169
  #expect(route.offer(packets[2]) && !route.reliable)
  time = 170
  #expect(route.offer(packets[3]) && route.reliable)
  #expect(route.observe(try routeProgress(3)))
  time = 171
  #expect(route.offer(packets[4]) && route.reliable)
  #expect(tls == [packets[0], packets[3], packets[4]] && udp == [packets[1], packets[2]])
  let receiver = InputPacketReceiver(grant: try routeGrant())
  for packet in tls {
    #expect(try GamepadReport.hex(receiver.open(packet)) == GamepadReport.hex(.neutral))
  }
}
@Test @MainActor private func udpOfferFailureUsesIdenticalCiphertextAndTlsFailureIsTerminal() throws
{
  var tls: [Data] = []
  var udp: [Data] = []
  let route = NativeInputRoute(
    now: { 0 },
    udp: {
      udp.append($0)
      return false
    },
    tls: {
      tls.append($0)
      return true
    })
  let sender = try InputPacketSender(grant: routeGrant())
  #expect(route.offer(try sender.seal(.neutral)))
  let second = try sender.seal(.neutral)
  #expect(route.offer(second) && route.reliable)
  #expect(udp == [second] && tls.last == second)
  var attempts = 0
  let failed = NativeInputRoute(
    now: { 0 }, udp: { _ in true },
    tls: { _ in
      attempts += 1
      return false
    })
  let first = try InputPacketSender(grant: routeGrant()).seal(.neutral)
  #expect(!failed.offer(first) && !failed.offer(first) && failed.closed && attempts == 1)
}
@Test @MainActor private func routeRejectsRollbackForeignSourceAndInactiveProgress() throws {
  var time: UInt64 = 10
  let route = NativeInputRoute(now: { time }, udp: { _ in true }, tls: { _ in true })
  let sender = try InputPacketSender(grant: routeGrant())
  #expect(route.offer(try sender.seal(.neutral)))
  time = 9
  #expect(!route.offer(try sender.seal(.neutral)) && route.closed)
  let other = NativeInputRoute(now: { 0 }, udp: { _ in true }, tls: { _ in true })
  #expect(other.offer(try InputPacketSender(grant: routeGrant()).seal(.neutral)))
  let foreign = try InputPacketSender(grant: routeGrant(9))
  _ = try foreign.seal(.neutral)
  #expect(!other.offer(try foreign.seal(.neutral)) && other.closed)
  let inactive = NativeInputRoute(now: { 0 }, udp: { _ in true }, tls: { _ in true })
  #expect(!inactive.observe(try routeProgress(nil, active: false)) && inactive.closed)
}

@Test @MainActor private func partialAcknowledgmentCannotExtendAnOlderUnacknowledgedPacket() throws
{
  var time: UInt64 = 0
  let route = NativeInputRoute(now: { time }, udp: { _ in true }, tls: { _ in true })
  let sender = try InputPacketSender(grant: routeGrant())
  #expect(route.offer(try sender.seal(.neutral)))
  #expect(route.observe(try routeProgress(0)))
  time = 20
  #expect(route.offer(try sender.seal(.neutral)))
  time = 40
  #expect(route.offer(try sender.seal(.neutral)))
  time = 160
  #expect(route.observe(try routeProgress(1)))
  time = 189
  #expect(route.offer(try sender.seal(.neutral)) && !route.reliable)
  time = 190
  #expect(route.offer(try sender.seal(.neutral)) && route.reliable)
}
@Test @MainActor private func outstandingProgressMetadataHasAFixedBound() throws {
  let route = NativeInputRoute(now: { 0 }, udp: { _ in true }, tls: { _ in true })
  let sender = try InputPacketSender(grant: routeGrant())
  for _ in 0..<64 { #expect(route.offer(try sender.seal(.neutral))) }
  #expect(!route.reliable)
  #expect(route.offer(try sender.seal(.neutral)) && route.reliable)
}

@Test @MainActor private func freshGrantRouteRetainsKnownFallbackWithFreshProgress() throws {
  let old = NativeInputRoute(now: { 0 }, udp: { _ in false }, tls: { _ in true })
  let sender = try InputPacketSender(grant: routeGrant())
  #expect(old.offer(try sender.seal(.neutral)))
  #expect(old.offer(try sender.seal(.neutral)))
  #expect(old.observe(try routeProgress(1)) && old.reliable)
  var udp = 0
  var tls: [Data] = []
  let successor = NativeInputRoute(
    now: { 0 },
    udp: { _ in
      udp += 1
      return true
    },
    tls: {
      tls.append($0)
      return true
    }, initiallyReliable: old.reliable)
  old.close()
  let fresh = try InputPacketSender(
    grant: InputPacketGrant(
      key: Data(repeating: 6, count: 32),
      session: Data(repeating: 6, count: 16), noncePrefix: Data(repeating: 6, count: 4),
      generation: 1))
  #expect(successor.acknowledged == nil && successor.lastOffered == nil)
  #expect(successor.offer(try fresh.seal(.neutral)))
  #expect(successor.offer(try fresh.seal(.neutral)))
  #expect(tls.count == 2 && udp == 0 && successor.reliable)
  #expect(successor.observe(try routeProgress(0)))
}
