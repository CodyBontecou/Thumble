package com.thumble.rewrite.input

import java.util.ArrayDeque
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class SavedControllerTest {
    private fun fixture() =
        JSONObject(
            checkNotNull(
                    javaClass.getResourceAsStream("/Fixtures/saved-controller-control-v8.json")
                )
                .bufferedReader()
                .use { it.readText() }
        )

    private fun request() =
        SavedControllerRequest(
            "3",
            "a".repeat(64),
            "aaaaaaaa-0000-0000-0000-000000000001",
            "7",
            "2",
            "874",
            "393",
        )

    private fun decode(fields: JSONObject) =
        SavedControllerWire.decode(
            EnrollmentJSON.parse(fields.toString().toByteArray()),
            request(),
            "synthetic-authority",
            "cd".repeat(16),
        )

    private fun rejected(block: () -> Unit) {
        try {
            block()
            fail("invalid saved controller admitted")
        } catch (_: SavedControllerRejected) {}
    }

    @Test
    fun sharedFixturePreservesControlsAndOptionalHaptics() {
        val result = decode(fixture().getJSONObject("reply"))
        assertEquals(2, result.map.controls.size)
        assertEquals("synthetic-south", result.map.controls[0].id)
        assertEquals(0.1, result.map.controls[0].x, 0.0)
        assertEquals(0.5, result.map.controls[0].hapticFeedback!!.intensity, 0.0)
        assertNull(result.map.controls[1].hapticFeedback)
        assertEquals("b".repeat(64), result.configurationSha256)
        assertTrue(result.bridgeMap["controls"] is List<*>)
    }

    @Test
    fun rejectsStalePinsMalformedNumbersUnknownFieldsAndPartialHaptics() {
        val changes =
            listOf(
                "connectionId" to "ff",
                "authorityInstanceId" to "other",
                "configurationRevision" to "4",
                "sourceHash" to "b".repeat(64),
                "profileId" to "wrong",
                "generation" to "8",
                "revision" to "3",
                "viewportWidth" to "874.0",
                "configurationSha256" to "invalid",
                "controlCount" to 0,
                "controlCount" to 65,
                "control1Id" to "synthetic-south",
                "control0Action" to "arbitrary",
                "control0X" to "-0",
                "control0X" to "01",
                "control0X" to "1E-1",
                "control0X" to "1e9999",
                "control0X" to "0.1\n",
                "control0X" to "NaN",
                "control0Width" to "1.1",
                "control0HapticDuration" to "0.301",
                "control0HapticStyle" to "unknown",
                "control0HapticPattern" to null,
                "extra" to "field",
            )
        changes.forEach { (key, value) ->
            val fields = fixture().getJSONObject("reply")
            if (value == null) fields.remove(key) else fields.put(key, value)
            rejected { decode(fields) }
        }
        rejected {
            decode(
                fixture()
                    .getJSONObject("reply")
                    .put("control0HapticStyle", "none")
                    .put("control0HapticIntensity", "2")
            )
        }
        try {
            EnrollmentJSON.parse("{\"version\":1,\"version\":1}".toByteArray())
            fail("duplicate key admitted")
        } catch (_: PhoneEnrollmentRejected) {}
    }

    @Test
    fun boundedNumericGrammarAndFixedErrors() {
        assertEquals(0.1, SavedControllerWire.number("1e-1")!!, 0.0)
        listOf("-1", "+1", ".1", "1.", "1E2", "1e999", "١", "1".repeat(33)).forEach {
            assertNull(SavedControllerWire.number(it))
        }
        rejected {
            SavedControllerRequest(
                "3",
                "a".repeat(64),
                "aaaaaaaa-0000-0000-0000-000000000001",
                "7",
                "2",
                "393",
                "874",
            )
        }
        val errors = fixture().getJSONArray("errors")
        for (index in 0 until errors.length()) {
            val error = errors.getJSONObject(index)
            try {
                decode(error)
                fail("error result admitted")
            } catch (failure: SavedControllerUnavailable) {
                assertEquals(error.getString("error"), failure.code)
            }
        }
    }

    private class IO(fields: List<JSONObject>) : NativeFrameIO {
        val frames =
            ArrayDeque(
                fields.map {
                    ControlTLSFrame(ControlTLSFrame.Kind.CONTROL, it.toString().toByteArray())
                }
            )
        val sent = mutableListOf<Map<String, EnrollmentJSON.Value>>()
        var closed = false

        override fun send(frame: ControlTLSFrame) {
            check(!closed)
            sent += EnrollmentJSON.parse(frame.payload)
        }

        override fun receive(): ControlTLSFrame {
            check(!closed)
            return frames.removeFirst()
        }

        override fun close() {
            closed = true
        }
    }

    private fun setup(version: Int = 8): Pair<SavedControllerClient, IO> {
        val authority = "synthetic-authority"
        val endpoint = TrustedHostEndpoint("127.0.0.1", 1234, "11".repeat(32), authority)
        val credential =
            PhoneCredential(
                PhoneCredentialMetadata(endpoint.certificatePin, "phone-a", 1, 100000),
                ByteArray(32) { 34 },
            )
        val io =
            IO(
                listOf(
                    JSONObject()
                        .put("version", 1)
                        .put("command", "hello")
                        .put("authorityInstanceId", authority)
                        .put("controlVersion", version)
                        .put("role", "management")
                        .put("inputVersion", 1)
                        .put("documentVersion", 1)
                        .put("capabilitiesVersion", 1)
                        .put("inputEnabled", false),
                    JSONObject()
                        .put("version", 1)
                        .put("command", "authenticated")
                        .put("authorityInstanceId", authority)
                        .put("phoneId", "phone-a")
                        .put("credentialEpoch", "1")
                        .put("connectionId", "cd".repeat(16))
                        .put("expiresAt", 60100)
                        .put("role", "management")
                        .put("inputSessionAvailable", false)
                        .put("inputEnabled", false),
                    fixture().getJSONObject("reply"),
                )
            )
        return SavedControllerClient(endpoint, { io }, { _, _ -> credential }, { 100 }) to io
    }

    @Test
    fun separateReadOnlyV8ClientClosesAfterOneReadAndRejectsOldVersion() {
        val (client, io) = setup()
        assertEquals(2, client.read(request()).map.controls.size)
        assertTrue(io.closed)
        assertEquals(3, io.sent.size)
        assertEquals(EnrollmentJSON.Value.Integer(8), io.sent.first()["controlVersion"])
        assertEquals(EnrollmentJSON.Value.Text("configuration-controls"), io.sent.last()["command"])
        rejected { client.read(request()) }
        val (old, oldIO) = setup(7)
        rejected { old.read(request()) }
        assertTrue(oldIO.closed)
        assertEquals(1, oldIO.sent.size)
    }

    @Test
    fun maximumMapAndExactFrameBoundaryRemainBounded() {
        val fields = fixture().getJSONObject("reply")
        fields
            .keys()
            .asSequence()
            .filter { it.startsWith("control") }
            .toList()
            .forEach { fields.remove(it) }
        fields.put("controlCount", 64)
        for (index in 0 until 64) {
            val prefix = "control$index"
            fields
                .put(prefix + "Id", "synthetic-$index")
                .put(prefix + "Action", "south")
                .put(prefix + "X", "0.1")
                .put(prefix + "Y", "0.2")
                .put(prefix + "Width", "0.15")
                .put(prefix + "Height", "0.3")
                .put(prefix + "HapticStyle", "light")
                .put(prefix + "HapticPattern", "single")
                .put(prefix + "HapticIntensity", "0.5")
                .put(prefix + "HapticSharpness", "0.4")
                .put(prefix + "HapticDuration", "0.06")
        }
        val source = fields.toString().toByteArray()
        assertTrue(source.size <= 65536)
        val bytes = ByteArray(65536) { 32 }
        source.copyInto(bytes)
        val frame = ControlTLSFrame(ControlTLSFrame.Kind.CONTROL, bytes)
        val map =
            SavedControllerWire.decode(
                EnrollmentJSON.parse(frame.payload),
                request(),
                "synthetic-authority",
                "cd".repeat(16),
            )
        assertEquals(64, map.map.controls.size)
        map.map.validated()
        try {
            ControlTLSFrame(ControlTLSFrame.Kind.CONTROL, bytes + 32.toByte())
            fail("oversizedframeadmitted")
        } catch (_: ControlTLSRejected) {}
        try {
            EnrollmentJSON.parse(bytes + 32.toByte())
            fail("oversizedJSONadmitted")
        } catch (_: PhoneEnrollmentRejected) {}
        val (closed, io) = setup()
        closed.close()
        rejected { closed.read(request()) }
        assertTrue(io.sent.isEmpty())
    }
}
