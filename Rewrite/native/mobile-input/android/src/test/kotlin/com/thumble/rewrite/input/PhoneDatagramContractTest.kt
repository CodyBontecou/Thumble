package com.thumble.rewrite.input

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class PhoneDatagramContractTest {
    private val binding = "ab".repeat(16)
    private val session = "33".repeat(16)
    private val map = ControlMap(generation = "1", revision = "1", controls = emptyList())

    private fun fixture(name: String): Map<String, EnrollmentJSON.Value> =
        javaClass.classLoader!!.getResourceAsStream("native-input-control-v5.json")!!.use {
            val value = JSONObject(it.readBytes().toString(Charsets.UTF_8)).getJSONObject(name)
            EnrollmentJSON.parse(value.toString().toByteArray(), allowNull = true)
        }

    private fun rejected(block: () -> Unit) {
        try {
            block()
            fail("accepted invalid native contract")
        } catch (_: PhoneControlRejected) {}
    }

    @Test
    fun grantRequiresExplicitVersionAndBoundPort() {
        val value = fixture("grant")
        rejected { PhoneInputGrant(value, binding, map) }
        val grant = PhoneInputGrant(value, binding, map, datagrams = true)
        assertEquals(43210, grant.udpPort)
        assertEquals(session, grant.sessionID)
        for (port in
            listOf(
                EnrollmentJSON.Value.Integer(0),
                EnrollmentJSON.Value.Integer(65536),
                EnrollmentJSON.Value.Text("43210"),
                EnrollmentJSON.Value.Null,
            )) {
            rejected { PhoneInputGrant(value + ("udpPort" to port), binding, map, true) }
        }
        for (field in listOf("udpPort", "connectionId", "generation", "key")) {
            rejected { PhoneInputGrant(value - field, binding, map, true) }
        }
    }

    @Test
    fun progressCannotAcknowledgeUnsentOrRegress() {
        val initial = fixture("progress")
        assertNull(PhoneInputProgress(initial, binding, session, map, null, null).lastAccepted)
        val value = initial + ("lastAcceptedSequence" to EnrollmentJSON.Value.Text("7"))
        assertEquals(7uL, PhoneInputProgress(value, binding, session, map, 8uL, 6uL).lastAccepted)
        for ((offered, previous) in listOf(6uL to 6uL, null to null, 8uL to 8uL)) {
            rejected { PhoneInputProgress(value, binding, session, map, offered, previous) }
        }
        for (sequence in
            listOf(
                EnrollmentJSON.Value.Text("07"),
                EnrollmentJSON.Value.Text("1048576"),
                EnrollmentJSON.Value.Integer(7),
                EnrollmentJSON.Value.Null,
            )) {
            rejected {
                PhoneInputProgress(
                    initial + ("lastAcceptedSequence" to sequence),
                    binding,
                    session,
                    map,
                    8uL,
                    6uL,
                )
            }
        }
    }

    @Test
    fun progressRejectsWrongScopeAndPreservesTerminalStatus() {
        val initial = fixture("progress")
        for ((field, value) in
            listOf(
                "connectionId" to EnrollmentJSON.Value.Text("cd".repeat(16)),
                "sessionId" to EnrollmentJSON.Value.Text("44".repeat(16)),
                "generation" to EnrollmentJSON.Value.Text("2"),
                "revision" to EnrollmentJSON.Value.Text("2"),
                "inputEnabled" to EnrollmentJSON.Value.BooleanValue(true),
                "extra" to EnrollmentJSON.Value.BooleanValue(false),
            )) {
            rejected {
                PhoneInputProgress(initial + (field to value), binding, session, map, null, null)
            }
        }
        assertFalse(
            PhoneInputProgress(
                    initial + ("active" to EnrollmentJSON.Value.BooleanValue(false)),
                    binding,
                    session,
                    map,
                    null,
                    null,
                )
                .active
        )
    }

    @Test
    fun nullRequiresParserOptInAndDuplicateKeysStillFail() {
        val data = "{\"value\":null}".toByteArray()
        try {
            EnrollmentJSON.parse(data)
            fail("null accepted without opt-in")
        } catch (_: PhoneEnrollmentRejected) {}
        assertEquals(EnrollmentJSON.Value.Null, EnrollmentJSON.parse(data, true)["value"])
        try {
            EnrollmentJSON.parse("{\"value\":null,\"value\":null}".toByteArray(), true)
            fail("duplicate accepted")
        } catch (_: PhoneEnrollmentRejected) {}
    }
}
