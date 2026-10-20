package com.thumble.android

import org.json.JSONObject
import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Test

class AppearanceEditOracleTest {
    private fun nativeSame(expected: Any?, actual: Any?, path: String = ""): Boolean {
        if (AppearanceJSON.same(expected, actual)) return true
        if (expected is Number && actual is Number && path.lowercase().contains("color") &&
            listOf("/red", "/green", "/blue", "/alpha").any(path::endsWith)) {
            val a = actual.toDouble(); val e = expected.toDouble()
            return a in 0.0..1.0 && e in 0.0..1.0 && kotlin.math.abs(a - e) <= 0.0000002
        }
        if (expected is JSONObject && actual is JSONObject) {
            val keys = expected.keys().asSequence().toSet()
            return keys == actual.keys().asSequence().toSet() && keys.all { nativeSame(expected.get(it), actual.get(it), "$path/$it") }
        }
        if (expected is JSONArray && actual is JSONArray)
            return expected.length() == actual.length() && (0 until expected.length()).all { nativeSame(expected.get(it), actual.get(it), "$path/$it") }
        return false
    }
    @Test fun allNativeEditCasesAgreeAcrossSchemesAndTriggerStates() {
        val fixture = javaClass.classLoader!!.getResourceAsStream("appearance-edits/v1/fixture.json")!!
            .use { JSONObject(it.bufferedReader().readText()) }
        var checked = 0
        for (case in AppearanceJSON.objects(fixture.getJSONArray("cases"))) {
            val source = case.getJSONObject("profile")
            val before = source.toString()
            val expanded = ProfileResourceTable.fromProfile(source)?.expanding(source) ?: AppearanceJSON.objectCopy(source)
            val bank = ProfileAppearanceBank(expanded.getJSONObject("appearanceBank"))
            val current = expanded.getJSONObject("customization")
            for (row in AppearanceJSON.objects(case.getJSONArray("resolutions"))) {
                val resolved = bank.resolve(current, row.getString("colorScheme"), row.getString("actionSet"))
                val actual = bank.snapshot(resolved)
                assertTrue("${case.getString("name")} ${row.getString("colorScheme")}/${row.getString("actionSet")}\nExpected ${row.getJSONObject("expectedAppearance")}\nActual $actual",
                    nativeSame(row.getJSONObject("expectedAppearance"), actual))
                val originalElements = AppearanceJSON.objects(current.getJSONArray("elements"))
                val outputElements = AppearanceJSON.objects(resolved.getJSONArray("elements"))
                assertEquals(originalElements.map { it.getString("id") }, outputElements.map { it.getString("id") })
                originalElements.zip(outputElements).forEach { (original, output) ->
                    for (field in listOf("output", "defaultOutput", "partOutputs", "kind", "label"))
                        assertTrue(AppearanceJSON.same(original.opt(field), output.opt(field)))
                    for (field in listOf("centerX", "centerY", "widthScale", "heightScale", "rotationDegrees", "isHidden"))
                        assertTrue(AppearanceJSON.same(original.getJSONObject("layout").opt(field), output.getJSONObject("layout").opt(field)))
                }
                checked++
            }
            assertEquals(before, source.toString())
        }
        assertEquals(168, checked)
    }
}
