package com.thumble.rewrite.input

import java.net.InetSocketAddress
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

class NativeTLSDeliveryTest {
    private fun until(condition: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(3)
        while (System.nanoTime() < deadline) {
            if (condition()) return
            Thread.sleep(1)
        }
        fail("native delivery condition timed out")
    }

    private class FakeIO(blockSend: Boolean = false) : NativeFrameIO {
        val sent = CopyOnWriteArrayList<ControlTLSFrame>()
        val inbound = LinkedBlockingQueue<ControlTLSFrame>()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(if (blockSend) 1 else 0)
        val closed = AtomicBoolean(false)

        override fun send(frame: ControlTLSFrame) {
            entered.countDown()
            check(release.await(3, TimeUnit.SECONDS))
            if (closed.get()) throw ControlTLSRejected()
            sent.add(frame)
        }

        override fun receive(): ControlTLSFrame {
            val frame = inbound.take()
            if (closed.get()) throw ControlTLSRejected()
            return frame
        }

        override fun close() {
            closed.set(true)
            release.countDown()
            inbound.offer(ControlTLSFrame(ControlTLSFrame.Kind.CONTROL, byteArrayOf(1)))
        }
    }

    @Test
    fun stalledNativeWriteCoalescesInputWithoutBlockingOffersOrReencrypting() {
        val io = FakeIO(true)
        NativeTLSDelivery { io }
            .use { delivery ->
                until { delivery.state == NativeTLSDelivery.State.READY }
                val first = ByteArray(108) { 1 }
                assertTrue(delivery.offerInput(first))
                first[0] = 99
                assertTrue(io.entered.await(3, TimeUnit.SECONDS))
                for (value in 2..100) assertTrue(
                    delivery.offerInput(ByteArray(108) { value.toByte() })
                )
                io.release.countDown()
                until { io.sent.size == 2 }
                assertArrayEquals(ByteArray(108) { 1 }, io.sent[0].payload)
                assertArrayEquals(ByteArray(108) { 100 }, io.sent[1].payload)
                assertEquals(2, io.sent.size)
            }
        until { io.closed.get() }
    }

    @Test
    fun controlQueueOverflowAndCloseAreTerminalAndDiscardPendingData() {
        val io = FakeIO(true)
        val delivery = NativeTLSDelivery { io }
        try {
            until { delivery.state == NativeTLSDelivery.State.READY }
            assertTrue(delivery.offerControl(byteArrayOf(1)))
            assertTrue(io.entered.await(3, TimeUnit.SECONDS))
            repeat(8) { assertTrue(delivery.offerControl(byteArrayOf(2))) }
            assertFalse(delivery.offerControl(byteArrayOf(3)))
            assertEquals(NativeTLSDelivery.State.CLOSED, delivery.state)
            assertFalse(delivery.offerInput(ByteArray(108)))
            assertNull(delivery.pollControl())
            until { io.closed.get() }
            assertTrue(io.sent.isEmpty())
        } finally {
            delivery.close()
        }
    }

    @Test
    fun inboundQueueOverflowAndWrongDirectionCloseWithoutUnboundedCallbacks() {
        for (wrongKind in listOf(false, true)) {
            val io = FakeIO()
            NativeTLSDelivery { io }
                .use { delivery ->
                    until { delivery.state == NativeTLSDelivery.State.READY }
                    if (wrongKind)
                        io.inbound.put(ControlTLSFrame(ControlTLSFrame.Kind.INPUT, ByteArray(108)))
                    else
                        repeat(9) {
                            io.inbound.put(
                                ControlTLSFrame(ControlTLSFrame.Kind.CONTROL, byteArrayOf(1))
                            )
                        }
                    until { delivery.state == NativeTLSDelivery.State.CLOSED }
                    assertNull(delivery.pollControl())
                }
        }
    }

    @Test
    fun closingDuringConnectCannotAdmitLateTransportOrReplayInput() {
        val connecting = CountDownLatch(1)
        val finish = CountDownLatch(1)
        val io = FakeIO()
        val delivery = NativeTLSDelivery {
            connecting.countDown()
            check(finish.await(3, TimeUnit.SECONDS))
            io
        }
        try {
            assertTrue(connecting.await(3, TimeUnit.SECONDS))
            assertFalse(delivery.offerInput(ByteArray(108)))
            delivery.close()
            finish.countDown()
            until { io.closed.get() }
            assertEquals(NativeTLSDelivery.State.CLOSED, delivery.state)
            assertFalse(delivery.offerInput(ByteArray(108)))
            assertTrue(io.sent.isEmpty())
        } finally {
            finish.countDown()
            delivery.close()
        }
    }

    @Test
    fun malformedFramesAndConnectionFailureFailClosed() {
        NativeTLSDelivery { throw ControlTLSRejected() }
            .use { delivery -> until { delivery.state == NativeTLSDelivery.State.CLOSED } }
        val io = FakeIO()
        NativeTLSDelivery { io }
            .use { delivery ->
                until { delivery.state == NativeTLSDelivery.State.READY }
                assertFalse(delivery.offerInput(ByteArray(109)))
                assertEquals(NativeTLSDelivery.State.CLOSED, delivery.state)
            }
    }

    @Test
    fun closeRetiresImmediatelyEvenWhenPlatformShutdownBlocks() {
        val closing = CountDownLatch(1)
        val finish = CountDownLatch(1)
        val returned = CountDownLatch(1)
        val io =
            object : NativeFrameIO {
                override fun send(frame: ControlTLSFrame) {}

                override fun receive(): ControlTLSFrame {
                    check(finish.await(3, TimeUnit.SECONDS))
                    throw ControlTLSRejected()
                }

                override fun close() {
                    closing.countDown()
                    check(finish.await(3, TimeUnit.SECONDS))
                }
            }
        val delivery = NativeTLSDelivery { io }
        try {
            until { delivery.state == NativeTLSDelivery.State.READY }
            val caller = Thread {
                delivery.close()
                returned.countDown()
            }
            caller.start()
            assertTrue("UI close waited for socket shutdown", returned.await(1, TimeUnit.SECONDS))
            assertTrue(closing.await(1, TimeUnit.SECONDS))
            assertEquals(NativeTLSDelivery.State.CLOSED, delivery.state)
            assertFalse(delivery.offerInput(ByteArray(108)))
        } finally {
            finish.countDown()
            delivery.close()
        }
    }

    @Test
    fun actualFullDuplexWorkerDeliversWhileNativeReaderWaits() {
        val path = System.getenv("THUMBLE_NATIVE_TLS_PROBE")
        assumeTrue("native TLS probe not configured", path != null)
        val process = ProcessBuilder(path).start()
        val watchdog =
            java.util.concurrent.ScheduledThreadPoolExecutor(1) { r ->
                Thread(r, "tls-worker-test-deadline").apply { isDaemon = true }
            }
        val timeout = watchdog.schedule({ process.destroyForcibly() }, 10, TimeUnit.SECONDS)
        try {
            val info = JSONObject(process.inputStream.bufferedReader().readLine())
            NativeTLSDelivery.connect(
                    InetSocketAddress("127.0.0.1", info.getInt("port")),
                    info.getString("pin"),
                )
                .use { delivery ->
                    until { delivery.state == NativeTLSDelivery.State.READY }
                    assertTrue(delivery.offerControl("native-duplex".toByteArray()))
                    var response: ControlTLSFrame? = null
                    until {
                        response = delivery.pollControl()
                        response != null
                    }
                    assertEquals(
                        "native-duplex",
                        requireNotNull(response).payload.toString(Charsets.UTF_8),
                    )
                    val fixture =
                        JSONObject(
                            requireNotNull(
                                    javaClass.classLoader?.getResourceAsStream(
                                        "input-packet-v1.json"
                                    )
                                )
                                .bufferedReader()
                                .use { it.readText() }
                        )
                    fun bytes(name: String) =
                        fixture
                            .getString(name)
                            .chunked(2)
                            .map { it.toInt(16).toByte() }
                            .toByteArray()
                    val generation = fixture.getString("generation")
                    val grant =
                        InputPacketGrant(
                            bytes("keyHex"),
                            bytes("sessionHex"),
                            bytes("noncePrefixHex"),
                            generation.toULong(),
                        )
                    val channel = InputPacketChannel(grant, send = delivery::offerInput)
                    val engine = InputEngine(channel::submit)
                    engine.activate(
                        ControlMap(
                            generation = generation,
                            revision = "1",
                            controls = listOf(ControlRegion("south", "south", 0.1, 0.1, 0.3, 0.3)),
                        )
                    )
                    fun verifyNativeState() {
                        response = null
                        until {
                            response = delivery.pollControl()
                            response != null
                        }
                        val admitted =
                            JSONObject(requireNotNull(response).payload.toString(Charsets.UTF_8))
                        assertTrue(admitted.getBoolean("ok"))
                        assertEquals(
                            GamepadReport.hex(engine.state),
                            admitted.getJSONObject("snapshot").getString("reportHex"),
                        )
                        assertFalse(admitted.getJSONObject("snapshot").getBoolean("inputEnabled"))
                    }
                    engine.connect(generation)
                    verifyNativeState()
                    assertTrue(engine.begin(1, generation, 0.2, 0.2))
                    verifyNativeState()
                    delivery.close()
                    engine.tick()
                    assertFalse(engine.connected)
                    assertTrue(engine.state.buttons.isEmpty())
                    assertEquals(ReleaseReason.transportFailure, engine.lastRelease)
                }
        } finally {
            timeout.cancel(false)
            watchdog.shutdownNow()
            process.destroy()
            assertTrue(process.waitFor(10, TimeUnit.SECONDS))
        }
    }
}
