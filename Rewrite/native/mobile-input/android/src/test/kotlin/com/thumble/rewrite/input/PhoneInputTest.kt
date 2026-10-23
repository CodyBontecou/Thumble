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

    private fun client(
        io: IO,
        now: () -> Long = { 1000 },
        elapsed: () -> Long = { 1000 },
        version: Int = 4,
        datagramFactory: (String, Int) -> NativeDatagramIO = { host, port ->
            NativeDatagramDelivery(java.net.InetSocketAddress(host, port))
        },
    ) =
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
            controlVersion = version,
            elapsed = elapsed,
            datagramFactory = datagramFactory,
        )

    private class IO(f: JSONObject) : NativeFrameIO {
        val queue = LinkedBlockingQueue<ControlTLSFrame>()
        val frames = CopyOnWriteArrayList<ControlTLSFrame>()
        val closed = CountDownLatch(1)
        var beforeReceive: (Int) -> Unit = {}
        var beforeInputSend: () -> Unit = {}
        var reads = 0
        var pauseGrant = false
        var pauseAt = 4
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
            if (frame.kind == ControlTLSFrame.Kind.INPUT) beforeInputSend()
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
            if (pauseGrant && reads == pauseAt) {
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

        fun replies(vararg values: JSONObject) {
            queue.clear()
            values.forEach { queue.add(frame(it)) }
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

    private fun version5Fixture(): JSONObject =
        fixture().apply {
            getJSONObject("hello").put("controlVersion", 5)
            getJSONObject("grant").put("transport", "udp+tls").put("udpPort", 43210)
        }

    @Test
    fun stalledUdpSetupDoesNotBlockNeutralInputAndLateSetupClosesAfterOwnerLoss() {
        val io = IO(version5Fixture())
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        val udpClosed = CountDownLatch(1)
        val worker = java.util.concurrent.Executors.newSingleThreadExecutor()
        val client =
            client(
                io,
                version = 5,
                datagramFactory = { _, _ ->
                    started.countDown()
                    check(release.await(2, TimeUnit.SECONDS))
                    object : NativeDatagramIO {
                        override fun offer(packet: ByteArray) = false

                        override fun close() {
                            udpClosed.countDown()
                        }
                    }
                },
            )
        try {
            client.authenticate()
            val admission =
                worker
                    .submit<PhoneInputAdmission> { client.prepareInput(map()) }
                    .get(500, TimeUnit.MILLISECONDS)
            assertTrue(started.await(1, TimeUnit.SECONDS))
            val engine = admission.bind()
            assertTrue(engine.connected)
            assertTrue(engine.begin(1, "1", 0.2, 0.2))
            client.close()
            release.countDown()
            assertTrue(udpClosed.await(1, TimeUnit.SECONDS))
            engine.tick()
            assertFalse(engine.connected)
            assertEquals(GamepadReport.neutral(), engine.state)
        } finally {
            client.close()
            release.countDown()
            worker.shutdownNow()
        }
    }

    @Test
    fun invalidVersion5ProgressClosesTheBoundTouchOwner() {
        for ((field, replacement) in
            listOf(
                "active" to false,
                "sessionId" to "99".repeat(16),
                "lastAcceptedSequence" to "2",
            )) {
            val io = IO(version5Fixture())
            val client =
                client(
                    io,
                    version = 5,
                    datagramFactory = { _, _ ->
                        object : NativeDatagramIO {
                            override fun offer(packet: ByteArray) = false

                            override fun close() {}
                        }
                    },
                )
            try {
                client.authenticate()
                val engine = client.prepareInput(map()).bind()
                assertTrue(engine.begin(1, "1", 0.2, 0.2))
                val progress =
                    JSONObject()
                        .put("version", 1)
                        .put("command", "input-status")
                        .put("connectionId", "ab".repeat(16))
                        .put("sessionId", "33".repeat(16))
                        .put("active", true)
                        .put("generation", "1")
                        .put("revision", "1")
                        .put("lastAcceptedSequence", "0")
                        .put("inputEnabled", false)
                        .put(field, replacement)
                io.queue.add(
                    ControlTLSFrame(ControlTLSFrame.Kind.CONTROL, progress.toString().toByteArray())
                )
                assertTrue(io.closed.await(500, TimeUnit.MILLISECONDS))
                engine.tick()
                assertFalse(engine.connected)
                assertEquals(GamepadReport.neutral(), engine.state)
            } finally {
                client.close()
            }
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
        assertEquals(PhoneInputFailureStage.HEARTBEAT_STATUS, client.inputFailureStage)
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
            assertNull(client.inputFailureStage)
            assertEquals(reason, engine.lastRelease)
            assertTrue(io.closed.await(1, TimeUnit.SECONDS))
            assertFalse(engine.connected)
            assertEquals(GamepadReport.neutral(), engine.state)
        }
    }

    @Test
    fun actualNativeTouchCrossesTlsAndIpcWithFreshNeutralReconnect() {
        for (mode in listOf("tls", "udp", "udp-blackhole")) actualNativeInputWitness(mode)
    }

    @Test
    fun actualAutomaticRenewalHoldsBeyondInitialExpiryAcrossUdpAndTlsFallback() {
        for (mode in listOf("renewal-udp", "renewal-tls-fallback")) actualNativeInputWitness(mode)
    }

    private fun actualNativeInputWitness(mode: String) {
        val renewing = mode.startsWith("renewal-")
        val path = System.getenv("THUMBLE_NATIVE_INPUT_PROBE")
        org.junit.Assume.assumeTrue(path != null)
        val process =
            (if (renewing) ProcessBuilder(path!!, "--renewal-watch") else ProcessBuilder(path!!))
                .start()
        val reader = process.inputStream.bufferedReader()
        val reads = java.util.concurrent.Executors.newSingleThreadExecutor()
        var enrollment: PhoneEnrollmentClient? = null
        var control: PhoneControlClient? = null
        try {
            fun line(sample: () -> Unit = {}) =
                JSONObject(
                    awaitNativeProbeReply(
                        reads.submit<String> { reader.readLine() ?: error("probe closed") },
                        sample,
                    )
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
                        controlVersion = if (renewing) 6 else if (mode == "tls") 4 else 5,
                        datagramFactory = { host, port ->
                            if (mode == "udp-blackhole" || mode == "renewal-tls-fallback")
                                object : NativeDatagramIO {
                                    private var closed = false

                                    override fun offer(packet: ByteArray) = !closed

                                    override fun close() {
                                        closed = true
                                    }
                                }
                            else NativeDatagramDelivery(java.net.InetSocketAddress(host, port))
                        },
                    )
                control = client
                assertTrue(client.authenticate().inputSessionAvailable)
                command(97)
                assertEquals(generation, line().getString("generation"))
                val metadata = client.inputConfiguration()
                assertTrue(metadata.active)
                assertEquals(generation, metadata.generation)
                assertEquals(generation, metadata.revision)
                assertFalse(metadata.inputEnabled)
                val map =
                    ControlMap(
                        generation = generation,
                        revision = generation,
                        controls =
                            if (renewing)
                                listOf(
                                    ControlRegion("south", "south", 0.0, 0.0, 0.4, 1.0),
                                    ControlRegion("trigger", "leftTrigger", 0.5, 0.0, 0.4, 1.0),
                                )
                            else map().controls,
                    )
                val admission = client.prepareInput(map)
                val engine = admission.bind()
                val adopted = engine.claimTouchSurface()
                assertEquals(generation, adopted.generation)
                assertEquals(generation, adopted.revision)
                assertTrue(engine.connected)
                // The sink is bounded and asynchronous: witness actual receiver admission instead
                // of treating status as a flush.
                command(122)
                assertTrue(line().getBoolean("freshNeutral"))
                assertTrue(engine.begin(1, generation, 0.2, 0.2))
                if (renewing && generation == "1") {
                    assertTrue(engine.begin(2L, generation, 0.6, 0.2))
                    // Keep native sampling active while initial UDP loss selects TLS fallback.
                    repeat(16) {
                        Thread.sleep(16)
                        engine.tick()
                    }
                    command(98)
                    assertTrue(line().getBoolean("watching"))
                    val until = System.nanoTime() + TimeUnit.SECONDS.toNanos(75)
                    while (System.nanoTime() < until) {
                        Thread.sleep(16)
                        engine.tick()
                        assertTrue(engine.connected)
                    }
                    command(118)
                    val verified = line { engine.tick() }
                    assertTrue(verified.getBoolean("continuousHeld"))
                    assertTrue(verified.getInt("rotations") >= 2)
                    assertTrue(verified.getLong("durationMs") >= 75_000)
                    assertEquals(0, verified.getInt("neutralPulses"))
                    assertEquals(350, verified.getInt("inputTtlMs"))
                    println(
                        "native-renewal-witness platform=kotlin mode=$mode durationMs=${verified.getLong("durationMs")} rotations=${verified.getInt("rotations")} samples=${verified.getInt("samples")}"
                    )
                    engine.end(2L, generation)
                } else if (generation == "1" || mode != "tls")
                    repeat(if (generation == "1") 62 else 5) {
                        Thread.sleep(50)
                        engine.tick()
                    }
                command(104)
                val held = line { engine.tick() }
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

    @Test
    fun bootstrapConfigurationExposesExactEpochsWithoutAdmittingInput() {
        for ((active, generation, revision) in
            listOf(
                Triple(false, "0", "0"),
                Triple(false, "1", "1"),
                Triple(true, "18446744073709551615", "18446744073709551615"),
            )) {
            val f = fixture()
            val io = IO(f)
            val client = client(io)
            try {
                rejects { client.inputConfiguration() }
                client.authenticate()
                io.replies(
                    f.getJSONObject("configuration")
                        .put("active", active)
                        .put("generation", generation)
                        .put("revision", revision)
                )
                val receipt = client.inputConfiguration()
                assertEquals(active, receipt.active)
                assertEquals(generation, receipt.generation)
                assertEquals(revision, receipt.revision)
                assertFalse(receipt.inputEnabled)
                assertTrue(io.inputs().isEmpty())
                assertEquals(listOf("hello", "authenticate", "input-configuration"), io.commands())
            } finally {
                client.close()
            }
        }
    }

    @Test
    fun malformedBootstrapMetadataClosesWithoutGrantOrTouchOwner() {
        for ((field, replacement) in
            listOf(
                "connectionId" to "ff".repeat(16),
                "generation" to "0",
                "generation" to "18446744073709551616",
                "generation" to "01",
                "generation" to 1,
                "revision" to "-1",
                "revision" to "18446744073709551616",
                "active" to 1,
                "inputEnabled" to true,
                "credential" to "unexpected",
            )) {
            val f = fixture()
            val io = IO(f)
            val client = client(io)
            client.authenticate()
            io.replies(f.getJSONObject("configuration").put(field, replacement))
            rejects { client.inputConfiguration() }
            assertTrue(io.closed.await(1, TimeUnit.SECONDS))
            assertTrue(io.inputs().isEmpty())
            assertEquals(listOf("hello", "authenticate", "input-configuration"), io.commands())
        }
    }

    @Test
    fun metadataInspectionDoesNotConsumeOrReplaceExactGrantAdmission() {
        for (changed in listOf(false, true)) {
            val f = fixture()
            val io = IO(f)
            val client = client(io)
            try {
                client.authenticate()
                val inspected = f.getJSONObject("configuration")
                val current =
                    JSONObject(inspected.toString()).apply { if (changed) put("revision", "2") }
                io.replies(inspected, current, f.getJSONObject("grant"))
                assertEquals("1", client.inputConfiguration().revision)
                assertTrue(io.inputs().isEmpty())
                if (changed) {
                    rejects { client.prepareInput(map()) }
                    assertTrue(io.closed.await(1, TimeUnit.SECONDS))
                    assertTrue(io.inputs().isEmpty())
                    assertFalse(io.commands().contains("input-grant"))
                } else {
                    val sendStarted = CountDownLatch(1)
                    val continueSend = CountDownLatch(1)
                    io.beforeInputSend = {
                        sendStarted.countDown()
                        check(continueSend.await(2, TimeUnit.SECONDS))
                    }
                    val engine = client.prepareInput(map()).bind()
                    try {
                        assertTrue(sendStarted.await(1, TimeUnit.SECONDS))
                        assertTrue(engine.connected)
                        assertEquals(GamepadReport.neutral(), engine.state)
                        rejects { client.inputConfiguration() }
                        assertTrue(engine.connected)
                        assertTrue(io.inputs().isEmpty())
                        continueSend.countDown()
                        waitUntil { io.inputs().isNotEmpty() }
                        assertTrue(engine.connected)
                        assertEquals(1, io.inputs().size)
                    } finally {
                        continueSend.countDown()
                        engine.cancel(ReleaseReason.disconnected)
                    }
                }
            } finally {
                client.close()
            }
        }
    }

    @Test
    fun lateBootstrapMetadataCannotSurviveCloseOrInterruption() {
        for (interrupt in listOf(false, true)) {
            val f = fixture()
            val io = IO(f)
            val client = client(io)
            client.authenticate()
            io.pauseGrant = true
            io.pauseAt = 3
            val rejected = CountDownLatch(1)
            val worker = Thread {
                try {
                    client.inputConfiguration()
                } catch (_: PhoneControlRejected) {
                    rejected.countDown()
                }
            }
            try {
                worker.start()
                assertTrue(io.paused.await(1, TimeUnit.SECONDS))
                rejects { client.status() }
                if (interrupt) worker.interrupt() else client.close()
                io.resume.countDown()
                assertTrue(rejected.await(1, TimeUnit.SECONDS))
                assertTrue(io.closed.await(1, TimeUnit.SECONDS))
                assertTrue(io.inputs().isEmpty())
                assertEquals(listOf("hello", "authenticate", "input-configuration"), io.commands())
            } finally {
                client.close()
                io.resume.countDown()
                worker.join(1000)
            }
        }
    }
}
