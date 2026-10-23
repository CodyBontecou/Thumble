import Foundation
import Testing

@testable import MobileInputCore

private func creditFrame(_ sequence: UInt64, scope: UInt8 = 1) throws -> ControlTLSFrame {
  var bytes = Data([84, 72, 73, 49, 0, 0, 0, 0])
  bytes.append(Data(repeating: scope, count: 24))
  for shift in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: sequence >> (shift * 8))) }
  bytes.append(Data(repeating: 0, count: 68))
  return try ControlTLSFrame(kind: .input, payload: bytes)
}
private func creditControl() throws -> ControlTLSFrame {
  try ControlTLSFrame(kind: .control, payload: Data([1]))
}
@MainActor private final class CreditClock {
  var value = ContinuousClock.now
  func advance(_ milliseconds: Int64) { value = value.advanced(by: .milliseconds(milliseconds)) }
  func queue() throws -> NativeInputWriteQueue {
    let result = NativeInputWriteQueue()
    try result.enable(now: { self.value })
    return result
  }
}
@Test @MainActor private func nativeInputCreditsBoundActiveWritesAndCoalescePressure() throws {
  let queue = try CreditClock().queue()
  for sequence in UInt64(0)..<8 {
    let frame = try creditFrame(sequence)
    try queue.offer(frame)
    #expect(try queue.next()?.payload == frame.payload)
  }
  for sequence in UInt64(8)...100 { try queue.offer(creditFrame(sequence)) }
  #expect(try queue.next() == nil)
  // An already dispatched write counts even before its transport completion callback.
  try queue.offer(creditControl())
  #expect(try queue.next()?.kind == .control)
  #expect(try queue.next() == nil)
  try queue.acknowledge(
    scope: Data(try creditFrame(0).payload.prefix(32)), sequence: 7, highestOffered: 100)
  #expect(try queue.next() == nil)  // Validated owner completes the control transaction separately.
  try queue.completeControl()
  #expect(try queue.next()?.payload == creditFrame(100).payload)
}
@Test @MainActor private func nativeInputCreditsRejectFutureWrongScopeAndRegressingAcknowledgments()
  throws
{
  let queue = try CreditClock().queue()
  try queue.offer(creditFrame(0))
  _ = try queue.next()
  let scope = Data(try creditFrame(0).payload.prefix(32))
  #expect(throws: ControlTLSError.self) {
    try queue.acknowledge(scope: scope, sequence: 2, highestOffered: 1)
  }
  #expect(throws: ControlTLSError.self) {
    try queue.acknowledge(scope: Data(repeating: 9, count: 32), sequence: 0, highestOffered: 1)
  }
  try queue.acknowledge(scope: scope, sequence: 1, highestOffered: 1)
  #expect(throws: ControlTLSError.self) {
    try queue.acknowledge(scope: scope, sequence: 0, highestOffered: 1)
  }
}
@Test @MainActor
private func nativeInputCreditsAcceptSharedUdpCounterBeyondTlsAndDropAcknowledgedLatest() throws {
  let queue = try CreditClock().queue()
  try queue.offer(creditFrame(0))
  _ = try queue.next()
  try queue.offer(creditFrame(20))
  try queue.acknowledge(
    scope: Data(try creditFrame(0).payload.prefix(32)), sequence: 20, highestOffered: 20)
  #expect(try queue.next() == nil)
  try queue.offer(creditFrame(21))
  #expect(try queue.next()?.payload == creditFrame(21).payload)
}
@Test @MainActor private func nativeInputCreditsRenewOnlyBehindValidatedControlBarrier() throws {
  let queue = try CreditClock().queue()
  for sequence in UInt64(0)..<8 {
    try queue.offer(creditFrame(sequence))
    _ = try queue.next()
  }
  try queue.offer(creditFrame(8))
  #expect(throws: ControlTLSError.self) { try queue.validatedRenewalReply() }
  try queue.offer(creditControl())
  _ = try queue.next()
  try queue.validatedRenewalReply()
  try queue.offer(creditFrame(0, scope: 2))  // New zero removes the old unsent held state.
  #expect(try queue.next()?.payload == creditFrame(0, scope: 2).payload)
  try queue.completeControl()
  #expect(try queue.next() == nil)
  #expect(throws: ControlTLSError.self) {
    try queue.acknowledge(
      scope: Data(try creditFrame(0).payload.prefix(32)), sequence: 8, highestOffered: 8)
  }
}
@Test @MainActor private func nativeInputCreditsDoNotRetireQueuedOldPacketZero() throws {
  let queue = try CreditClock().queue()
  try queue.offer(creditControl())
  _ = try queue.next()
  try queue.offer(creditFrame(0))
  #expect(throws: ControlTLSError.self) { try queue.validatedRenewalReply() }
}
@Test @MainActor
private func nativeInputCreditsRejectStaleQueuedHeldAndNeutralIncludingClockRollback() throws {
  for zero in [true, false] {
    let clock = CreditClock()
    let queue = try clock.queue()
    if !zero {
      try queue.offer(creditFrame(0))
      _ = try queue.next()
    }
    try queue.offer(creditFrame(zero ? 0 : 1))
    clock.advance(350)
    #expect(throws: ControlTLSError.self) { try queue.next() }
  }
  let clock = CreditClock()
  let queue = try clock.queue()
  try queue.offer(creditFrame(0))
  clock.advance(-1)
  #expect(throws: ControlTLSError.self) { try queue.next() }
  let fresh = CreditClock()
  let freshQueue = try fresh.queue()
  try freshQueue.offer(creditFrame(0))
  fresh.advance(349)
  #expect(try freshQueue.next() != nil)
}
@Test @MainActor private func nativeInputCreditsCloseCannotReplayPendingOrReopen() throws {
  let queue = try CreditClock().queue()
  try queue.offer(creditFrame(0))
  _ = try queue.next()
  try queue.offer(creditFrame(1))
  queue.close()
  #expect(try queue.next() == nil)
  #expect(throws: ControlTLSError.self) { try queue.completeControl() }
  #expect(throws: ControlTLSError.self) { try queue.offer(creditFrame(2)) }
}
@Test @MainActor private func nativeInputCreditsGenericAndLegacyQueuesRemainUnpaced() throws {
  let queue = NativeInputWriteQueue()
  try queue.offer(creditControl())
  _ = try queue.next()
  for sequence in UInt64(0)...30 {
    try queue.offer(creditFrame(sequence))
    #expect(try queue.next() != nil)
  }
  try queue.completeControl()
}

@MainActor private final class WeakCreditClock {
  weak var value: CreditClock?
}
@MainActor private func ownedClockQueue(_ weakClock: WeakCreditClock) throws
  -> NativeInputWriteQueue
{
  let clock = CreditClock()
  weakClock.value = clock
  return try clock.queue()
}
@Test @MainActor private func nativeInputCreditsCloseReleasesInjectedClockOwner() throws {
  let weakClock = WeakCreditClock()
  let queue = try ownedClockQueue(weakClock)
  #expect(weakClock.value != nil)
  queue.close()
  #expect(weakClock.value == nil)
}
