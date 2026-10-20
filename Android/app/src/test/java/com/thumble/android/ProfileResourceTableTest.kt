package com.thumble.android

import java.nio.ReadOnlyBufferException
import java.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import org.erdtman.jcs.JsonCanonicalizer
import org.junit.Assert.*
import org.junit.Test

class ProfileResourceTableTest {
    private fun assertSameJSON(expected: Any, actual: Any) = assertEquals(
        JsonCanonicalizer(expected.toString()).encodedString, JsonCanonicalizer(actual.toString()).encodedString)
    private fun fixture() = javaClass.classLoader!!.getResourceAsStream("profile-resources/v1/fixture.json")!!
        .use { JSONObject(it.bufferedReader().readText()) }

    private fun expanded(value: Any, table: ProfileResourceTable): Any = when (value) {
        is JSONObject -> if (value.has("resourceSHA256")) {
            val buffer = table.data(value)
            val bytes = ByteArray(buffer.remaining()).also(buffer::get)
            Base64.getEncoder().encodeToString(bytes)
        } else JSONObject().also { result ->
            value.keys().asSequence().filter { it !in setOf("appearanceResources", "appearanceResourceVersion") }
                .forEach { result.put(it, expanded(value.get(it), table)) }
        }
        is JSONArray -> JSONArray().also { result -> repeat(value.length()) { result.put(expanded(value.get(it), table)) } }
        else -> value
    }

    @Test fun nativeFixtureExpandsExactlyAndDataReadersCannotMutateThePool() {
        val fixture = fixture()
        val profile = fixture.getJSONObject("pooledProfile")
        val before = profile.toString()
        val table = ProfileResourceTable.fromProfile(profile)!!
        assertSameJSON(fixture.getJSONObject("expandedProfile"), expanded(profile, table))
        assertEquals(before, profile.toString())
        val reference = profile.getJSONObject("customization").getJSONObject("assetLibrary").getJSONArray("assets")
            .getJSONObject(0).getJSONObject("data")
        val bytes = table.data(reference)
        assertTrue(bytes.isReadOnly)
        assertThrows(ReadOnlyBufferException::class.java) { bytes.put(0, 0.toByte()) }
        val copy = ByteArray(bytes.remaining()).also(bytes::get)
        assertArrayEquals("fixture-image".toByteArray(), copy)
        assertEquals('f'.code.toByte(), table.data(reference).get(0))
    }

    @Test fun pruningPortableCopyRemovesLocalOnlyBytesAndRetainsUnknownFields() {
        val fixture = fixture()
        val profile = fixture.getJSONObject("pooledProfile")
        val table = ProfileResourceTable.fromProfile(profile)!!
        val stripped = JSONObject(profile.toString()).apply { remove("launchTarget") }
        assertSameJSON(fixture.getJSONObject("portableProfile"), table.pruningUnused(stripped))
        stripped.put("futureMigrationMetadata", JSONObject().put("untouched", JSONArray().put(1).put("data")))
        val pruned = table.pruningUnused(stripped)
        assertSameJSON(stripped.getJSONObject("futureMigrationMetadata"), pruned.getJSONObject("futureMigrationMetadata"))
        assertEquals(2, stripped.getJSONObject("appearanceResources").length())
        assertEquals(1, pruned.getJSONObject("appearanceResources").length())
        stripped.put("futureMigrationMetadata", JSONObject().put("resource", profile.getJSONObject("launchTarget").getJSONObject("bookmarkData")))
        val retained = table.pruningUnused(stripped)
        assertSameJSON(stripped.getJSONObject("futureMigrationMetadata"), retained.getJSONObject("futureMigrationMetadata"))
        assertEquals(2, retained.getJSONObject("appearanceResources").length())
    }

    @Test fun corruptMissingAndMalformedReferencesNeverTurnIntoEmptyImages() {
        val original = fixture().getJSONObject("pooledProfile")
        for (version in listOf(99, "1", JSONObject.NULL)) {
            val profile = JSONObject(original.toString()).put("appearanceResourceVersion", version)
            assertThrows(IllegalArgumentException::class.java) { ProfileResourceTable.fromProfile(profile) }
        }
        val digest = original.getJSONObject("appearanceResources").keys().next()
        val corrupt = JSONObject(original.toString()).apply {
            getJSONObject("appearanceResources").put(digest, Base64.getEncoder().encodeToString("corrupt".toByteArray()))
        }
        assertThrows(IllegalArgumentException::class.java) { ProfileResourceTable.fromProfile(corrupt) }
        val missing = JSONObject(original.toString()).put("appearanceResources", JSONObject())
        assertThrows(IllegalArgumentException::class.java) { ProfileResourceTable.fromProfile(missing) }
        val malformed = JSONObject(original.toString()).apply {
            getJSONObject("customization").getJSONObject("assetLibrary").getJSONArray("assets")
                .getJSONObject(0).getJSONObject("data").put("extra", true)
        }
        assertThrows(IllegalArgumentException::class.java) { ProfileResourceTable.fromProfile(malformed) }
        val unmarked = JSONObject(original.toString()).apply { remove("appearanceResourceVersion") }
        assertThrows(IllegalArgumentException::class.java) { ProfileResourceTable.fromProfile(unmarked) }
        assertNotNull(ProfileResourceTable.fromProfile(JSONObject(original.toString()).put("appearanceResourceVersion", 1.0)))
    }

    @Test fun legacyProfilesDoNotRequireResourceMarkers() {
        assertNull(ProfileResourceTable.fromProfile(fixture().getJSONObject("expandedProfile")))
    }
}
