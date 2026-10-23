package com.thumble.rewrite.input

import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class PhysicalPhoneControlTest {
    private fun fixture() =
        JSONObject(
            checkNotNull(javaClass.getResourceAsStream("/Fixtures/physical-input-control-v9.json"))
                .bufferedReader()
                .use { it.readText() }
        )

    private fun map() =
        ControlMap(
            generation = "1",
            revision = "1",
            controls = listOf(ControlRegion("south", "south", 0.0, 0.0, 1.0, 1.0)),
        )

    private fun fields(value: JSONObject) =
        EnrollmentJSON.parse(value.toString().toByteArray(), allowNull = true)

    private fun rejects(action: () -> Unit) {
        try {
            action()
            fail("physical input admitted")
        } catch (_: PhoneControlRejected) {}
    }

    private class IO(values: List<JSONObject>) : NativeFrameIO {
        val replies =
            ConcurrentLinkedQueue(
                values.map {
                    ControlTLSFrame(ControlTLSFrame.Kind.CONTROL, it.toString().toByteArray())
                }
            )
        val sent = java.util.Collections.synchronizedList(mutableListOf<ControlTLSFrame>())
        val closed = CountDownLatch(1)
        val neutral = CountDownLatch(1)
        val held = CountDownLatch(1)
        private val inputs = AtomicInteger()

        override fun send(frame: ControlTLSFrame) {
            if (closed.count == 0L) throw PhoneControlRejected()
            sent.add(frame)
            if (frame.kind == ControlTLSFrame.Kind.INPUT)
                when (inputs.incrementAndGet()) {
                    1 -> neutral.countDown()
                    2 -> held.countDown()
                }
        }

        override fun receive(): ControlTLSFrame {
            return replies.poll()
                ?: run {
                    closed.await(2, TimeUnit.SECONDS)
                    throw PhoneControlRejected()
                }
        }

        override fun close() {
            closed.countDown()
        }
    }

    private fun client(
        io: IO,
        mode: PhoneOutputMode = PhoneOutputMode.MACOS_HID,
        load: () -> Unit = {},
    ) =
        PhoneControlClient(
            TrustedHostEndpoint("127.0.0.1", 1234, "1".repeat(64), "authority-a"),
            { io },
            { _, _ ->
                load()
                PhoneCredential(
                    PhoneCredentialMetadata("1".repeat(64), "phone-a", 1, 100000),
                    ByteArray(32) { 34 },
                )
            },
            { 1000 },
            controlVersion = 9,
            elapsed = { 1_000_000L },
            datagramFactory = { _, _ -> throw PhoneControlRejected() },
            outputMode = mode,
        )

    @Test
    fun explicitPhysicalV9AuthenticatesAndBindsWithoutAnOSDevice() {
        val f = fixture()
        val io =
            IO(
                listOf("hello", "authenticated", "configuration", "configuration", "grant").map {
                    f.getJSONObject(it)
                }
            )
        val client = client(io)
        try {
            val metadata = client.authenticate()
            assertTrue(metadata.inputEnabled)
            assertEquals(PhoneOutputMode.MACOS_HID, metadata.outputMode)
            val configuration = client.inputConfiguration()
            assertTrue(configuration.inputEnabled)
            assertEquals(PhoneOutputMode.MACOS_HID, configuration.outputMode)
            val engine = client.prepareInput(map()).bind()
            assertTrue(engine.connected)
            assertTrue(io.neutral.await(1, TimeUnit.SECONDS))
            assertTrue(engine.begin(1, "1", 0.2, 0.2))
            assertTrue(io.held.await(1, TimeUnit.SECONDS))
            assertEquals(
                fields(f.getJSONObject("request")),
                EnrollmentJSON.parse(io.sent.first().payload),
            )
            client.close()
            engine.tick()
            assertFalse(engine.connected)
            assertTrue(io.closed.await(1, TimeUnit.SECONDS))
        } finally {
            client.close()
        }
    }

    @Test
    fun physicalV9RejectsImplicitIntentAndRecordingFallbackBeforeCredentialRead() {
        for (mode in PhoneOutputMode.entries) {
            val f = fixture()
            val io = IO(listOf(f.getJSONObject("hello").put("controlVersion", 6)))
            var loads = 0
            val client = client(io, mode) { loads++ }
            rejects { client.authenticate() }
            assertEquals(0, loads)
            assertFalse(
                io.sent.any {
                    EnrollmentJSON.parse(it.payload)["command"] ==
                        EnrollmentJSON.Value.Text("authenticate")
                }
            )
            client.close()
        }
    }

    @Test
    fun physicalDTOsRequireExactBackendAdmissionAndKeepRecordingFalseGuards() {
        val f = fixture()
        val connection = "ab".repeat(16)
        val map = map()
        PhoneInputGrant(
            fields(f.getJSONObject("grant")),
            connection,
            map,
            true,
            PhoneOutputMode.MACOS_HID,
        )
        PhoneInputProgress(
            fields(f.getJSONObject("progress")),
            connection,
            "33".repeat(16),
            map,
            0u,
            null,
            PhoneOutputMode.MACOS_HID,
        )
        PhoneInputRenewal(
            fields(f.getJSONObject("renewal")),
            connection,
            map,
            PhoneInputRenewalScope("33".repeat(16), 43210, 2000, 100000),
            1000,
            PhoneOutputMode.MACOS_HID,
        )
        for ((key, value) in
            listOf(
                "inputEnabled" to false,
                "outputBackend" to "recording",
                "generation" to "2",
                "extra" to true,
            )) {
            val grant = fixture().getJSONObject("grant").put(key, value)
            rejects {
                PhoneInputGrant(fields(grant), connection, map, true, PhoneOutputMode.MACOS_HID)
            }
        }
        rejects { PhoneInputGrant(fields(f.getJSONObject("grant")), connection, map, true) }
        rejects {
            PhoneInputConfiguration.decode(fields(f.getJSONObject("configuration")), connection)
        }
        val inactive =
            f.getJSONObject("configuration").put("active", false).put("inputEnabled", false)
        assertFalse(
            PhoneInputConfiguration.decode(fields(inactive), connection, PhoneOutputMode.MACOS_HID)
                .inputEnabled
        )
    }
}
