package com.thumble.rewrite.input

import org.junit.Assert.*
import org.junit.Test

class NativeInputRouteTest {
    private fun grant(session: Byte = 3) =
        InputPacketGrant(ByteArray(32) { 4 }, ByteArray(16) { session }, ByteArray(4) { 5 }, 1uL)

    private fun progress(sequence: ULong?, active: Boolean = true): PhoneInputProgress {
        val value =
            mapOf(
                "version" to EnrollmentJSON.Value.Integer(1),
                "command" to EnrollmentJSON.Value.Text("input-status"),
                "connectionId" to EnrollmentJSON.Value.Text("connection"),
                "sessionId" to EnrollmentJSON.Value.Text("session"),
                "generation" to EnrollmentJSON.Value.Text("1"),
                "revision" to EnrollmentJSON.Value.Text("1"),
                "active" to EnrollmentJSON.Value.BooleanValue(active),
                "inputEnabled" to EnrollmentJSON.Value.BooleanValue(false),
                "lastAcceptedSequence" to
                    (sequence?.let { EnrollmentJSON.Value.Text(it.toString()) }
                        ?: EnrollmentJSON.Value.Null),
            )
        return PhoneInputProgress(
            value,
            "connection",
            "session",
            ControlMap(generation = "1", revision = "1", controls = emptyList()),
            sequence,
            null,
        )
    }

    @Test
    fun acknowledgedDatagramsKeepOneReliableNeutral() {
        var time = 0L
        val tls = mutableListOf<ByteArray>()
        val udp = mutableListOf<ByteArray>()
        val route =
            NativeInputRoute(
                { time },
                {
                    udp.add(it)
                    true
                },
                {
                    tls.add(it)
                    true
                },
            )
        val sender = InputPacketSender(grant())
        assertTrue(route.offer(sender.seal(GamepadReport.neutral())))
        assertTrue(route.observe(progress(0uL)))
        for (sequence in 1..60) {
            time += 50
            assertTrue(route.offer(sender.seal(GamepadReport.neutral())))
            assertTrue(route.observe(progress(sequence.toULong())))
        }
        assertEquals(1, tls.size)
        assertEquals(60, udp.size)
        assertFalse(route.reliable)
        assertFalse(route.closed)
    }

    @Test
    fun blackholeFallbackKeepsTheSameCounterAndCiphertext() {
        var time = 0L
        val tls = mutableListOf<ByteArray>()
        val udp = mutableListOf<ByteArray>()
        val route =
            NativeInputRoute(
                { time },
                {
                    udp.add(it)
                    true
                },
                {
                    tls.add(it)
                    true
                },
            )
        val sender = InputPacketSender(grant())
        val packets = (0..4).map { sender.seal(GamepadReport.neutral()) }
        assertTrue(route.offer(packets[0]))
        assertTrue(route.observe(progress(0uL)))
        time = 20
        assertTrue(route.offer(packets[1]))
        time = 169
        assertTrue(route.offer(packets[2]))
        assertFalse(route.reliable)
        time = 170
        assertTrue(route.offer(packets[3]))
        assertTrue(route.reliable)
        assertTrue(route.observe(progress(3uL)))
        time = 171
        assertTrue(route.offer(packets[4]))
        assertTrue(route.reliable)
        assertEquals(listOf(packets[0], packets[3], packets[4]), tls)
        assertEquals(listOf(packets[1], packets[2]), udp)
        val receiver = InputPacketReceiver(grant())
        tls.forEach { assertEquals(GamepadReport.neutral(), receiver.open(it)) }
    }

    @Test
    fun failedUdpUsesSameCiphertextAndFailedTlsClosesPermanently() {
        val tls = mutableListOf<ByteArray>()
        val udp = mutableListOf<ByteArray>()
        val route =
            NativeInputRoute(
                { 0 },
                {
                    udp.add(it)
                    false
                },
                {
                    tls.add(it)
                    true
                },
            )
        val sender = InputPacketSender(grant())
        assertTrue(route.offer(sender.seal(GamepadReport.neutral())))
        val second = sender.seal(GamepadReport.neutral())
        assertTrue(route.offer(second))
        assertTrue(route.reliable)
        assertSame(second, udp.single())
        assertSame(second, tls.last())
        var attempts = 0
        val failed =
            NativeInputRoute(
                { 0 },
                { true },
                {
                    attempts++
                    false
                },
            )
        val first = InputPacketSender(grant()).seal(GamepadReport.neutral())
        assertFalse(failed.offer(first))
        assertFalse(failed.offer(first))
        assertTrue(failed.closed)
        assertEquals(1, attempts)
    }

    @Test
    fun rollbackForeignSourceAndInactiveProgressAreTerminal() {
        var time = 10L
        val route = NativeInputRoute({ time }, { true }, { true })
        val sender = InputPacketSender(grant())
        assertTrue(route.offer(sender.seal(GamepadReport.neutral())))
        time = 9
        assertFalse(route.offer(sender.seal(GamepadReport.neutral())))
        assertTrue(route.closed)
        val other = NativeInputRoute({ 0 }, { true }, { true })
        assertTrue(other.offer(InputPacketSender(grant()).seal(GamepadReport.neutral())))
        val foreign = InputPacketSender(grant(9))
        foreign.seal(GamepadReport.neutral())
        assertFalse(other.offer(foreign.seal(GamepadReport.neutral())))
        assertTrue(other.closed)
        val inactive = NativeInputRoute({ 0 }, { true }, { true })
        assertFalse(inactive.observe(progress(null, false)))
        assertTrue(inactive.closed)
    }

    @Test
    fun partialAckCannotExtendTheAgeOfStillUnacknowledgedInput() {
        var time = 0L
        val route = NativeInputRoute({ time }, { true }, { true })
        val sender = InputPacketSender(grant())
        assertTrue(route.offer(sender.seal(GamepadReport.neutral())))
        assertTrue(route.observe(progress(0uL)))
        time = 20
        assertTrue(route.offer(sender.seal(GamepadReport.neutral())))
        time = 40
        assertTrue(route.offer(sender.seal(GamepadReport.neutral())))
        time = 160
        assertTrue(route.observe(progress(1uL)))
        time = 189
        assertTrue(route.offer(sender.seal(GamepadReport.neutral())))
        assertFalse(route.reliable)
        time = 190
        assertTrue(route.offer(sender.seal(GamepadReport.neutral())))
        assertTrue(route.reliable)
    }

    @Test
    fun outstandingProgressMetadataHasAFixedBound() {
        val route = NativeInputRoute({ 0 }, { true }, { true })
        val sender = InputPacketSender(grant())
        repeat(64) { assertTrue(route.offer(sender.seal(GamepadReport.neutral()))) }
        assertFalse(route.reliable)
        assertTrue(route.offer(sender.seal(GamepadReport.neutral())))
        assertTrue(route.reliable)
    }

    @Test
    fun freshGrantRouteRetainsKnownFallbackWithFreshProgress() {
        val old = NativeInputRoute({ 0 }, { false }, { true })
        val sender = InputPacketSender(grant())
        assertTrue(old.offer(sender.seal(GamepadReport.neutral())))
        assertTrue(old.offer(sender.seal(GamepadReport.neutral())))
        assertTrue(old.observe(progress(1uL)))
        assertTrue(old.reliable)
        var udp = 0
        val tls = mutableListOf<ByteArray>()
        val successor =
            NativeInputRoute(
                { 0 },
                {
                    udp++
                    true
                },
                {
                    tls.add(it)
                    true
                },
                initiallyReliable = old.reliable,
            )
        old.close()
        val fresh =
            InputPacketSender(
                InputPacketGrant(ByteArray(32) { 6 }, ByteArray(16) { 6 }, ByteArray(4) { 6 }, 1uL)
            )
        assertNull(successor.acknowledged)
        assertNull(successor.lastOffered)
        assertTrue(successor.offer(fresh.seal(GamepadReport.neutral())))
        assertTrue(successor.offer(fresh.seal(GamepadReport.neutral())))
        assertEquals(2, tls.size)
        assertEquals(0, udp)
        assertTrue(successor.reliable)
        assertTrue(successor.observe(progress(0uL)))
    }
}
