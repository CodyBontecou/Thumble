package com.thumble.rewrite.input

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class PhoneRenewalTest {
    private class IO : NativeFrameIO {
        private val fixture =
            javaClass.classLoader!!.getResourceAsStream("native-input-control-v4.json")!!.use {
                JSONObject(it.readBytes().toString(Charsets.UTF_8))
            }
        private val replies = LinkedBlockingQueue<ControlTLSFrame>()
        val frames = CopyOnWriteArrayList<ControlTLSFrame>()
        val commands = CopyOnWriteArrayList<String>()
        val wall = AtomicLong(1000)
        val elapsed = AtomicLong(0)
        val renewals = AtomicInteger(0)
        val initialProgressCompleted = CountDownLatch(1)
        @Volatile var initialProgressWasUnacknowledged = false
        val closed = CountDownLatch(1)
        val paused = CountDownLatch(1)
        val resume = CountDownLatch(1)
        @Volatile var pauseRenewal = false
        @Volatile var nullProgress = false
        @Volatile var currentSession = "33".repeat(16)
        var changeReply: (JSONObject) -> JSONObject = { it }

        private fun reply(value: JSONObject) {
            replies.put(
                ControlTLSFrame(ControlTLSFrame.Kind.CONTROL, value.toString().toByteArray())
            )
        }

        private fun fixture(name: String) = JSONObject(fixture.getJSONObject(name).toString())

        fun inputs() = frames.filter { it.kind == ControlTLSFrame.Kind.INPUT }.map { it.payload }

        override fun send(frame: ControlTLSFrame) {
            if (closed.count == 0L) throw PhoneControlRejected()
            frames.add(frame)
            if (frame.kind == ControlTLSFrame.Kind.INPUT) return
            val value = JSONObject(frame.payload.toString(Charsets.UTF_8))
            val command = value.getString("command")
            commands.add(command)
            when (command) {
                "hello" -> reply(fixture("hello").put("controlVersion", 6))
                "authenticate" -> reply(fixture("authenticated").put("expiresAt", 61_000))
                "input-configuration" -> reply(fixture("configuration"))
                "input-grant" ->
                    reply(
                        fixture("grant")
                            .put("lifetimeMs", 60_000)
                            .put("transport", "udp+tls")
                            .put("udpPort", 43210)
                    )
                "input-renew" -> {
                    check(value.getString("sessionId") == currentSession)
                    val count = renewals.incrementAndGet()
                    val old = currentSession
                    currentSession = (0x60 + count).toString(16).repeat(16)
                    reply(
                        changeReply(
                            fixture("grant")
                                .put("lifetimeMs", 60_000)
                                .put("transport", "udp+tls")
                                .put("udpPort", 43210)
                                .put("command", "input-renewed")
                                .put("replacesSessionId", old)
                                .put("sessionId", currentSession)
                                .put("key", (0x70 + count).toString(16).repeat(32))
                                .put("noncePrefix", (0x80 + count).toString(16).repeat(4))
                                .put("authorizationExpiresAt", wall.get() + 60_000)
                        )
                    )
                }
                "input-status" -> {
                    check(value.getString("sessionId") == currentSession)
                    val sequence =
                        inputs().lastOrNull()?.let {
                            ByteBuffer.wrap(it, 32, 8).order(ByteOrder.LITTLE_ENDIAN).long
                        }
                    if (initialProgressCompleted.count == 1L)
                        initialProgressWasUnacknowledged = sequence == null
                    reply(
                        JSONObject()
                            .put("version", 1)
                            .put("command", "input-status")
                            .put("connectionId", "ab".repeat(16))
                            .put("sessionId", currentSession)
                            .put("active", true)
                            .put("generation", "1")
                            .put("revision", "1")
                            .put(
                                "lastAcceptedSequence",
                                if (nullProgress || sequence == null) JSONObject.NULL
                                else sequence.toString(),
                            )
                            .put("inputEnabled", false)
                    )
                    initialProgressCompleted.countDown()
                }
                else -> throw PhoneControlRejected()
            }
        }

        override fun receive(): ControlTLSFrame {
            while (closed.count != 0L) {
                val frame = replies.poll(10, TimeUnit.MILLISECONDS) ?: continue
                if (
                    pauseRenewal &&
                        JSONObject(frame.payload.toString(Charsets.UTF_8)).getString("command") ==
                            "input-renewed"
                ) {
                    paused.countDown()
                    check(resume.await(2, TimeUnit.SECONDS))
                }
                if (closed.count == 0L) throw PhoneControlRejected()
                return frame
            }
            throw PhoneControlRejected()
        }

        override fun close() {
            closed.countDown()
            resume.countDown()
        }
    }

    private fun client(io: IO) =
        PhoneControlClient(
            TrustedHostEndpoint("127.0.0.1", 1234, "11".repeat(32), "authority-a"),
            { io },
            { pin, _ ->
                PhoneCredential(
                    PhoneCredentialMetadata(pin, "phone-a", 1, 180_000),
                    ByteArray(32) { 34 },
                )
            },
            io.wall::get,
            controlVersion = 6,
            elapsed = io.elapsed::get,
            datagramFactory = { _, _ -> throw PhoneControlRejected() },
        )

    private fun map() =
        ControlMap(
            generation = "1",
            revision = "1",
            controls =
                listOf(
                    ControlRegion("south", "south", 0.0, 0.0, 0.4, 1.0),
                    ControlRegion("trigger", "leftTrigger", 0.5, 0.0, 0.4, 1.0),
                ),
        )

    private fun until(tick: () -> Unit = {}, condition: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(3)
        while (System.nanoTime() < deadline) {
            if (condition()) return
            tick()
            Thread.sleep(5)
        }
        assertTrue("automatic renewal missed its native handoff barrier", condition())
    }

    private fun newPackets(io: IO, count: Int) =
        io.inputs().filter {
            it.sliceArray(8..23).all { byte -> byte == (0x60 + count).toByte() }
        }

    @Test
    fun automaticRenewalPreservesTouchesThroughTwoFreshCounters() {
        val io = IO()
        client(io).use { client ->
            client.authenticate()
            val engine = client.prepareInput(map()).bind()
            assertTrue(engine.begin(1L, "1", 0.1, 0.1))
            assertTrue(engine.begin(2L, "1", 0.6, 0.1))
            val held = engine.state
            until {
                io.inputs().any {
                    ByteBuffer.wrap(it, 32, 8).order(ByteOrder.LITTLE_ENDIAN).long == 2L
                }
            }
            for (count in 1..2) {
                io.wall.set(1000L + count * 35_000L)
                io.elapsed.set(TimeUnit.MILLISECONDS.toNanos(count * 35_000L))
                until({ engine.tick() }) {
                    io.renewals.get() == count &&
                        newPackets(io, count).isNotEmpty() &&
                        io.commands.lastOrNull() == "input-status"
                }
                assertTrue(engine.connected)
                assertEquals(held.buttons, engine.state.buttons)
                assertEquals(1.0, engine.state.leftTrigger, 0.0)
                val first = newPackets(io, count).first()
                assertTrue(first.sliceArray(32..39).all { it == 0.toByte() })
                val grant =
                    InputPacketGrant(
                        ByteArray(32) { (0x70 + count).toByte() },
                        ByteArray(16) { (0x60 + count).toByte() },
                        ByteArray(4) { (0x80 + count).toByte() },
                        1uL,
                    )
                val decoded = InputPacketReceiver(grant).open(first)
                assertEquals(held.buttons, decoded.buttons)
                assertEquals(1.0, decoded.leftTrigger, 0.0)
            }
            engine.end(1L, "1")
            assertTrue(engine.connected && engine.state.buttons.isEmpty())
            assertEquals(1.0, engine.state.leftTrigger, 0.0)
            engine.end(2L, "1")
            assertEquals(
                GamepadReport.hex(GamepadReport.neutral()),
                GamepadReport.hex(engine.state),
            )
            assertEquals(1, io.commands.count { it == "authenticate" })
        }
    }

    @Test
    fun lateOrCancelledRenewalCannotReviveTheOldInteraction() {
        for (fault in
            listOf(
                "wall-expiry",
                "continuous-expiry",
                "wall-rollback",
                "continuous-rollback",
                "background",
            )) {
            val io = IO().also { it.pauseRenewal = true }
            client(io).use { client ->
                client.authenticate()
                val engine = client.prepareInput(map()).bind()
                assertTrue(engine.begin(1L, "1", 0.1, 0.1))
                // Drain the emitted held sample before a synthetic 35-second clock jump.
                // Otherwise this exercises stale queued-state rejection, not late renewal.
                until {
                    io.inputs().any {
                        ByteBuffer.wrap(it, 32, 8).order(ByteOrder.LITTLE_ENDIAN).long == 1L
                    }
                }
                io.wall.set(36_000)
                io.elapsed.set(TimeUnit.MILLISECONDS.toNanos(35_000))
                assertTrue(io.paused.await(2, TimeUnit.SECONDS))
                engine.tick()
                when (fault) {
                    "wall-expiry" -> io.wall.set(61_000)
                    "continuous-expiry" -> io.elapsed.set(TimeUnit.MILLISECONDS.toNanos(60_000))
                    "wall-rollback" -> io.wall.set(35_999)
                    "continuous-rollback" -> io.elapsed.set(TimeUnit.MILLISECONDS.toNanos(34_999))
                    else -> engine.cancel(ReleaseReason.background)
                }
                io.resume.countDown()
                assertTrue(io.closed.await(2, TimeUnit.SECONDS))
                engine.tick()
                assertFalse(engine.connected)
                assertTrue(engine.state.buttons.isEmpty())
                assertTrue(newPackets(io, 1).isEmpty())
            }
        }
    }

    @Test
    fun invalidScopeReusedKeyAndUnacknowledgedCommitAreTerminal() {
        for (fault in listOf("port", "old-session", "key-reuse", "no-ack")) {
            val io = IO()
            io.changeReply = {
                when (fault) {
                    "port" -> it.put("udpPort", 43211)
                    "old-session" -> it.put("replacesSessionId", "99".repeat(16))
                    "key-reuse" -> it.put("key", "44".repeat(32))
                    else -> it
                }
            }
            io.nullProgress = fault == "no-ack"
            client(io).use { client ->
                client.authenticate()
                val engine = client.prepareInput(map()).bind()
                assertTrue(engine.begin(1L, "1", 0.1, 0.1))
                // Drain the emitted held sample before a synthetic 35-second clock jump.
                // Otherwise this exercises stale queued-state rejection, not late renewal.
                until {
                    io.inputs().any {
                        ByteBuffer.wrap(it, 32, 8).order(ByteOrder.LITTLE_ENDIAN).long == 1L
                    }
                }
                io.wall.set(36_000)
                io.elapsed.set(TimeUnit.MILLISECONDS.toNanos(35_000))
                until({ engine.tick() }) { io.closed.count == 0L }
                engine.tick()
                assertFalse(engine.connected)
                assertTrue(engine.state.buttons.isEmpty())
            }
        }
    }

    @Test
    fun initialProgressBeforePacketZeroKeepsThePreparedFixtureAvailable() {
        val io = IO()
        client(io).use { client ->
            client.authenticate()
            val admission = client.prepareInput(map())
            // The real native status admits no accepted sequence before packet zero.
            assertTrue(io.initialProgressCompleted.await(2, TimeUnit.SECONDS))
            assertTrue(io.initialProgressWasUnacknowledged)
            assertTrue(io.inputs().isEmpty())
            val engine = admission.bind()
            until { io.inputs().isNotEmpty() }
            assertTrue(engine.connected)
            engine.cancel(ReleaseReason.background)
        }
    }

    @Test
    fun preparedRenewalCannotWaitForTheUiPastItsCommitBudget() {
        val io = IO()
        client(io).use { client ->
            client.authenticate()
            val admission = client.prepareInput(map())
            // Force an initial progress reply before binding, then observe packet-zero
            // dispatch below; this does not prove that the reply has been validated.
            assertTrue(io.initialProgressCompleted.await(2, TimeUnit.SECONDS))
            assertTrue(io.initialProgressWasUnacknowledged)
            val engine = admission.bind()
            // Raw IO dispatch proves the writer already checked packet-zero eligibility
            // before this synthetic jump; queued input still expires.
            until { io.inputs().isNotEmpty() }
            io.wall.set(36_000)
            io.elapsed.set(TimeUnit.MILLISECONDS.toNanos(35_000))
            until { io.renewals.get() == 1 }
            Thread.sleep(20) // Permit the worker to decode; no UI sample is emitted.
            io.elapsed.set(TimeUnit.MILLISECONDS.toNanos(37_000))
            assertTrue(io.closed.await(2, TimeUnit.SECONDS))
            engine.tick()
            assertFalse(engine.connected)
            assertTrue(newPackets(io, 1).isEmpty())
        }
    }
}
