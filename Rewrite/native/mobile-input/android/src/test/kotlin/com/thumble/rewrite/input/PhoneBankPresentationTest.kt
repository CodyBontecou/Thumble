package com.thumble.rewrite.input

import com.thumble.rewrite.contracts.GamepadStateV1
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class PhoneBankPresentationTest {
    private fun fixture() =
        JSONObject(
            checkNotNull(
                    javaClass.getResourceAsStream(
                        "/Fixtures/saved-controller-presentation-control-v11.json"
                    )
                )
                .bufferedReader()
                .use { it.readText() }
        )

    private fun request(fields: JSONObject): PhonePresentationRequest =
        PhonePresentationRequest(
            SavedControllerRequest(
                "3",
                "a".repeat(64),
                "aaaaaaaa-0000-0000-0000-000000000001",
                "7",
                "2",
                "874",
                "393",
            ),
            SavedControllerMap(
                ControlMap(
                    generation = "7",
                    revision = "2",
                    controls =
                        listOf(
                            ControlRegion("synthetic-south", "south", .1, .2, .15, .3),
                            ControlRegion("synthetic-east", "east", .5, .2, .15, .3),
                        ),
                ),
                "b".repeat(64),
            ),
            fields.getString("colorScheme"),
            PhonePresentationBank.entries.single { it.wire == fields.getString("bank") },
        )

    private fun fields(value: JSONObject) = EnrollmentJSON.parse(value.toString().toByteArray())

    private fun rejected(block: () -> Unit) {
        try {
            block()
            fail("bank_cross_context_admitted")
        } catch (_: PhonePresentationRejected) {}
    }

    @Test
    fun allEightBankThemeVariantsKeepFullPinsAndVerifiedImages() {
        val variants = fixture().getJSONArray("variants")
        assertEquals(8, variants.length())
        val hashes = mutableSetOf<String>()
        for (i in 0 until variants.length()) {
            val variant = variants.getJSONObject(i)
            val requested = variant.getJSONObject("request")
            val request = request(requested)
            assertEquals(fields(requested), fields(request.fields("cd".repeat(16))))
            val metadata =
                PhonePresentationWire.metadata(
                    fields(variant.getJSONObject("reply")),
                    request,
                    "synthetic-authority",
                    "cd".repeat(16),
                )
            val event = metadata.bridgeEvent()
            assertEquals(2, event["presentationProtocol"])
            assertEquals("synthetic-authority", event["authorityInstanceId"])
            assertEquals(request.bank!!.wire, event["bank"])
            assertEquals("874", event["viewportWidth"])
            assertEquals("393", event["viewportHeight"])
            val selection = request.bankNotification("synthetic-authority")
            assertEquals("bank", selection["kind"])
            assertFalse(selection.containsKey("presentationRevision"))
            val icon =
                PhonePresentationWire.icon(
                    fields(variant.getJSONObject("iconReply")),
                    metadata,
                    metadata.controls[0],
                    "synthetic-authority",
                    "cd".repeat(16),
                )
            hashes.add(icon.sha256)
            val iconEvent = icon.notification(metadata, "synthetic-south")
            assertEquals(request.bank!!.wire, iconEvent["bank"])
            assertEquals("synthetic-authority", iconEvent["authorityInstanceId"])
            assertFalse(iconEvent.containsKey("profileName"))
        }
        assertEquals(8, hashes.size)
    }

    @Test
    fun crossBankAuthorityViewportEpochAndProtocolDowngradeReject() {
        val fixture = fixture()
        val request = request(fixture.getJSONObject("request"))
        for (fault in
            listOf("version", "bank", "missing-bank", "authority", "viewport", "epoch", "extra")) {
            val reply = JSONObject(fixture.getJSONObject("reply").toString())
            when (fault) {
                "version" -> reply.put("version", 1)
                "bank" -> reply.put("bank", "left-trigger")
                "missing-bank" -> reply.remove("bank")
                "authority" -> reply.put("authorityInstanceId", "other-authority")
                "viewport" -> reply.put("viewportWidth", "874.0")
                "epoch" -> reply.put("generation", "8")
                else -> reply.put("unknown", true)
            }
            rejected {
                PhonePresentationWire.metadata(
                    fields(reply),
                    request,
                    "synthetic-authority",
                    "cd".repeat(16),
                )
            }
        }
    }

    @Test
    fun semanticHalfBoundaryIsNotSelectedByWireRounding() {
        fun state(left: Double, right: Double) =
            GamepadStateV1(emptyList(), 0.0, 0.0, 0.0, 0.0, left, right)
        assertEquals(PhonePresentationBank.BASE, PhonePresentationBank.accepted(state(.5, .5)))
        assertEquals(
            PhonePresentationBank.LEFT_TRIGGER,
            PhonePresentationBank.accepted(state(.500001, .5)),
        )
        assertEquals(
            PhonePresentationBank.RIGHT_TRIGGER,
            PhonePresentationBank.accepted(state(.5, .500001)),
        )
        assertEquals(
            PhonePresentationBank.BOTH_TRIGGERS,
            PhonePresentationBank.accepted(state(1.0, 1.0)),
        )
        assertEquals(PhonePresentationBank.BASE, PhonePresentationBank.accepted(state(0.0, 0.0)))
    }
}
