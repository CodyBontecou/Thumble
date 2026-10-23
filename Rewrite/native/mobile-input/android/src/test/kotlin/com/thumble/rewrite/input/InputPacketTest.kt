package com.thumble.rewrite.input

import com.thumble.rewrite.contracts.GamepadButtonV1
import com.thumble.rewrite.contracts.GamepadStateV1
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class InputPacketTest {
    private fun fixture() =
        JSONObject(
            requireNotNull(javaClass.classLoader?.getResourceAsStream("input-packet-v1.json"))
                .bufferedReader()
                .use { it.readText() }
        )

    private fun bytes(hex: String) = hex.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    private fun grant(f: JSONObject, key: ByteArray = bytes(f.getString("keyHex"))) =
        InputPacketGrant(
            key,
            bytes(f.getString("sessionHex")),
            bytes(f.getString("noncePrefixHex")),
            f.getString("generation").toULong(),
        )

    private fun state(o: JSONObject): GamepadStateV1 {
        val b = o.getJSONArray("buttons")
        return GamepadStateV1(
            (0 until b.length()).map { GamepadButtonV1.valueOf(b.getString(it)) },
            o.getDouble("leftStickX"),
            o.getDouble("leftStickY"),
            o.getDouble("rightStickX"),
            o.getDouble("rightStickY"),
            o.getDouble("leftTrigger"),
            o.getDouble("rightTrigger"),
        )
    }

    private fun rejected(run: () -> Unit) {
        try {
            run()
            fail("packet_was_accepted")
        } catch (_: PacketRejected) {}
    }

    @Test
    fun sharedEncryptedPacketsMatchAndDecode() {
        val f = fixture()
        val vectors = f.getJSONArray("vectors")
        assertEquals(33, vectors.length())
        assertEquals(108, f.getInt("packetBytes"))
        assertEquals(InputPacketSender.LIMIT, f.getLong("packetLimit"))
        val sender = InputPacketSender(grant(f))
        val receiver = InputPacketReceiver(grant(f))
        for (i in 0 until vectors.length()) {
            val v = vectors.getJSONObject(i)
            val expected = bytes(v.getString("packetHex"))
            assertArrayEquals(
                bytes(v.getString("payloadHex")),
                InputPacketState.encode(state(v.getJSONObject("state"))),
            )
            assertArrayEquals(expected, sender.seal(state(v.getJSONObject("state"))))
            val decoded = receiver.open(expected)
            assertArrayEquals(bytes(v.getString("payloadHex")), InputPacketState.encode(decoded))
            assertEquals(v.getString("reportHex"), GamepadReport.hex(decoded))
        }
    }

    @Test
    fun tamperingAndMalformedPayloadsDoNotAdvanceReplayState() {
        val f = fixture()
        val original = bytes(f.getJSONArray("vectors").getJSONObject(0).getString("packetHex"))
        val receiver = InputPacketReceiver(grant(f))
        for (i in original.indices) {
            val mutated = original.copyOf()
            mutated[i] = (mutated[i].toInt() xor 1).toByte()
            rejected { receiver.open(mutated) }
        }
        val invalid = f.getJSONArray("invalidAuthenticated")
        for (i in 0 until invalid.length()) rejected {
            receiver.open(bytes(invalid.getJSONObject(i).getString("packetHex")))
        }
        rejected { receiver.open(original + byteArrayOf(0)) }
        rejected { receiver.open(original.copyOf(107)) }
        rejected { receiver.open(bytes(f.getString("overLimitPacketHex"))) }
        assertTrue(GamepadReport.valid(receiver.open(original)))
    }

    @Test
    fun replayReorderingWrongKeysAndClose() {
        val f = fixture()
        val v = f.getJSONArray("vectors")
        val receiver = InputPacketReceiver(grant(f))
        receiver.open(bytes(v.getJSONObject(2).getString("packetHex")))
        for (i in 0..2) rejected { receiver.open(bytes(v.getJSONObject(i).getString("packetHex"))) }
        receiver.open(bytes(v.getJSONObject(3).getString("packetHex")))
        receiver.open(bytes(f.getString("maximumSequencePacketHex")))
        rejected { receiver.open(bytes(v.getJSONObject(4).getString("packetHex"))) }
        receiver.close()
        receiver.close()
        rejected { receiver.open(bytes(f.getString("maximumSequencePacketHex"))) }
        val wrong = InputPacketReceiver(grant(f, ByteArray(32) { -1 }))
        rejected { wrong.open(bytes(v.getJSONObject(0).getString("packetHex"))) }
    }

    @Test
    fun senderBudgetAndGrantArraysHaveIndependentOwnership() {
        val f = fixture()
        val key = bytes(f.getString("keyHex"))
        val session = bytes(f.getString("sessionHex"))
        val prefix = bytes(f.getString("noncePrefixHex"))
        val g = InputPacketGrant(key, session, prefix, f.getString("generation").toULong())
        key.fill(0)
        session.fill(0)
        prefix.fill(0)
        val sender = InputPacketSender(g, 2)
        assertArrayEquals(
            bytes(f.getJSONArray("vectors").getJSONObject(0).getString("packetHex")),
            sender.seal(GamepadReport.neutral()),
        )
        sender.seal(GamepadReport.neutral())
        rejected { sender.seal(GamepadReport.neutral()) }
        rejected { sender.seal(GamepadReport.neutral()) }
        val closed = InputPacketSender(grant(f))
        closed.close()
        rejected { closed.seal(GamepadReport.neutral()) }
        for (limit in listOf(0L, InputPacketSender.LIMIT + 1)) rejected {
            InputPacketSender(grant(f), limit)
        }
        rejected { InputPacketGrant(ByteArray(31), ByteArray(16) { 1 }, ByteArray(4), 1uL) }
        rejected { InputPacketGrant(ByteArray(32), ByteArray(16), ByteArray(4), 1uL) }
        rejected { InputPacketGrant(ByteArray(32), ByteArray(16) { 1 }, ByteArray(3), 1uL) }
        rejected { InputPacketGrant(ByteArray(32), ByteArray(16) { 1 }, ByteArray(4), 0uL) }
    }

    @Test
    fun wrongThreadCannotUseSenderOrReceiver() {
        val f = fixture()
        val sender = InputPacketSender(grant(f))
        val receiver = InputPacketReceiver(grant(f))
        val failures = AtomicReference<List<Throwable>>()
        val thread = Thread {
            failures.set(
                listOfNotNull(
                    runCatching { sender.seal(GamepadReport.neutral()) }.exceptionOrNull(),
                    runCatching { receiver.close() }.exceptionOrNull(),
                )
            )
        }
        thread.start()
        thread.join()
        assertEquals(2, failures.get().size)
        assertTrue(failures.get().all { it is IllegalStateException })
        assertEquals(108, sender.seal(GamepadReport.neutral()).size)
    }
}

class InputPacketChannelTest {
    private fun grant() =
        InputPacketGrant(ByteArray(32) { 5 }, ByteArray(16) { 7 }, ByteArray(4) { 9 }, 1uL)

    @Test
    fun nativeTouchEngineEncryptionAndTransportLossRelease() {
        val packets = mutableListOf<ByteArray>()
        var accepting = true
        val channel =
            InputPacketChannel(grant()) { p ->
                if (accepting) packets.add(p)
                accepting
            }
        val engine = InputEngine(channel::submit)
        engine.activate(
            ControlMap(
                generation = "1",
                revision = "1",
                controls = listOf(ControlRegion("south", "south", 0.1, 0.1, 0.3, 0.3)),
            )
        )
        engine.connect("1")
        assertTrue(engine.begin(1L, "1", 0.2, 0.2))
        val receiver = InputPacketReceiver(grant())
        assertTrue(receiver.open(packets[0]).buttons.isEmpty())
        assertEquals(listOf(GamepadButtonV1.south), receiver.open(packets[1]).buttons)
        accepting = false
        engine.tick()
        assertFalse(engine.connected)
        assertTrue(engine.state.buttons.isEmpty())
        assertEquals(ReleaseReason.transportFailure, engine.lastRelease)
        val count = packets.size
        accepting = true
        engine.tick()
        assertEquals(count, packets.size)
        assertFalse(channel.submit(InputSample("1", "3", GamepadReport.neutral())))
    }

    @Test
    fun generationSequenceReentrancyAndThrowingSinkRetireChannel() {
        var sends = 0
        val wrong =
            InputPacketChannel(grant()) {
                sends++
                true
            }
        assertFalse(wrong.submit(InputSample("2", "0", GamepadReport.neutral())))
        assertFalse(wrong.submit(InputSample("1", "0", GamepadReport.neutral())))
        val gap =
            InputPacketChannel(grant()) {
                sends++
                true
            }
        assertFalse(gap.submit(InputSample("1", "1", GamepadReport.neutral())))
        assertEquals(0, sends)
        lateinit var reentrant: InputPacketChannel
        reentrant =
            InputPacketChannel(grant()) {
                assertFalse(reentrant.submit(InputSample("1", "1", GamepadReport.neutral())))
                true
            }
        assertFalse(reentrant.submit(InputSample("1", "0", GamepadReport.neutral())))
        val broken = InputPacketChannel(grant()) { throw IllegalStateException("sink_failed") }
        assertFalse(broken.submit(InputSample("1", "0", GamepadReport.neutral())))
        assertFalse(broken.submit(InputSample("1", "1", GamepadReport.neutral())))
    }

    @Test
    fun freshKeysContinueHeldTouchesWithoutResettingEngineSequence() {
        val packets = mutableListOf<ByteArray>()
        var channel =
            InputPacketChannel(grant()) {
                packets.add(it)
                true
            }
        val engine = InputEngine({ channel.submit(it) })
        engine.activate(
            ControlMap(
                generation = "1",
                revision = "1",
                controls = listOf(ControlRegion("south", "south", 0.1, 0.1, 0.3, 0.3)),
            )
        )
        engine.connect("1")
        assertTrue(engine.begin(1L, "1", 0.2, 0.2))
        val priorRelease = engine.lastRelease
        for (byte in listOf(31.toByte(), 32.toByte())) {
            val next =
                InputPacketGrant(
                    ByteArray(32) { byte },
                    ByteArray(16) { byte },
                    ByteArray(4) { byte },
                    1uL,
                )
            val old = channel
            channel =
                old.continued(next) {
                    packets.add(it)
                    true
                }
            assertFalse(old.submit(InputSample("1", "2", GamepadReport.neutral())))
            val before = packets.size
            engine.tick()
            assertTrue(engine.connected)
            assertEquals(priorRelease, engine.lastRelease)
            assertEquals(listOf(GamepadButtonV1.south), engine.state.buttons)
            assertEquals(before + 1, packets.size)
            assertTrue(packets.last().sliceArray(32..39).all { it == 0.toByte() })
            assertEquals(
                listOf(GamepadButtonV1.south),
                InputPacketReceiver(next).open(packets.last()).buttons,
            )
        }
        engine.end(1L, "1")
        assertTrue(engine.connected)
        assertTrue(engine.state.buttons.isEmpty())
        assertEquals(1.toByte(), packets.last()[32])
    }

    @Test
    fun continuationCannotReuseMaterialReviveClosedChannelsOrHideSendFailure() {
        fun reject(block: () -> Unit) {
            try {
                block()
                fail("invalid continuation accepted")
            } catch (_: PacketRejected) {}
        }
        for (next in
            listOf(
                grant(),
                InputPacketGrant(
                    ByteArray(32) { 57 },
                    ByteArray(16) { 7 },
                    ByteArray(4) { 9 },
                    1uL,
                ),
                InputPacketGrant(
                    ByteArray(32) { 5 },
                    ByteArray(16) { 91 },
                    ByteArray(4) { 91 },
                    1uL,
                ),
            )) {
            val channel = InputPacketChannel(grant()) { true }
            assertTrue(channel.submit(InputSample("1", "0", GamepadReport.neutral())))
            reject { channel.continued(next) { true } }
            assertFalse(channel.submit(InputSample("1", "1", GamepadReport.neutral())))
        }
        val fresh =
            InputPacketGrant(ByteArray(32) { 73 }, ByteArray(16) { 73 }, ByteArray(4) { 73 }, 1uL)
        val closed = InputPacketChannel(grant()) { true }
        closed.close()
        reject { closed.continued(fresh) { true } }
        var channel = InputPacketChannel(grant()) { true }
        val engine = InputEngine({ channel.submit(it) })
        engine.activate(
            ControlMap(
                generation = "1",
                revision = "1",
                controls = listOf(ControlRegion("south", "south", 0.1, 0.1, 0.3, 0.3)),
            )
        )
        engine.connect("1")
        channel = channel.continued(fresh) { false }
        engine.tick()
        assertFalse(engine.connected)
        assertEquals(ReleaseReason.transportFailure, engine.lastRelease)
        reject { channel.continued(grant()) { true } }
    }
}
