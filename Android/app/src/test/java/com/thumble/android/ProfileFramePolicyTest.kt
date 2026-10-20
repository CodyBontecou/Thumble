package com.thumble.android

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ProfileFramePolicyTest {
    private fun fixture() = javaClass.classLoader!!.getResourceAsStream("profile-formats/v1.json")!!.use { JSONObject(it.bufferedReader().readText()) }
    @Test fun sharedNegotiationAndIncomingFrameMatrix() {
        val fixture = fixture()
        for (row in AppearanceJSON.objects(fixture.getJSONArray("negotiations"))) {
            val offered = row.optJSONArray("offered")?.let { array -> (0 until array.length()).map { array.getInt(it) } }
            assertEquals(row.getString("name"), row.getBoolean("allowed"), runCatching { ProfileFramePolicy.negotiate(row.getInt("required"), offered) }.isSuccess)
        }
        for (row in AppearanceJSON.objects(fixture.getJSONArray("frames")))
            assertEquals(row.getString("name"), row.getBoolean("allowed"), runCatching { ProfileFramePolicy.validateIncoming(row.getJSONObject("message")) }.isSuccess)
        assertEquals(listOf(4), ProfileFramePolicy.supportedFormats)
        assertEquals(listOf(4), ProfileFramePolicy.advertise(WireCodec.message("hello")).getJSONArray("supportedProfileFormats").let { (0 until it.length()).map(it::getInt) })
    }
    @Test fun duplicateTagsMalformedUTF8AndFutureStoredProfilesNeverBecomeLegacyData() {
        for (raw in listOf(
            """{"type":"gamepad_profiles","profileFormatVersion":5,"profileFormatVersion":4,"gamepadProfiles":[]}""",
            """{"type":"gamepad_profiles","gamepadProfiles":[{"profileFormatVersion":5,"profileFormatVersion":4}]}"""
        )) assertTrue(runCatching { WireCodec.decode(raw.toByteArray()) }.isFailure)
        assertTrue(runCatching { WireCodec.decode(byteArrayOf(123, 34, 120, 34, 58, 34, 0xC0.toByte(), 0xAF.toByte(), 34, 125)) }.isFailure)
        val source = JSONObject("""{"id":"ca000000-0000-0000-0000-000000000001","profileFormatVersion":5,"customization":{}}""")
        val before = source.toString()
        assertTrue(runCatching { ControllerProfile.parse(source) }.isFailure)
        assertEquals(before, source.toString())
    }
}
