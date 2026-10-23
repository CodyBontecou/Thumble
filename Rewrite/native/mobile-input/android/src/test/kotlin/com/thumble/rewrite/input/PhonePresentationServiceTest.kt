package com.thumble.rewrite.input

import java.net.InetSocketAddress
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Real native TLS + Bun service + sole configuration child, synthetic recording only. */
class PhonePresentationServiceTest {
    @Test
    fun actualPresentationRefreshAndStaleCASPreserveHeldInputThenRevokePreventsMetadata() {
        val path = System.getenv("THUMBLE_PRESENTATION_SERVICE_PROBE")
        org.junit.Assume.assumeTrue(path != null)
        for (fallback in listOf(false, true)) witness(path!!, fallback)
    }

    private fun witness(path: String, fallback: Boolean) {
        val process = ProcessBuilder(path).redirectError(ProcessBuilder.Redirect.INHERIT).start()
        val reader = process.inputStream.bufferedReader()
        val reads = Executors.newSingleThreadExecutor()
        val worker = Executors.newSingleThreadExecutor()
        var engine: InputEngine? = null
        var input: PhoneControlClient? = null
        val clients = mutableListOf<PhonePresentationClient>()
        fun line(): JSONObject =
            JSONObject(
                awaitNativeProbeReply(
                    reads.submit<String> { reader.readLine() ?: error("presentation_probe_closed") }
                ) {
                    engine?.tick()
                }
            )
        fun command(c: Char): JSONObject {
            process.outputStream.write(c.code)
            process.outputStream.flush()
            return line()
        }
        fun <T> work(block: () -> T): T =
            awaitNativeProbeReply(worker.submit<T> { block() }) { engine?.tick() }
        try {
            val offer = line()
            assertEquals("real-bun-service", offer.getString("backend"))
            assertEquals(1, offer.getInt("profileCount"))
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
            val credentials = mutableMapOf<String, PhoneCredential>()
            fun enroll(offer: EnrollmentInvitation, id: String) {
                val client =
                    PhoneEnrollmentClient(
                        offer,
                        ::connect,
                        { credentials[id] = it },
                        System::currentTimeMillis,
                    )
                try {
                    client.enroll(id, "Synthetic presentation witness")
                } finally {
                    client.close()
                }
            }
            enroll(invitation, "phone-a")
            val secondary = command('p')
            enroll(
                EnrollmentInvitation(
                    invitation.host,
                    invitation.port,
                    invitation.certificatePin,
                    invitation.authorityInstanceID,
                    secondary.getString("windowId"),
                    secondary.getString("secret"),
                    secondary.getLong("expiresAt"),
                ),
                "phone-b",
            )
            val endpoint =
                TrustedHostEndpoint(
                    invitation.host,
                    invitation.port,
                    invitation.certificatePin,
                    invitation.authorityInstanceID,
                )
            fun load(id: String): (String, Long) -> PhoneCredential? = { pin, now ->
                credentials[id]?.takeIf {
                    it.metadata.hostPin == pin && it.metadata.expiresAt > now
                }
            }
            val control =
                PhoneControlClient(
                    endpoint,
                    ::connect,
                    load("phone-a"),
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
            input = control
            assertTrue(control.authenticate().inputSessionAvailable)
            assertEquals("1", command('a').getString("generation"))
            val status = control.inputConfiguration()
            assertTrue(status.active)
            assertFalse(status.inputEnabled)
            val catalog =
                PhoneCatalogClient(endpoint, ::connect, load("phone-a"), System::currentTimeMillis)
                    .read() as PhoneCatalogResult.Catalog
            val saved =
                SavedControllerRequest(
                    catalog.page.revision,
                    checkNotNull(catalog.page.contentHash),
                    checkNotNull(catalog.page.activeProfileID),
                    status.generation,
                    status.revision,
                    "874",
                    "393",
                )
            val delivered =
                SavedControllerClient(
                        endpoint,
                        ::connect,
                        load("phone-a"),
                        System::currentTimeMillis,
                    )
                    .read(saved)
            assertEquals(1, delivered.map.controls.size)
            assertEquals("south", delivered.map.controls.single().action)
            val owner = control.prepareInput(delivered.map).bind()
            engine = owner
            owner.claimTouchSurface()
            assertTrue(command('z').getBoolean("freshNeutral"))
            assertTrue(owner.begin(1, status.generation, 0.5, 0.5))
            assertTrue(command('q').getBoolean("watching"))
            val start = System.nanoTime() // Measure the hold only after its native watch ACK.
            fun health(phase: String) {
                owner.tick()
                if (!owner.connected) {
                    val state = command('d')
                    fail(
                        "presentation_input_lost phase=$phase fallback=$fallback input=${control.inputFailureStage} checkpoint=${control.checkpointFailure} active=${state.getBoolean("active")} reason=${state.getString("reason")}"
                    )
                }
            }
            val request = PhonePresentationRequest(saved, delivered, "light")
            fun client(phone: String = "phone-a") =
                PhonePresentationClient(endpoint, ::connect, load(phone), System::currentTimeMillis)
                    .also { clients.add(it) }
            val initialClient = client()
            val initial = work { initialClient.read(request) }
            val initialControl = initial.controls.single()
            assertEquals("Initial spell", initialControl.label)
            assertEquals("not-evaluated", initial.freshness)
            val oldIcon = work { initialClient.icon(initialControl) }
            assertEquals(offer.getString("iconSHA256"), oldIcon.sha256)
            health("before_refresh")
            val refresh = command('u')
            assertTrue(refresh.getBoolean("refreshed"))
            assertEquals(status.generation, refresh.getString("generation"))
            assertEquals(status.revision, refresh.getString("revision"))
            assertTrue(
                work {
                    try {
                        initialClient.icon(initialControl)
                        false
                    } catch (e: PhonePresentationUnavailable) {
                        e.code == "presentation_stale"
                    }
                }
            )
            health("after_stale")
            val freshClient = client()
            val fresh = work { freshClient.read(request) }
            val freshControl = fresh.controls.single()
            assertEquals("Refreshed spell", freshControl.label)
            assertEquals(refresh.getString("configurationRevision"), fresh.presentationRevision)
            assertEquals(refresh.getString("sourceHash"), fresh.presentationSourceHash)
            assertEquals(
                saved.configurationRevision,
                fresh.bridgeEvent()["expectedConfigurationRevision"],
            )
            val newIcon = work { freshClient.icon(freshControl) }
            assertEquals(refresh.getString("iconSHA256"), newIcon.sha256)
            assertNotEquals(oldIcon.sha256, newIcon.sha256)
            assertEquals("icon", newIcon.notification(fresh, freshControl.id)["kind"])
            freshClient.close()
            health("before_cas")
            assertTrue(command('x').getBoolean("casRejected"))
            health("after_cas")
            while (System.nanoTime() - start < TimeUnit.MILLISECONDS.toNanos(1600)) {
                Thread.sleep(16)
                owner.tick()
                health("after_cas_hold")
            }
            val held = command('j')
            assertTrue(held.getBoolean("catalogHeld"))
            assertEquals(0, held.getInt("neutralPulses"))
            assertEquals(350, held.getInt("inputTtlMs"))
            assertFalse(held.getBoolean("inputEnabled"))
            assertTrue(held.getInt("samples") > 0)
            owner.cancel(ReleaseReason.background)
            assertEquals("native_input_released", command('n').getString("reason"))
            // Existing local operator revoke intentionally releases all input. Test it only
            // after the independent continuous-hold proof and clean release above.
            assertTrue(command('r').getBoolean("secondaryRevoked"))
            var sent = 0
            val revoked =
                PhonePresentationClient(
                    endpoint,
                    {
                        val channel = connect()
                        object : NativeFrameIO {
                            override fun send(frame: ControlTLSFrame) {
                                sent++
                                channel.send(frame)
                            }

                            override fun receive() = channel.receive()

                            override fun close() = channel.close()
                        }
                    },
                    load("phone-b"),
                    System::currentTimeMillis,
                )
            clients.add(revoked)
            assertTrue(
                work {
                    try {
                        revoked.read(request)
                        false
                    } catch (_: PhonePresentationRejected) {
                        true
                    } catch (e: PhonePresentationUnavailable) {
                        e.code in PhonePresentationWire.errors
                    }
                }
            )
            assertEquals(
                2,
                sent,
            ) // Hello and credential proof only; no metadata request after revoke.
            assertTrue(command('f').getBoolean("completed"))
            assertTrue(process.waitFor(5, TimeUnit.SECONDS))
            assertEquals(0, process.exitValue())
        } finally {
            engine?.let { if (it.connected) it.cancel(ReleaseReason.disposed) }
            clients.forEach { it.close() }
            input?.close()
            if (process.isAlive) process.destroy()
            if (!process.waitFor(5, TimeUnit.SECONDS))
                process.destroyForcibly().waitFor(5, TimeUnit.SECONDS)
            reader.close()
            reads.shutdownNow()
            worker.shutdownNow()
        }
    }
}
