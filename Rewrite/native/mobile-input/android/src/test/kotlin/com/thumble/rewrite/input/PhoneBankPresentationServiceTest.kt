package com.thumble.rewrite.input

import java.net.InetSocketAddress
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Real native TLS + Bun service + sole configuration child, synthetic recording only. */
class PhoneBankPresentationServiceTest {
    @Test
    fun actualAllBanksAndThemesRefreshWhileTriggersAndSouthStayHeldThenRevocationFencesReads() {
        val path = System.getenv("THUMBLE_BANK_PRESENTATION_SERVICE_PROBE")
        org.junit.Assume.assumeTrue(path != null)
        for (fallback in listOf(false, true)) witness(path!!, fallback)
    }

    private fun witness(path: String, fallback: Boolean) {
        val process =
            ProcessBuilder(path, "--bank-presentation")
                .redirectError(ProcessBuilder.Redirect.INHERIT)
                .start()
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
            assertEquals(3, delivered.map.controls.size)
            assertEquals(
                setOf("south", "leftVerticalTrigger", "rightVerticalTrigger"),
                delivered.map.controls.map { it.action }.toSet(),
            )
            val owner = control.prepareInput(delivered.map).bind()
            engine = owner
            owner.claimTouchSurface()
            assertTrue(command('z').getBoolean("freshNeutral"))
            assertTrue(owner.begin(1, status.generation, 0.5, 0.5))
            for ((id, action) in
                listOf(2L to "leftVerticalTrigger", 3L to "rightVerticalTrigger")) {
                val trigger = delivered.map.controls.single { it.action == action }
                assertTrue(
                    owner.begin(id, status.generation, trigger.x + trigger.width / 2, trigger.y)
                )
            }
            assertEquals(1.0, owner.state.leftTrigger, 0.0)
            assertEquals(1.0, owner.state.rightTrigger, 0.0)
            assertTrue(command('w').getBoolean("watching"))
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
            val request =
                PhonePresentationRequest(saved, delivered, "light", PhonePresentationBank.BASE)
            fun client(phone: String = "phone-a") =
                PhonePresentationClient(endpoint, ::connect, load(phone), System::currentTimeMillis)
                    .also { clients.add(it) }
            fun read(
                bank: PhonePresentationBank,
                theme: String,
            ): Pair<PhonePresentationMetadata, PhonePresentationIcon> {
                val peer = client()
                try {
                    val metadata = work {
                        peer.read(PhonePresentationRequest(saved, delivered, theme, bank))
                    }
                    assertEquals(bank.wire, metadata.bridgeEvent()["bank"])
                    assertEquals(2, metadata.bridgeEvent()["presentationProtocol"])
                    assertEquals(
                        saved.configurationRevision,
                        metadata.bridgeEvent()["expectedConfigurationRevision"],
                    )
                    val icon = work {
                        peer.icon(metadata.controls.single { it.id == offer.getString("southId") })
                    }
                    health("bank_read")
                    return metadata to icon
                } finally {
                    peer.close()
                }
            }
            val originals = mutableMapOf<String, String>()
            for (theme in listOf("light", "dark")) for (bank in PhonePresentationBank.entries) {
                val (_, icon) = read(bank, theme)
                originals["$theme:${bank.wire}"] = icon.sha256
            }
            assertEquals(8, originals.values.toSet().size)
            // A/B/A is an actual new management batch each time, under the unchanged input pin.
            val (other, _) = read(PhonePresentationBank.LEFT_TRIGGER, "light")
            val initialClient = client()
            val initial = work { initialClient.read(request) }
            val initialControl = initial.controls.single { it.id == offer.getString("southId") }
            val oldIcon = work { initialClient.icon(initialControl) }
            assertEquals(originals["light:base"], oldIcon.sha256)
            // A control from another bank cannot be used as an icon capability for this batch.
            assertTrue(
                work {
                    try {
                        initialClient.icon(other.controls.single { it.id == initialControl.id })
                        false
                    } catch (_: PhonePresentationRejected) {
                        true
                    }
                }
            )
            initialClient.close()
            val staleClient = client()
            val stale = work { staleClient.read(request) }
            val refresh = command('m')
            assertTrue(refresh.getBoolean("refreshed"))
            assertEquals(status.generation, refresh.getString("generation"))
            assertEquals(status.revision, refresh.getString("revision"))
            assertTrue(
                work {
                    try {
                        staleClient.icon(stale.controls.single { it.id == initialControl.id })
                        false
                    } catch (e: PhonePresentationUnavailable) {
                        e.code == "presentation_stale"
                    }
                }
            )
            staleClient.close()
            val refreshed = mutableSetOf<String>()
            for (theme in listOf("light", "dark")) for (bank in PhonePresentationBank.entries) {
                val (metadata, icon) = read(bank, theme)
                assertEquals(
                    refresh.getString("configurationRevision"),
                    metadata.presentationRevision,
                )
                assertEquals(refresh.getString("sourceHash"), metadata.presentationSourceHash)
                assertNotEquals(originals["$theme:${bank.wire}"], icon.sha256)
                assertEquals("icon", icon.notification(metadata, initialControl.id)["kind"])
                refreshed.add(icon.sha256)
            }
            assertEquals(8, refreshed.size)
            assertTrue(command('x').getBoolean("casRejected"))
            while (System.nanoTime() - start < TimeUnit.MILLISECONDS.toNanos(1600)) {
                Thread.sleep(16)
                health("after_cas_hold")
            }
            val held = command('g')
            assertTrue(held.getBoolean("bankHeld"))
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
