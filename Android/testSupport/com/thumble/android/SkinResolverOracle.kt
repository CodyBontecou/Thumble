package com.thumble.android

import org.json.JSONObject
import org.junit.Assert.*
import java.util.Base64
import java.util.UUID

internal class SkinResolverOracle(private val load: () -> JSONObject) {
    private fun fixture() = load()
    fun allNativeOrientationSchemeActionSetAndControlAppearancesMatch() {
        val oracle=fixture();val cases=oracle.getJSONArray("appearanceCases");assertEquals(80,cases.length())
        repeat(cases.length()) { index ->
            val row=cases.getJSONObject(index)
            val skin=oracle.getJSONObject("packages").getJSONObject(row.getString("source")).getJSONObject("skin")
            val result=SkinAppearanceResolver.appearance(skin,row.getString("orientation"),row.getString("scheme"),row.getString("actionSet"))
            equal("appearance $index ${row.getString("source")}",oracle.getJSONObject("expectedAppearances").getJSONObject(row.getString("expectedKey")),result)
            val controls=row.getJSONArray("controls")
            repeat(controls.length()) {
                val c=controls.getJSONObject(it)
                equal("control $index/$it",c.getJSONObject("expected"),SkinAppearanceResolver.controlAppearance(result,c.getString("kind"),UUID.fromString(c.getString("id")),c.optString("role").ifEmpty { null }))
            }
        }
    }
    fun localOverrideBaselineClearsAndAssetLibraryStagesMatchNative() {
        val oracle=fixture();val cases=oracle.getJSONArray("layoutCases");assertEquals(80,cases.length())
        repeat(cases.length()) { index ->
            val row=cases.getJSONObject(index);val p=oracle.getJSONObject("packages").getJSONObject(row.getString("source"))
            val data=p.getJSONObject("assetPayloads");val assets=data.keys().asSequence().associateWith { Base64.getDecoder().decode(data.getString(it)) }
            val packageValue=SkinPackage(byteArrayOf(),p.getJSONObject("manifest"),p.getJSONObject("skin"),null,assets,emptyMap())
            val appearance=SkinAppearanceResolver.appearance(p.getJSONObject("skin"),row.getString("orientation"),row.getString("scheme"),row.getString("actionSet"))
            val library=SkinAppearanceResolver.mergeAssets(packageValue,row.getJSONObject("localAssets"),row.optJSONObject("baselineAssets"))
            equal("assets $index",row.getJSONObject("expectedAssets"),library)
            val styles=SkinAppearanceResolver.hydrateAssets(SkinAppearanceResolver.mergeStyles(appearance.getJSONObject("styleLibrary"),row.getJSONObject("localStyles"),row.optJSONObject("baselineStyles")),library)
            equal("styles $index",row.getJSONObject("expectedStyles"),styles)
            val control=SkinAppearanceResolver.controlAppearance(appearance,"button",UUID.fromString("00000000-0000-0000-0000-000000000105"),"primary_action")
            val tokens=styles.getJSONArray("styles")
            val style=(0 until tokens.length()).map { tokens.getJSONObject(it) }.firstOrNull { it.getString("id")==control.optString("styleID") }
            val local=row.getJSONObject("local");val before=local.toString()
            val result=SkinAppearanceResolver.hydrateAssets(SkinAppearanceResolver.applyControl(control,local,style?.optJSONObject("visualStyle")?.optJSONObject("icon"),row.getString("mode")!="replace",row.optJSONObject("baseline")),library)
            equal("layout $index ${row.getString("mode")}",row.getJSONObject("expected"),result)
            assertEquals(before,local.toString())
        }
    }
    fun nativeCornerDefaultsClampsAndLocalSilhouettesMatch() {
        val cases = fixture().getJSONArray("controlEdgeCases")
        assertEquals(192, cases.length())
        repeat(cases.length()) { index ->
            val row = cases.getJSONObject(index)
            equal("corner edge $index", row.getJSONObject("expected"),
                SkinAppearanceResolver.applyControl(row.getJSONObject("appearance"), row.getJSONObject("local"),
                    preserveLocal = row.getString("mode") != "replace", baseline = row.optJSONObject("baseline")))
        }
    }
    private fun equal(label: String, expected: Any?, actual: Any?) {
        when (expected) {
            null, JSONObject.NULL -> assertTrue(label, actual == null || actual === JSONObject.NULL)
            is JSONObject -> {
                assertTrue("$label must be an object", actual is JSONObject)
                actual as JSONObject
                assertEquals("$label keys", expected.keys().asSequence().toSet(), actual.keys().asSequence().toSet())
                for (key in expected.keys()) equal("$label.$key", expected.get(key), actual.get(key))
            }
            is org.json.JSONArray -> {
                assertTrue("$label must be an array", actual is org.json.JSONArray)
                actual as org.json.JSONArray
                assertEquals("$label length", expected.length(), actual.length())
                for (index in 0 until expected.length()) equal("$label[$index]", expected.get(index), actual.get(index))
            }
            is Number -> {
                assertTrue("$label must be numeric", actual is Number)
                assertEquals(label, expected.toDouble(), (actual as Number).toDouble(), 1e-12)
            }
            else -> assertEquals(label, expected, actual)
        }
    }
}
