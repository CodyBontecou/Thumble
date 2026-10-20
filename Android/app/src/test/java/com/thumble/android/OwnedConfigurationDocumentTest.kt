package com.thumble.android

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class OwnedConfigurationDocumentTest {
    private fun fixture(name: String) = javaClass.classLoader!!.getResourceAsStream("owned-configuration/v1/$name.json")!!.use { it.readBytes() }
    @Test fun sharedVersionFiveContractAndRejectedMutations() {
        val original = fixture("document")
        val rows = JSONObject(fixture("cases").toString(Charsets.UTF_8)).getJSONArray("cases")
        repeat(rows.length()) { index ->
            val row = rows.getJSONObject(index)
            val candidate = JSONObject(original.toString(Charsets.UTF_8))
            val path = row.getJSONArray("path")
            if (path.length() > 0) {
                var target: Any = candidate
                repeat(path.length()-1) { i ->
                    target = if (target is JSONArray) (target as JSONArray).get(path.getInt(i)) else (target as JSONObject).get(path.getString(i))
                }
                val key = path.getString(path.length()-1)
                if (row.getString("action") == "remove") (target as JSONObject).remove(key)
                else (target as JSONObject).put(key,row.get("value"))
            }
            assertEquals(row.getString("name"),row.getBoolean("allowed"),runCatching {
                OwnedConfigurationDocument.decode(candidate.toString().toByteArray(Charsets.UTF_8))
            }.isSuccess)
        }
    }
    @Test fun exactSourceAllStatesAndResourceBytesSurviveDetachedProjections() {
        val bytes = fixture("document")
        val document = OwnedConfigurationDocument.decode(bytes)
        assertArrayEquals(bytes,document.originalData())
        val profile = document.projectedProfiles().first()
        assertEquals(2,document.projectedProfiles().size)
        assertEquals(profile.id,document.activeProfileID)
        assertEquals(document.projectedProfiles().last().id,document.defaultProfileID)
        val repository = SkinRenderRepository { error("V5 reader must not consult a package") }
        for (scheme in ProfileAppearanceBank.schemes) for (action in ProfileAppearanceBank.actions) {
            val projection = repository.resolve(profile,true,scheme=="dark",action)
            assertNull(projection.warning)
            val layout = projection.profile!!.layout(true)
            val element = layout.getJSONArray("elements").getJSONObject(0)
            assertEquals("$scheme/$action",element.getJSONObject("layout").getJSONObject("icon").getString("value"))
            assertEquals("Zml4dHVyZS1pbWFnZQ==",layout.getJSONObject("assetLibrary").getJSONArray("assets").getJSONObject(0).getString("data"))
        }
        profile.source.remove("appearanceBank")
        assertNotNull(document.projectedProfiles().first().source.getJSONObject("appearanceBank"))
        assertArrayEquals(bytes,document.originalData())
        assertEquals(listOf(4),ProfileFramePolicy.supportedFormats)
    }
    @Test fun projectionPreservesNamesBeyondLegacyDisplayLimit() {
        val source = JSONObject(fixture("document").toString(Charsets.UTF_8))
        val name = "n".repeat(200)
        source.getJSONArray("profiles").getJSONObject(0).put("name",name)
        val bytes = source.toString().toByteArray(Charsets.UTF_8)
        val document = OwnedConfigurationDocument.decode(bytes)
        assertEquals(name,document.projectedProfiles().first().name)
        assertArrayEquals(bytes,document.originalData())
    }
    @Test fun duplicateKeysInvalidUTF8AndCompleteDocumentOverflowAreRejected() {
        val bytes = fixture("document")
        val duplicate = bytes.toString(Charsets.UTF_8).replace("\"version\": 5","\"version\": 5, \"version\": 4")
        assertTrue(runCatching { OwnedConfigurationDocument.decode(duplicate.toByteArray()) }.isFailure)
        assertTrue(runCatching { OwnedConfigurationDocument.decode(byteArrayOf(255.toByte())) }.isFailure)
        val maximum = ByteArray(WireCodec.MAX_PAYLOAD) { 32 }.also { bytes.copyInto(it) }
        assertArrayEquals(maximum,OwnedConfigurationDocument.decode(maximum).originalData())
        assertTrue(runCatching { OwnedConfigurationDocument.decode(maximum + byteArrayOf(32)) }.isFailure)
    }
}
