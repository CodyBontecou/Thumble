package com.thumble.rewrite.input

import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.*
import org.junit.Test

class NativeInputCreditsTest {
    private fun packet(sequence: Int, grant: Int = 1) =
        ByteArray(108).also {
            byteArrayOf(84, 72, 73, 49, 0, 0, 0, 0).copyInto(it)
            it[8] = grant.toByte()
            it[24] = 1
            for (i in 0..7) it[32 + i] = (sequence.toLong() ushr (i * 8)).toByte()
        }

    private fun sequence(frame: ControlTLSFrame) = frame.payload[32].toInt() and 255

    private fun until(condition: () -> Boolean) {
        val end = System.nanoTime() + TimeUnit.SECONDS.toNanos(2)
        while (System.nanoTime() < end) {
            if (condition()) return
            Thread.sleep(1)
        }
        fail("credit_condition_timeout")
    }

    private class IO(private val block: Boolean = false) : NativeFrameIO {
        val frames = CopyOnWriteArrayList<ControlTLSFrame>()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(if (block) 1 else 0)
        val closed = AtomicBoolean(false)
        val inbound = LinkedBlockingQueue<ControlTLSFrame>()

        override fun send(frame: ControlTLSFrame) {
            entered.countDown()
            check(release.await(2, TimeUnit.SECONDS))
            if (closed.get()) throw ControlTLSRejected()
            frames.add(frame)
        }

        override fun receive(): ControlTLSFrame {
            while (!closed.get()) inbound.poll(10, TimeUnit.MILLISECONDS)?.let {
                return it
            }
            throw ControlTLSRejected()
        }

        override fun close() {
            closed.set(true)
            release.countDown()
        }

        fun inputs() = frames.filter { it.kind == ControlTLSFrame.Kind.INPUT }
    }

    private fun fill(delivery: NativeTLSDelivery, io: IO) {
        for (i in 0..7) {
            assertTrue(delivery.offerInput(packet(i)))
            until { io.inputs().size == i + 1 }
        }
    }

    @Test
    fun eightGlobalDispatchCreditsKeepControlAheadOfOneFreshCoalescedState() {
        val io = IO()
        val delivery = NativeTLSDelivery(io, true, { 0L })
        try {
            fill(delivery, io)
            assertTrue(delivery.offerInput(packet(8)))
            assertTrue(delivery.offerInput(packet(99)))
            assertTrue(delivery.offerControl(byteArrayOf(1), true))
            until { io.frames.size == 9 }
            assertEquals(ControlTLSFrame.Kind.CONTROL, io.frames.last().kind)
            assertTrue(delivery.acknowledgeInput(packet(0).copyOfRange(0, 32), 7u, 99u))
            assertEquals(8, io.inputs().size)
            delivery.completeControl()
            until { io.inputs().size == 9 }
            assertEquals(99, sequence(io.inputs().last()))
            assertFalse(delivery.acknowledgeInput(packet(0).copyOfRange(0, 32), 100u, 99u))
            assertFalse(delivery.acknowledgeInput(packet(0, 2).copyOfRange(0, 32), 99u, 99u))
        } finally {
            delivery.close()
        }
    }

    @Test
    fun renewalRequiresValidatedOrderedReplyBeforeGlobalWindowCanChangeGrant() {
        val io = IO()
        val delivery = NativeTLSDelivery(io, true, { 0L })
        try {
            fill(delivery, io)
            assertTrue(delivery.offerInput(packet(99)))
            assertTrue(delivery.offerControl(byteArrayOf(1), true))
            until { io.frames.size == 9 }
            delivery.validatedRenewalReply()
            assertTrue(delivery.offerInput(packet(0, 2)))
            assertTrue(delivery.offerInput(packet(1, 2)))
            until { io.inputs().size == 9 }
            assertEquals(2, io.inputs().last().payload[8].toInt())
            assertEquals(0, sequence(io.inputs().last()))
            assertFalse(delivery.acknowledgeInput(packet(0).copyOfRange(0, 32), 7u, 99u))
            delivery.completeControl()
            until { io.inputs().size == 10 }
            assertEquals(1, sequence(io.inputs().last()))
            assertFalse(io.inputs().any { it.payload[8] == 1.toByte() && sequence(it) == 99 })
        } finally {
            delivery.close()
        }
        val credits = NativeInputCredits()
        assertTrue(credits.dispatch(ControlTLSFrame(ControlTLSFrame.Kind.INPUT, packet(0))))
        try {
            credits.dispatch(ControlTLSFrame(ControlTLSFrame.Kind.INPUT, packet(0, 2)))
            fail("unvalidated_grant_reset")
        } catch (_: ControlTLSRejected) {}
    }

    @Test
    fun udpAdvancedAcknowledgementIsValidButFutureWrongGrantAndRegressingReceiptsCannotUnlock() {
        val credits = NativeInputCredits()
        val header = packet(0).copyOfRange(0, 32)
        assertTrue(credits.dispatch(ControlTLSFrame(ControlTLSFrame.Kind.INPUT, packet(0))))
        assertTrue(credits.acknowledge(header, 100u, 100u))
        assertTrue(credits.dispatch(ControlTLSFrame(ControlTLSFrame.Kind.INPUT, packet(101))))
        assertFalse(credits.acknowledge(header, 102u, 101u))
        assertFalse(credits.acknowledge(header, 99u, 101u))
        assertFalse(credits.acknowledge(packet(0, 2).copyOfRange(0, 32), 101u, 101u))
        assertTrue(credits.acknowledge(header, 101u, 101u))
        assertFalse(credits.dispatch(ControlTLSFrame(ControlTLSFrame.Kind.INPUT, packet(100))))
    }

    @Test
    fun staleLatestAndPacketZeroCannotBeReplayedAfterCreditWait() {
        var clock = 0L
        val io = IO()
        val delivery = NativeTLSDelivery(io, true, { clock })
        try {
            fill(delivery, io)
            assertTrue(delivery.offerInput(packet(99)))
            clock = 350_000_000L
            assertTrue(delivery.offerControl(byteArrayOf(1), true))
            until { io.frames.size == 9 }
            assertTrue(delivery.acknowledgeInput(packet(0).copyOfRange(0, 32), 7u, 99u))
            delivery.completeControl()
            until { delivery.state == NativeTLSDelivery.State.CLOSED }
            assertEquals(8, io.inputs().size)
        } finally {
            delivery.close()
        }
        clock = 0
        val blocked = IO(true)
        val zero = NativeTLSDelivery(blocked, true, { clock })
        try {
            assertTrue(zero.offerControl(byteArrayOf(1)))
            assertTrue(blocked.entered.await(1, TimeUnit.SECONDS))
            assertTrue(zero.offerInput(packet(0)))
            clock = 350_000_000L
            blocked.release.countDown()
            until { zero.state == NativeTLSDelivery.State.CLOSED }
            assertTrue(blocked.inputs().isEmpty())
        } finally {
            zero.close()
        }
    }

    @Test
    fun closeDiscardsCreditBlockedLatestAndCannotBeResurrectedByAcknowledgement() {
        val io = IO()
        val delivery = NativeTLSDelivery(io, true, { 0L })
        fill(delivery, io)
        assertTrue(delivery.offerInput(packet(99)))
        delivery.close()
        assertFalse(delivery.acknowledgeInput(packet(0).copyOfRange(0, 32), 7u, 99u))
        assertFalse(delivery.offerInput(packet(100)))
        until { io.closed.get() }
        assertEquals(8, io.inputs().size)
    }

    @Test
    fun legacyV4DeliveryStillSendsBeyondEightInputsWithoutProgressAck() {
        val io = IO()
        val delivery = NativeControlDelivery(io, false)
        try {
            for (i in 0..19) {
                assertTrue(delivery.offerInput(packet(i)))
                until { io.inputs().size == i + 1 }
            }
            assertEquals(20, io.inputs().size)
        } finally {
            delivery.close()
        }
    }

    @Test
    fun activeWriteCannotCrossTheControlBarrierWithPendingOldInput() {
        val io = IO(true)
        val delivery = NativeTLSDelivery(io, true, { 0L })
        try {
            assertTrue(delivery.offerInput(packet(0)))
            assertTrue(io.entered.await(1, TimeUnit.SECONDS))
            assertTrue(delivery.offerInput(packet(1)))
            assertTrue(delivery.offerControl(byteArrayOf(1), true))
            io.release.countDown()
            until { io.frames.size == 2 }
            assertEquals(ControlTLSFrame.Kind.INPUT, io.frames[0].kind)
            assertEquals(ControlTLSFrame.Kind.CONTROL, io.frames[1].kind)
            assertTrue(delivery.acknowledgeInput(packet(0).copyOfRange(0, 32), 0u, 1u))
            assertEquals(1, io.inputs().size)
            delivery.completeControl()
            until { io.inputs().size == 2 }
            assertEquals(1, sequence(io.inputs().last()))
        } finally {
            delivery.close()
        }
    }

    @Test
    fun productionDeliveryUsesOwnersContinuousClockForQueuedFreshness() {
        var clock = 0L
        val io = IO(true)
        val delivery = NativeControlDelivery(io, true, { clock })
        try {
            delivery.send(ControlTLSFrame(ControlTLSFrame.Kind.CONTROL, byteArrayOf(1)))
            assertTrue(io.entered.await(1, TimeUnit.SECONDS))
            assertTrue(delivery.offerInput(packet(0)))
            clock = 350_000_000L
            io.release.countDown()
            until { delivery.terminalDiagnostic != null }
            assertTrue(io.inputs().isEmpty())
        } finally {
            delivery.close()
        }
    }
}
