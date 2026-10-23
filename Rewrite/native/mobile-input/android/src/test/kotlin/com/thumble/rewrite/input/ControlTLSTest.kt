package com.thumble.rewrite.input

import java.net.InetSocketAddress
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

class ControlTLSTest {
    private fun rejected(message: String = "accepted_invalid_transport", run: () -> Unit) {
        try {
            run()
            fail(message)
        } catch (_: ControlTLSRejected) {}
    }

    @Test
    fun frameShapeBoundsAndImmutablePayload() {
        val bytes = byteArrayOf(1, 2)
        val frame = ControlTLSFrame(ControlTLSFrame.Kind.CONTROL, bytes)
        bytes[0] = 9
        frame.payload[0] = 9
        assertArrayEquals(byteArrayOf(0, 0, 0, 3, 1, 1, 2), frame.encode())
        assertEquals(3, ControlTLSFrame.bodyLength(frame.encode().copyOfRange(0, 4)))
        assertArrayEquals(
            byteArrayOf(1, 2),
            ControlTLSFrame.decodeBody(frame.encode().copyOfRange(4, 7)).payload,
        )
        assertEquals(
            65541,
            ControlTLSFrame(ControlTLSFrame.Kind.CONTROL, ByteArray(65536)).encode().size,
        )
        for (prefix in
            listOf(
                byteArrayOf(),
                byteArrayOf(0, 0, 0, 0),
                byteArrayOf(0, 0, 0, 1),
                byteArrayOf(0, 1, 0, 2),
                ByteArray(4) { -1 },
            )) rejected { ControlTLSFrame.bodyLength(prefix) }
        for (body in
            listOf(
                byteArrayOf(),
                byteArrayOf(9, 1),
                byteArrayOf(1),
                byteArrayOf(2) + ByteArray(107),
                byteArrayOf(2) + ByteArray(109),
            )) rejected { ControlTLSFrame.decodeBody(body) }
    }

    @Test
    fun malformedPinsAndUnresolvedRoutesFailBeforeConnecting() {
        for (pin in listOf("", "0", "A".repeat(64))) rejected {
            ControlTLSClient.connect(InetSocketAddress("127.0.0.1", 1), pin)
        }
        rejected {
            ControlTLSClient.connect(
                InetSocketAddress.createUnresolved("invalid.local", 1),
                "0".repeat(64),
            )
        }
    }

    private fun probe(mode: String = "valid", run: (JSONObject) -> Unit) {
        val path = System.getenv("THUMBLE_NATIVE_TLS_PROBE")
        assumeTrue("native TLS probe not configured", path != null)
        val process = ProcessBuilder(path, mode).start()
        val watchdog =
            ScheduledThreadPoolExecutor(1) { r ->
                Thread(r, "tls-test-deadline").apply { isDaemon = true }
            }
        val timeout = watchdog.schedule({ process.destroyForcibly() }, 10, TimeUnit.SECONDS)
        try {
            val info = JSONObject(process.inputStream.bufferedReader().readLine())
            assertFalse(info.getBoolean("inputEnabled"))
            assertEquals("synthetic-loopback-only", info.getString("scope"))
            run(info)
        } finally {
            timeout.cancel(false)
            watchdog.shutdownNow()
            process.destroy()
            assertTrue(process.waitFor(10, TimeUnit.SECONDS))
        }
    }

    @Test
    fun actualJVMPlatformTLSExchangesNativeFramesAndEncryptedInput() = probe { info ->
        ControlTLSClient.connect(
                InetSocketAddress("127.0.0.1", info.getInt("port")),
                info.getString("pin"),
            )
            .use { client ->
                client.send(
                    ControlTLSFrame(
                        ControlTLSFrame.Kind.CONTROL,
                        "actual-jvm-native-control".toByteArray(),
                    )
                )
                assertEquals(
                    "actual-jvm-native-control",
                    client.receive().payload.toString(Charsets.UTF_8),
                )
                val fixture =
                    JSONObject(
                        requireNotNull(
                                javaClass.classLoader?.getResourceAsStream("input-packet-v1.json")
                            )
                            .bufferedReader()
                            .use { it.readText() }
                    )
                for ((index, accepted) in listOf(0 to true, 1 to true, 1 to false)) {
                    val vector = fixture.getJSONArray("vectors").getJSONObject(index)
                    val packet =
                        vector
                            .getString("packetHex")
                            .chunked(2)
                            .map { it.toInt(16).toByte() }
                            .toByteArray()
                    client.send(ControlTLSFrame(ControlTLSFrame.Kind.INPUT, packet))
                    val result = JSONObject(client.receive().payload.toString(Charsets.UTF_8))
                    assertEquals(accepted, result.getBoolean("ok"))
                    assertFalse(result.getJSONObject("snapshot").getBoolean("inputEnabled"))
                    assertEquals(
                        vector.getString("reportHex"),
                        result.getJSONObject("snapshot").getString("reportHex"),
                    )
                    if (!accepted) assertEquals("input_packet_rejected", result.getString("error"))
                }
            }
    }

    @Test
    fun actualJVMPlatformTLSRejectsWrongPinBeforeControl() = probe { info ->
        rejected {
            ControlTLSClient.connect(
                InetSocketAddress("127.0.0.1", info.getInt("port")),
                "0".repeat(64),
            )
        }
    }

    @Test
    fun actualJVMPlatformPinDoesNotBypassCertificatePolicy() {
        for (mode in listOf("expired", "future", "wrong-name", "client-usage")) probe(mode) { info
            ->
            rejected(mode) {
                ControlTLSClient.connect(
                    InetSocketAddress("127.0.0.1", info.getInt("port")),
                    info.getString("pin"),
                )
            }
        }
    }
}
