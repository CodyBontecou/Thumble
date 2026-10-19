package com.thumble.android

import org.json.JSONObject
import org.junit.Assert.*
import java.util.Base64

internal class SkinLifecycleOracle(private val load: () -> JSONObject) {
    fun applicationAndDetachmentMatchNative() {
        val v=load();val packages=v.getJSONObject("packages")
        val decoded=packages.keys().asSequence().associateWith { name ->
            val p=packages.getJSONObject(name);val assets=p.getJSONObject("assetPayloads")
            SkinPackage(byteArrayOf(),p.getJSONObject("manifest"),p.getJSONObject("skin"),null,
                assets.keys().asSequence().associateWith { Base64.getDecoder().decode(assets.getString(it)) },emptyMap())
        }
        val rows=v.getJSONArray("cases");assertEquals(44,rows.length())
        repeat(rows.length()) { index ->
            val row=rows.getJSONObject(index);val input=ControllerProfile.parse(row.getJSONObject("input"));val before=input.source.toString()
            val pkg=row.optString("package").takeIf { it.isNotEmpty() }?.let { decoded.getValue(it) }
            val actual=if(row.getString("operation")=="apply") SkinProfileLifecycle.apply(input,pkg!!,row.getString("scheme"),0)
                else SkinProfileLifecycle.detach(input,pkg,row.getString("scheme"),0)
            equal(row.getString("name"),row.getJSONObject("expected"),actual.source)
            assertEquals("Mutation must not change the caller's saved object",before,input.source.toString())
            assertEquals(input.id,actual.id);assertEquals(input.name,actual.name)
        }
    }
    private fun equal(path: String, expected: Any?, actual: Any?) {
        when(expected) {
            null,JSONObject.NULL -> assertTrue(path,actual==null || actual===JSONObject.NULL)
            is JSONObject -> {
                assertTrue("$path object",actual is JSONObject);actual as JSONObject
                assertEquals("$path fields",expected.keys().asSequence().toSet(),actual.keys().asSequence().toSet())
                for(key in expected.keys()) equal("$path.$key",expected.get(key),actual.get(key))
            }
            is org.json.JSONArray -> {
                assertTrue("$path array",actual is org.json.JSONArray);actual as org.json.JSONArray
                assertEquals("$path length",expected.length(),actual.length())
                repeat(expected.length()) { equal("$path[$it]",expected.get(it),actual.get(it)) }
            }
            is Number -> { assertTrue(path,actual is Number);assertEquals(path,expected.toDouble(),(actual as Number).toDouble(),1e-12) }
            else -> assertEquals(path,expected,actual)
        }
    }
}
