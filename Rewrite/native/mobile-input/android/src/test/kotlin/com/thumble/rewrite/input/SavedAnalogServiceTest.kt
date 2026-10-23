package com.thumble.rewrite.input

import java.net.InetSocketAddress
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class SavedAnalogServiceTest {
    @Test
    fun actualSavedAnalogMapDrivesBothSticksAndTriggersOverUdpAndFallback() {
        val path = System.getenv("THUMBLE_REAL_SERVICE_PHONE_PROBE")
        org.junit.Assume.assumeTrue(path != null)
        for (mode in listOf("udp", "tls-fallback", "unsupported")) witness(path!!, mode)
    }

    private fun witness(path: String, mode: String) {
        val fallback = mode == "tls-fallback"
        val unsupported = mode == "unsupported"
        val process =
            ProcessBuilder(
                    path,
                    if (unsupported) "--saved-controller-analog-unsupported"
                    else "--saved-controller-analog",
                )
                .redirectError(ProcessBuilder.Redirect.INHERIT)
                .start()
        val reader = process.inputStream.bufferedReader()
        val reads = Executors.newSingleThreadExecutor()
        val catalogWorker = Executors.newSingleThreadExecutor()
        var control: PhoneControlClient? = null
        var catalog: PhoneCatalogClient? = null
        var engine: InputEngine? = null
        fun line(sample: () -> Unit = {}) =
            JSONObject(
                awaitNativeProbeReply(
                    reads.submit<String> {
                        reader.readLine() ?: error("real_service_probe_closed")
                    },
                    sample,
                )
            )
        fun command(byte: Int) {
            process.outputStream.write(byte)
            process.outputStream.flush()
        }
        try {
            val offer = line()
            assertEquals("real-bun-service", offer.getString("backend"))
            assertEquals(2, offer.getInt("profileCount"))
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
                        InetSocketAddress(invitation.host, invitation.port),
                        invitation.certificatePin,
                    )
                return object : NativeFrameIO {
                    override fun send(frame: ControlTLSFrame) = socket.send(frame)

                    override fun receive() = socket.receive()

                    override fun close() = socket.close()
                }
            }
            var saved: PhoneCredential? = null
            val enrollment =
                PhoneEnrollmentClient(
                    invitation,
                    ::connect,
                    { saved = it },
                    System::currentTimeMillis,
                )
            try {
                enrollment.enroll("phone-a", "Synthetic real service witness")
            } finally {
                enrollment.close()
            }
            val endpoint =
                TrustedHostEndpoint(
                    invitation.host,
                    invitation.port,
                    invitation.certificatePin,
                    invitation.authorityInstanceID,
                )
            val load = { pin: String, now: Long ->
                saved?.takeIf { it.metadata.hostPin == pin && it.metadata.expiresAt > now }
            }
            val input =
                PhoneControlClient(
                    endpoint,
                    ::connect,
                    load,
                    System::currentTimeMillis,
                    controlVersion = 6,
                    datagramFactory = { host, port ->
                        if (fallback)
                            object : NativeDatagramIO {
                                private var closed = false

                                override fun offer(packet: ByteArray) = !closed

                                override fun close() {
                                    closed = true
                                }
                            }
                        else NativeDatagramDelivery(InetSocketAddress(host, port))
                    },
                )
            control = input
            assertTrue(input.authenticate().inputSessionAvailable)
            command(97)
            assertEquals("1", line().getString("generation"))
            val metadata = input.inputConfiguration()
            assertTrue(metadata.active)
            assertFalse(metadata.inputEnabled)
            assertEquals("1", metadata.generation)
            assertEquals("1", metadata.revision)
            val selected =
                PhoneCatalogClient(endpoint, ::connect, load, System::currentTimeMillis).read()
            check(selected is PhoneCatalogResult.Catalog)
            val maps = SavedControllerClient(endpoint, ::connect, load, System::currentTimeMillis)
            val mapRequest =
                SavedControllerRequest(
                    selected.page.revision,
                    checkNotNull(selected.page.contentHash),
                    checkNotNull(selected.page.activeProfileID),
                    metadata.generation,
                    metadata.revision,
                    "874",
                    "393",
                )
            if (unsupported) {
                try {
                    maps.read(mapRequest)
                    fail("unsupported saved map admitted")
                } catch (failure: SavedControllerUnavailable) {
                    assertEquals("saved_map_unsupported_profile", failure.code)
                }
                input.close()
                command(102)
                assertTrue(line().getBoolean("completed"))
                assertTrue(process.waitFor(5, TimeUnit.SECONDS))
                assertEquals(0, process.exitValue())
                return
            }
            val delivered = maps.read(mapRequest)
            assertEquals(5, delivered.map.controls.size)
            assertEquals(
                listOf(
                    "leftStandardStick",
                    "rightStandardStick",
                    "leftVerticalTrigger",
                    "rightHorizontalTrigger",
                    "south",
                ),
                delivered.map.controls.map { it.action },
            )
            val owner = input.prepareInput(delivered.map).bind()
            engine = owner
            owner.claimTouchSurface()
            command(122)
            assertTrue(line().getBoolean("freshNeutral"))
            val points = listOf(.736 to .5, .5 to .264, .5 to .582, .418 to .5, .5 to .5)
            delivered.map.controls.forEachIndexed { index, region ->
                val point = points[index]
                assertTrue(
                    owner.begin(
                        index.toLong() + 1,
                        metadata.generation,
                        region.x + point.first * region.width,
                        region.y + point.second * region.height,
                    )
                )
            }
            assertEquals("0014001066663333000000003333000000000000", GamepadReport.hex(owner.state))
            command(107)
            assertTrue(line { owner.tick() }.getBoolean("watching"))
            // Dedicated role7 worker/socket shares only verified endpoint/credential authority.
            val management =
                PhoneCatalogClient(endpoint, ::connect, load, System::currentTimeMillis)
            catalog = management
            val result = catalogWorker.submit<PhoneCatalogResult> { management.read() }
            val until = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(1600)
            while (System.nanoTime() < until) {
                Thread.sleep(16)
                owner.tick()
                assertTrue(owner.connected)
            }
            val read = awaitNativeProbeReply(result) { owner.tick() }
            assertTrue(read is PhoneCatalogResult.Catalog)
            val page = (read as PhoneCatalogResult.Catalog).page
            assertEquals("1", page.revision)
            assertEquals("bbbbbbbb-0000-0000-0000-000000000002", page.activeProfileID)
            assertNull(page.defaultProfileID)
            assertNull(page.nextOffset)
            assertEquals(
                listOf(
                    "aaaaaaaa-0000-0000-0000-000000000001",
                    "bbbbbbbb-0000-0000-0000-000000000002",
                ),
                page.profiles.map { it.id },
            )
            assertEquals(2, read.bridgeMetadata()["profileCount"])
            command(111)
            val held = line { owner.tick() }
            assertTrue(held.getBoolean("analogHeld"))
            assertEquals(0, held.getInt("neutralPulses"))
            assertEquals(350, held.getInt("inputTtlMs"))
            assertFalse(held.getBoolean("inputEnabled"))
            assertTrue(held.getLong("durationMs") >= 1500)
            assertTrue(held.getInt("samples") > 0)
            owner.cancel(ReleaseReason.background)
            command(110)
            assertEquals("native_input_released", line().getString("reason"))
            assertFalse(owner.connected)
            command(102)
            assertTrue(line().getBoolean("completed"))
            assertTrue(process.waitFor(5, TimeUnit.SECONDS))
            assertEquals(0, process.exitValue())
        } finally {
            engine?.let { if (it.connected) it.cancel(ReleaseReason.disposed) }
            catalog?.close()
            control?.close()
            if (process.isAlive) process.destroy()
            if (!process.waitFor(5, TimeUnit.SECONDS))
                process.destroyForcibly().waitFor(5, TimeUnit.SECONDS)
            reader.close()
            reads.shutdownNow()
            catalogWorker.shutdownNow()
        }
    }
}
