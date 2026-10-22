package com.thumble.rewrite.input

import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class PhoneInputTest {
    private fun fixture(): JSONObject =
        javaClass.classLoader!!.getResourceAsStream("native-input-control-v4.json")!!.use {
            JSONObject(it.readBytes().toString(Charsets.UTF_8))
        }

    private fun map() =
        ControlMap(
            generation = "1",
            revision = "1",
            controls = listOf(ControlRegion("south", "south", 0.0, 0.0, 1.0, 1.0)),
        )

    private fun client(io: IO, now: () -> Long = { 1000 }, elapsed: () -> Long = { 1000 }) =
        PhoneControlClient(
            TrustedHostEndpoint("127.0.0.1", 1234, "11".repeat(32), "authority-a"),
            { io },
            { pin, _ ->
                PhoneCredential(
                    PhoneCredentialMetadata(pin, "phone-a", 1, 100000),
                    ByteArray(32) { 34 },
                )
            },
            now,
            controlVersion = 4,
            elapsed = elapsed,
        )

    private class IO(f: JSONObject) : NativeFrameIO {
        val queue = LinkedBlockingQueue<ControlTLSFrame>()
        val frames = CopyOnWriteArrayList<ControlTLSFrame>()
        val closed = CountDownLatch(1)
        var beforeReceive: (Int) -> Unit = {}
        var reads = 0
        var pauseGrant = false
        val paused = CountDownLatch(1)
        val resume = CountDownLatch(1)
        val status = f.getJSONObject("status")

        init {
            for (name in listOf("hello", "authenticated", "configuration", "grant")) queue.add(
                frame(f.getJSONObject(name))
            )
        }

        private fun frame(value: JSONObject) =
            ControlTLSFrame(
                ControlTLSFrame.Kind.CONTROL,
                value.toString().toByteArray(Charsets.UTF_8),
            )

        override fun send(frame: ControlTLSFrame) {
            if (closed.count == 0L) throw PhoneControlRejected()
            frames.add(frame)
            if (
                frame.kind == ControlTLSFrame.Kind.CONTROL &&
                    JSONObject(frame.payload.toString(Charsets.UTF_8)).getString("command") ==
                        "control-status"
            )
                queue.add(frame(status))
        }

        override fun receive(): ControlTLSFrame {
            reads++
            if (pauseGrant && reads == 4) {
                paused.countDown()
                check(resume.await(2, TimeUnit.SECONDS))
            }
            beforeReceive(reads)
            while (closed.count != 0L) queue.poll(10, TimeUnit.MILLISECONDS)?.let {
                return it
            }
            throw PhoneControlRejected()
        }

        override fun close() {
            closed.countDown()
        }

        fun inputs() = frames.filter { it.kind == ControlTLSFrame.Kind.INPUT }

        fun commands() =
            frames
                .filter { it.kind == ControlTLSFrame.Kind.CONTROL }
                .map { JSONObject(it.payload.toString(Charsets.UTF_8)).getString("command") }
    }

    private fun rejects(action: () -> Unit) {
        try {
            action()
            fail("input accepted")
        } catch (_: PhoneControlRejected) {}
    }

    private fun waitUntil(check: () -> Boolean) {
        val deadline = System.nanoTime() + 2_000_000_000L
        while (!check()) {
            assertTrue("timed out", System.nanoTime() < deadline)
            Thread.sleep(1)
        }
    }

    @Test
    fun authenticatesAndBindsOnInputThreadWithOnlySealedFrames() {
        val io = IO(fixture())
        val client = client(io)
        try {
            assertTrue(client.authenticate().inputSessionAvailable)
            val admission = client.prepareInput(map())
            val engine = admission.bind()
            rejects { admission.bind() }
            waitUntil { io.inputs().isNotEmpty() }
            val receiver =
                InputPacketReceiver(
                    InputPacketGrant(
                        ByteArray(32) { 0x44 },
                        ByteArray(16) { 0x33 },
                        ByteArray(4) { 0x55 },
                        1u,
                    )
                )
            assertEquals(GamepadReport.neutral(), receiver.open(io.inputs()[0].payload))
            assertTrue(engine.begin(1, "1", 0.2, 0.2))
            waitUntil { io.inputs().size >= 2 }
            assertEquals(
                listOf(com.thumble.rewrite.contracts.GamepadButtonV1.south),
                receiver.open(io.inputs()[1].payload).buttons,
            )
            engine.cancel(ReleaseReason.background)
            assertTrue(io.closed.await(2, TimeUnit.SECONDS))
            assertFalse(engine.connected)
            assertEquals(GamepadReport.neutral(), engine.state)
            assertEquals(
                listOf("hello", "authenticate", "input-configuration", "input-grant"),
                io.commands(),
            )
        } finally {
            client.close()
        }
    }

    @Test
    fun explicitVersion4RejectsDowngradeBeforeLoadingVault() {
        for (version in listOf(2, 3)) {
            val f = fixture()
            f.getJSONObject("hello").put("controlVersion", version)
            val io = IO(f)
            var loads = 0
            val client =
                PhoneControlClient(
                    TrustedHostEndpoint("127.0.0.1", 1234, "11".repeat(32), "authority-a"),
                    { io },
                    { _, _ ->
                        loads++
                        null
                    },
                    { 1000 },
                    controlVersion = 4,
                )
            rejects { client.authenticate() }
            assertEquals(0, loads)
            assertEquals(listOf("hello"), io.commands())
            assertTrue(io.closed.await(1, TimeUnit.SECONDS))
        }
    }

    @Test
    fun inactiveStaleForeignOrExtendedConfigurationNeverRequestsGrant() {
        for ((key, value) in
            listOf(
                "active" to false,
                "generation" to "2",
                "revision" to "0",
                "connectionId" to "cd".repeat(16),
                "inputEnabled" to true,
                "extra" to true,
            )) {
            val f = fixture()
            f.getJSONObject("configuration").put(key, value)
            val io = IO(f)
            val client = client(io)
            client.authenticate()
            rejects { client.prepareInput(map()) }
            assertTrue(io.closed.await(1, TimeUnit.SECONDS))
            assertTrue(io.inputs().isEmpty())
            assertFalse(io.commands().contains("input-grant"))
        }
    }

    @Test
    fun malformedOrCrossConnectionGrantsNeverReachInputThread() {
        for ((key, value) in
            listOf(
                "version" to 2,
                "command" to "other",
                "connectionId" to "cd".repeat(16),
                "generation" to "01",
                "revision" to "2",
                "sessionId" to "00".repeat(16),
                "key" to "AA".repeat(32),
                "noncePrefix" to "0",
                "lifetimeMs" to 99,
                "lifetimeMs" to 60001,
                "packetVersion" to 2,
                "packetBytes" to 107,
                "packetLimit" to 1048576,
                "transport" to "udp",
                "inputEnabled" to true,
                "extra" to "x",
            )) {
            val f = fixture()
            f.getJSONObject("grant").put(key, value)
            val io = IO(f)
            val client = client(io)
            client.authenticate()
            rejects { client.prepareInput(map()) }
            assertTrue(io.closed.await(1, TimeUnit.SECONDS))
            assertTrue(io.inputs().isEmpty())
        }
    }

    @Test
    fun latencyConsumesGrantLifetimeAndElapsedClockExpiresHeldInput() {
        for (delayed in listOf(true, false)) {
            var now = 1000L
            var elapsed = 1000L
            val io = IO(fixture())
            if (delayed) io.beforeReceive = { if (it == 4) now = 2000 }
            val client = client(io, { now }, { elapsed })
            client.authenticate()
            if (delayed) rejects { client.prepareInput(map()) }
            else {
                val engine = client.prepareInput(map()).bind()
                assertTrue(engine.begin(1, "1", 0.2, 0.2))
                elapsed += 1_000_000_000L
                engine.tick()
                assertFalse(engine.connected)
                assertEquals(GamepadReport.neutral(), engine.state)
            }
            assertTrue(io.closed.await(1, TimeUnit.SECONDS))
        }
    }

    @Test
    fun lateGrantCannotBindAfterConcurrentClose() {
        val io = IO(fixture())
        io.pauseGrant = true
        val client = client(io)
        client.authenticate()
        val result =
            java.util.concurrent.CompletableFuture.runAsync {
                rejects { client.prepareInput(map()) }
            }
        assertTrue(io.paused.await(1, TimeUnit.SECONDS))
        client.close()
        io.resume.countDown()
        result.get(2, TimeUnit.SECONDS)
        assertTrue(io.inputs().isEmpty())
        assertTrue(io.closed.await(1, TimeUnit.SECONDS))
    }

    @Test
    fun heartbeatRejectsAChangedConnectionAndInputThreadClearsHeldState() {
        val f = fixture()
        f.getJSONObject("grant").put("lifetimeMs", 5000)
        f.getJSONObject("status").put("connectionId", "cd".repeat(16))
        val io = IO(f)
        val client = client(io)
        client.authenticate()
        val engine = client.prepareInput(map()).bind()
        assertTrue(engine.begin(1, "1", 0.2, 0.2))
        assertTrue(io.closed.await(2, TimeUnit.SECONDS))
        engine.tick()
        assertFalse(engine.connected)
        assertEquals(GamepadReport.neutral(), engine.state)
    }

    @Test
    fun everyNativeLifecycleCancellationClosesGrantChannel() {
        for (reason in ReleaseReason.entries) {
            val io = IO(fixture())
            val client = client(io)
            client.authenticate()
            val engine = client.prepareInput(map()).bind()
            assertTrue(engine.begin(1, "1", 0.2, 0.2))
            engine.cancel(reason)
            assertEquals(reason, engine.lastRelease)
            assertTrue(io.closed.await(1, TimeUnit.SECONDS))
            assertFalse(engine.connected)
            assertEquals(GamepadReport.neutral(), engine.state)
        }
    }

    @Test
    fun actualNativeTouchCrossesTlsAndIpcWithFreshNeutralReconnect() {
        val path = System.getenv("THUMBLE_NATIVE_INPUT_PROBE")
        org.junit.Assume.assumeTrue(path != null)
        val process = ProcessBuilder(path!!).start()
        val reader = process.inputStream.bufferedReader()
        val reads = java.util.concurrent.Executors.newSingleThreadExecutor()
        var enrollment: PhoneEnrollmentClient? = null
        var control: PhoneControlClient? = null
        try {
            fun line() =
                JSONObject(
                    reads
                        .submit<String> { reader.readLine() ?: error("probe closed") }
                        .get(5, TimeUnit.SECONDS)
                )
            fun command(value: Int) {
                process.outputStream.write(value)
                process.outputStream.flush()
            }
            val offer = line()
            val invitation =
                EnrollmentInvitation(
                    "127.0.0.1",
                    offer.getInt("port"),
                    offer.getString("pin"),
                    offer.getString("authorityInstanceId"),
                    offer.getString("windowId"),
                    offer.getString("secret"),
                    offer.getLong("expiresAt"),
                )
            fun connect(): NativeFrameIO {
                val socket =
                    ControlTLSClient.connect(
                        java.net.InetSocketAddress(invitation.host, invitation.port),
                        invitation.certificatePin,
                    )
                return object : NativeFrameIO {
                    override fun send(frame: ControlTLSFrame) = socket.send(frame)

                    override fun receive() = socket.receive()

                    override fun close() = socket.close()
                }
            }
            var saved: PhoneCredential? = null
            enrollment =
                PhoneEnrollmentClient(
                    invitation,
                    ::connect,
                    { saved = it },
                    System::currentTimeMillis,
                )
            enrollment.enroll("phone-a", "Native touch witness")
            enrollment.close()
            val endpoint =
                TrustedHostEndpoint(
                    invitation.host,
                    invitation.port,
                    invitation.certificatePin,
                    invitation.authorityInstanceID,
                )
            for (generation in listOf("1", "2")) {
                val client =
                    PhoneControlClient(
                        endpoint,
                        ::connect,
                        { _, _ -> saved },
                        System::currentTimeMillis,
                        controlVersion = 4,
                    )
                control = client
                assertTrue(client.authenticate().inputSessionAvailable)
                command(97)
                assertEquals(generation, line().getString("generation"))
                val map =
                    ControlMap(
                        generation = generation,
                        revision = generation,
                        controls = map().controls,
                    )
                val admission = client.prepareInput(map)
                val engine = admission.bind()
                // The sink is bounded and asynchronous: witness actual receiver admission instead
                // of treating status as a flush.
                command(122)
                assertTrue(line().getBoolean("freshNeutral"))
                assertTrue(engine.begin(1, generation, 0.2, 0.2))
                if (generation == "1")
                    repeat(62) {
                        Thread.sleep(50)
                        engine.tick()
                    }
                command(104)
                val held = line()
                assertTrue(held.getBoolean("held"))
                assertFalse(held.getBoolean("inputEnabled"))
                if (generation == "1") engine.cancel(ReleaseReason.background)
                else {
                    client.close()
                    engine.tick()
                }
                command(110)
                val neutral = line()
                assertTrue(neutral.getBoolean("neutral"))
                assertEquals("native_input_released", neutral.getString("reason"))
                assertFalse(engine.connected)
                assertEquals(GamepadReport.neutral(), engine.state)
            }
            command(102)
            assertTrue(line().getBoolean("completed"))
            assertTrue(process.waitFor(5, TimeUnit.SECONDS))
            assertEquals(0, process.exitValue())
        } finally {
            enrollment?.close()
            control?.close()
            process.destroy()
            reader.close()
            reads.shutdownNow()
        }
    }

    @Test
    fun lateUiHandoffOrClockRollbackCannotExtendTheGrant() {
        for (lateBind in listOf(false, true)) {
            var now = 1000L
            var elapsed = 1000L
            val io = IO(fixture())
            val client = client(io, { now }, { elapsed })
            client.authenticate()
            val admission = client.prepareInput(map())
            if (lateBind) {
                now = 2000
                rejects { admission.bind() }
                assertTrue(io.inputs().isEmpty())
            } else {
                val feedback = mutableListOf<com.thumble.rewrite.contracts.GamepadStateV1>()
                val engine = admission.bind { feedback.add(it) }
                assertTrue(engine.begin(1, "1", 0.2, 0.2))
                elapsed = 999
                engine.tick()
                assertFalse(engine.connected)
                assertEquals(GamepadReport.neutral(), feedback.last())
            }
            assertTrue(io.closed.await(1, TimeUnit.SECONDS))
        }
    }
}
