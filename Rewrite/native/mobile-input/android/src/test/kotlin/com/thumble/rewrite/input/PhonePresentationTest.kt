package com.thumble.rewrite.input

import java.util.ArrayDeque
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class PhonePresentationTest {
    private fun fixture() =
        JSONObject(
            checkNotNull(
                    javaClass.getResourceAsStream(
                        "/Fixtures/saved-controller-presentation-control-v10.json"
                    )
                )
                .bufferedReader()
                .use { it.readText() }
        )

    private fun request(): PhonePresentationRequest {
        val saved =
            SavedControllerRequest(
                "3",
                "a".repeat(64),
                "aaaaaaaa-0000-0000-0000-000000000001",
                "7",
                "2",
                "874",
                "393",
            )
        return PhonePresentationRequest(
            saved,
            SavedControllerMap(
                ControlMap(
                    generation = "7",
                    revision = "2",
                    controls =
                        listOf(
                            ControlRegion("synthetic-south", "south", 0.1, 0.2, 0.15, 0.3),
                            ControlRegion("synthetic-east", "east", 0.5, 0.2, 0.15, 0.3),
                        ),
                ),
                "b".repeat(64),
            ),
            "light",
        )
    }

    private fun decode(json: JSONObject) =
        PhonePresentationWire.metadata(
            EnrollmentJSON.parse(json.toString().toByteArray(), allowNull = true),
            request(),
            "synthetic-authority",
            "cd".repeat(16),
        )

    private fun reject(block: () -> Unit) {
        try {
            block()
            fail("invalid presentation admitted")
        } catch (_: PhonePresentationRejected) {}
    }

    @Test
    fun sharedMetadataIconAndNormalizedEventsAreStrictlyPinned() {
        val metadata = decode(fixture().getJSONObject("reply"))
        assertEquals("observed", metadata.freshness)
        assertEquals(2, metadata.controls.size)
        val icon =
            PhonePresentationWire.icon(
                EnrollmentJSON.parse(fixture().getJSONObject("iconReply").toString().toByteArray()),
                metadata,
                metadata.controls[0],
                "synthetic-authority",
                "cd".repeat(16),
            )
        assertEquals(104, icon.byteCount)
        assertEquals("presentation", metadata.bridgeEvent()["kind"])
        assertEquals("icon", icon.notification(metadata, "synthetic-south")["kind"])
        reject { icon.notification(metadata, "synthetic-east") }
        assertFalse(metadata.bridgeEvent().containsKey("viewportWidth"))
        assertFalse(metadata.bridgeEvent().containsKey("authorityInstanceId"))
    }

    @Test
    fun rejectsHostileMetadataAndAcceptsCosmeticOrderByID() {
        val changes =
            listOf(
                "generation" to "8",
                "expectedSourceHash" to "f".repeat(64),
                "configurationSha256" to "e".repeat(64),
                "viewportWidth" to "874.0",
                "profileId" to "wrong",
                "presentationRevision" to "2",
                "presentationSourceHash" to "bad",
                "colorScheme" to "dark",
                "freshness" to "live",
                "bank" to "shift",
                "controlCount" to 65,
                "control1Id" to "synthetic-south",
                "control0Label" to "x".repeat(129),
                "control0IconByteCount" to 8193,
                "control0IconName" to JSONObject.NULL,
                "source" to "private",
                "inputEnabled" to true,
            )
        changes.forEach { (key, value) ->
            reject { decode(fixture().getJSONObject("reply").put(key, value)) }
        }
        assertEquals(
            "😀".repeat(32),
            decode(fixture().getJSONObject("reply").put("control0Label", "😀".repeat(32)))
                .controls[0]
                .label,
        )
        reject { decode(fixture().getJSONObject("reply").put("control0Label", "😀".repeat(33))) }
        assertEquals(
            "line\nlabel",
            decode(fixture().getJSONObject("reply").put("control0Label", "line\nlabel"))
                .controls[0]
                .label,
        )
        val swapped = fixture().getJSONObject("reply")
        val all = listOf("Id", "Label", "IconSHA256", "IconByteCount", "IconName")
        all.forEach { suffix ->
            val a = swapped.opt("control0" + suffix)
            val b = swapped.opt("control1" + suffix)
            swapped.remove("control0" + suffix)
            swapped.remove("control1" + suffix)
            if (b != null) swapped.put("control0" + suffix, b)
            if (a != null) swapped.put("control1" + suffix, a)
        }
        assertEquals("synthetic-east", decode(swapped).controls[0].id)
        try {
            EnrollmentJSON.parse("{\"kind\":\"presentation\",\"kind\":\"icon\"}".toByteArray())
            fail("duplicate JSON admitted")
        } catch (_: PhoneEnrollmentRejected) {}
    }

    private class IO(values: List<JSONObject>, val before: (Int) -> Unit = {}) : NativeFrameIO {
        val values =
            ArrayDeque(
                values.map {
                    ControlTLSFrame(ControlTLSFrame.Kind.CONTROL, it.toString().toByteArray())
                }
            )
        val sent = mutableListOf<Map<String, EnrollmentJSON.Value>>()
        var closed = false

        override fun send(frame: ControlTLSFrame) {
            check(!closed)
            sent.add(EnrollmentJSON.parse(frame.payload))
        }

        override fun receive(): ControlTLSFrame {
            check(!closed)
            before(values.size)
            return values.removeFirst()
        }

        override fun close() {
            closed = true
        }
    }

    private fun setup(
        helloVersion: Int = 10,
        now: () -> Long = { 100 },
        load: (() -> Unit)? = null,
        before: (Int) -> Unit = {},
    ): Pair<PhonePresentationClient, IO> {
        val endpoint =
            TrustedHostEndpoint("127.0.0.1", 1234, "11".repeat(32), "synthetic-authority")
        val credential =
            PhoneCredential(
                PhoneCredentialMetadata(endpoint.certificatePin, "phone-a", 1, 100000),
                ByteArray(32) { 34 },
            )
        val hello =
            fixture()
                .getJSONObject("hello")
                .put("controlVersion", helloVersion)
                .put("authorityInstanceId", "synthetic-authority")
                .put("inputEnabled", false)
        val admitted =
            JSONObject()
                .put("version", 1)
                .put("command", "authenticated")
                .put("authorityInstanceId", "synthetic-authority")
                .put("phoneId", "phone-a")
                .put("credentialEpoch", "1")
                .put("connectionId", "cd".repeat(16))
                .put("expiresAt", 60100)
                .put("role", "management")
                .put("inputSessionAvailable", false)
                .put("inputEnabled", false)
        val io =
            IO(
                listOf(hello, admitted, fixture().getJSONObject("reply")) +
                    List(64) { fixture().getJSONObject("iconReply") },
                before,
            )
        return PhonePresentationClient(
            endpoint,
            { io },
            { _, _ ->
                load?.invoke()
                credential
            },
            now,
        ) to io
    }

    @Test
    fun reusableConnectionNeverGrantsInputAndClosesAtBatchEnd() {
        val (client, io) = setup()
        val metadata = client.read(request())
        assertFalse(io.closed)
        repeat(64) { assertEquals(104, client.icon(metadata.controls[0]).byteCount) }
        assertEquals(67, io.sent.size)
        assertEquals(EnrollmentJSON.Value.Integer(10), io.sent[0]["controlVersion"])
        assertTrue(io.sent.none { it["command"] == EnrollmentJSON.Value.Text("input-grant") })
        reject { client.icon(metadata.controls[0]) }
        assertTrue(io.closed)
        val (next, channel) = setup()
        next.read(request())
        next.close()
        assertTrue(channel.closed)
        reject { next.read(request()) }
    }

    @Test
    fun authorityValidationPrecedesCredentialLoadAndClockFailureClosesOnlyManagement() {
        var loads = 0
        val (old, channel) = setup(9, load = { loads++ })
        reject { old.read(request()) }
        assertEquals(0, loads)
        assertTrue(channel.closed)
        var time = 100L
        val (client, io) = setup(now = { time })
        val m = client.read(request())
        time = 99
        reject { client.icon(m.controls[0]) }
        assertTrue(io.closed)
        val (closed, c) = setup()
        closed.close()
        reject { closed.read(request()) }
        assertTrue(c.sent.isEmpty())
    }

    @Test
    fun fixedErrorsAndMalformedIconFailClosed() {
        fixture().getJSONArray("errors").let { errors ->
            for (i in 0 until errors.length()) {
                val code = errors.getString(i)
                val obj =
                    JSONObject()
                        .put("version", 1)
                        .put("command", "configuration-presentation-result")
                        .put("connectionId", "cd".repeat(16))
                        .put("kind", "error")
                        .put("error", code)
                try {
                    decode(obj)
                    fail("expected fixed error")
                } catch (e: PhonePresentationUnavailable) {
                    assertEquals(code, e.code)
                }
                reject { decode(obj.put("extra", true)) }
            }
        }
        val m = decode(fixture().getJSONObject("reply"))
        listOf(
                "iconSHA256" to "a".repeat(64),
                "controlId" to "synthetic-east",
                "presentationRevision" to "5",
                "byteCount" to 105,
                "pngBase64" to "AA==",
                "inputEnabled" to false,
            )
            .forEach { (k, v) ->
                reject {
                    PhonePresentationWire.icon(
                        EnrollmentJSON.parse(
                            fixture().getJSONObject("iconReply").put(k, v).toString().toByteArray()
                        ),
                        m,
                        m.controls[0],
                        "synthetic-authority",
                        "cd".repeat(16),
                    )
                }
            }
    }

    @Test
    fun cancellationAndConcurrentCallsCannotPublishOrOpenAnotherConnection() {
        lateinit var cancelled: PhonePresentationClient
        val pair = setup(before = { remaining -> if (remaining == 65) cancelled.close() })
        cancelled = pair.first
        reject { cancelled.read(request()) }
        assertTrue(pair.second.closed)
        lateinit var active: PhonePresentationClient
        var rejectedOverlap = false
        val concurrent =
            setup(
                before = { remaining ->
                    if (remaining == 65) {
                        reject { active.read(request()) }
                        rejectedOverlap = true
                    }
                }
            )
        active = concurrent.first
        assertEquals(2, active.read(request()).controls.size)
        assertTrue(rejectedOverlap)
        assertEquals(3, concurrent.second.sent.size)
        active.close()
    }

    @Test
    fun oversizedReplyAndExpiredLeaseCannotReturnCosmetics() {
        val (large, io) = setup()
        val frames = io.values.toMutableList()
        frames[2] = ControlTLSFrame(ControlTLSFrame.Kind.CONTROL, ByteArray(32769) { 32 })
        io.values.clear()
        io.values.addAll(frames)
        reject { large.read(request()) }
        assertTrue(io.closed)
        var time = 100L
        val (expired, channel) =
            setup(now = { time }, before = { remaining -> if (remaining == 65) time = 60100 })
        reject { expired.read(request()) }
        assertTrue(channel.closed)
    }
}
