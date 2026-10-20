package com.thumble.android

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.Base64

/** Frozen migration inputs remain independent of the removable skin test suite. */
class FeatureRemovalBaselineTest {
    private fun fixture(name: String) = javaClass.classLoader!!
        .getResourceAsStream("feature-removal/v1/$name.json")!!.use { JSONObject(it.bufferedReader().readText()) }

    @Test fun migrationInputsKeepUnknownFieldsAndUnresolvedSkinReferences() {
        val rows = fixture("migration-cases").getJSONArray("cases")
        assertEquals(3, rows.length())
        repeat(rows.length()) { index ->
            val row = rows.getJSONObject(index)
            val source = row.getJSONObject("profile")
            val parsed = ControllerProfile.parse(source)
            assertTrue(sameSkinJSON(source, parsed.source))
            assertEquals(7, parsed.source.getJSONObject("futureMigrationMetadata").getInt("version"))
            if (row.getString("name") == "missing-package") {
                assertEquals("99.0.0", parsed.source.getJSONObject("skinReference").getString("version"))
                assertEquals("recovery-required", row.getString("expectedDisposition"))
            }
        }
    }

    @Test fun frozenAppearanceMatchesSwiftWithoutChangingInput() {
        val fixture = fixture("appearance")
        val payloads = fixture.getJSONObject("assetPayloads")
        val packageValue = SkinPackage(byteArrayOf(), fixture.getJSONObject("manifest"), fixture.getJSONObject("skin"), null,
            payloads.keys().asSequence().associateWith { Base64.getDecoder().decode(payloads.getString(it)) }, emptyMap())
        val profiles = fixture.getJSONObject("profiles")
        val rows = fixture.getJSONArray("cases")
        assertEquals(10, rows.length())
        repeat(rows.length()) { index ->
            val row = rows.getJSONObject(index)
            val local = profiles.getJSONObject(row.getString("profile"))
            val before = local.toString()
            val baseline = row.optString("baseline").takeIf { it.isNotEmpty() }?.let(profiles::getJSONObject)
            val actual = SkinProfileResolver.apply(packageValue, local, row.getString("orientation"), row.getString("scheme"), true, baseline)
            assertTrue("Frozen appearance $index", sameSkinJSON(row.getJSONObject("expected"), actual.customization))
            assertEquals("Source layout must remain intact", before, local.toString())
            val originalElements = local.getJSONArray("elements")
            val actualElements = actual.customization.getJSONArray("elements")
            assertEquals(originalElements.length(), actualElements.length())
            repeat(originalElements.length()) { element ->
                for (key in listOf("id", "output", "partOutputs", "joystickMapping", "triggerSettings", "trackpadSettings")) {
                    assertTrue("Input $index/$element/$key", sameSkinJSON(
                        originalElements.getJSONObject(element).opt(key), actualElements.getJSONObject(element).opt(key)))
                }
            }
        }
    }

    @Test fun legacyProfilesKeepTheirIdentitiesAndOrientationVariants() {
        val rows = fixture("legacy-profiles").getJSONArray("cases")
        assertEquals(4, rows.length())
        repeat(rows.length()) { index ->
            val row = rows.getJSONObject(index)
            val input = ControllerProfile.parse(row.getJSONObject("input"))
            val expected = ControllerProfile.parse(row.getJSONObject("expected"))
            assertEquals(input.id, expected.id)
            assertEquals(input.name, expected.name)
            for (landscape in listOf(true, false)) {
                val original = input.layout(landscape).getJSONArray("elements")
                val converted = expected.layout(landscape).getJSONArray("elements")
                assertEquals(original.length(), converted.length())
                repeat(original.length()) { element ->
                    for (key in listOf("id", "output", "partOutputs")) {
                        assertTrue(sameSkinJSON(original.getJSONObject(element).opt(key), converted.getJSONObject(element).opt(key)))
                    }
                }
            }
        }
    }
}
