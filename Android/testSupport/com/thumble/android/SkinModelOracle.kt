package com.thumble.android

import org.json.JSONObject
import org.junit.Assert.*
import java.util.Base64

internal class SkinModelOracle(private val load: () -> JSONObject) {
    private fun input(row: JSONObject): JSONObject {
        if(row.has("rawJSON")) return PackageJSON.objectValue(row.getString("rawJSON").toByteArray(Charsets.UTF_8))
        val input=JSONObject(row.getJSONObject("input").toString())
        if(row.has("repeatImageDataBytes")) input.getJSONObject("image").put("data",
            Base64.getEncoder().encodeToString(ByteArray(row.getInt("repeatImageDataBytes")) { 7 }))
        return input
    }
    fun validModelsMatchNativeNormalizationAndPreserveInput() {
        val cases=load().getJSONArray("cases");assertEquals(394,cases.length());var accepted=0
        repeat(cases.length()) { index ->
            val row=cases.getJSONObject(index)
            if(row.getBoolean("accepted")) {
                accepted++
                val input=input(row);val before=input.toString()
                val actual=try { SkinModelCodec.decode(row.getString("kind"),input) } catch(e: Exception) { throw AssertionError("Native accepted model $index ${row.getString("kind")}",e) }
                equal("model $index ${row.getString("kind")}",row.opt("expected"),actual)
                assertEquals("Saved input must remain unchanged",before,input.toString())
            }
        }
        assertEquals(171,accepted)
    }
    fun malformedModelsMatchNativeRejections() {
        val cases=load().getJSONArray("cases");var rejected=0
        repeat(cases.length()) { index ->
            val row=cases.getJSONObject(index)
            if(!row.getBoolean("accepted")) {
                rejected++
                try {
                    SkinModelCodec.decode(row.getString("kind"),input(row))
                    fail("Native rejected model $index ${row.getString("kind")}, Android must reject it too")
                } catch(_: SkinPackageException) { }
            }
        }
        assertEquals(223,rejected)
    }
    fun publishedPackagesMatchNativeSkinModels(nativeOracle: JSONObject,read: (String)->ByteArray) {
        val packages=nativeOracle.getJSONObject("packages")
        val names=packages.keys().asSequence().filter { it!="synthetic" }.toList()
        assertEquals(4,names.size)
        for(name in names) {
            val decoded=SkinPackageCodec.decode(read(name))
            equal("native package $name",packages.getJSONObject(name).getJSONObject("skin"),decoded.skinJSON())
        }
    }
    private fun equal(label: String, expected: Any?, actual: Any?) {
        if(expected is String && expected.startsWith("@base64-sha256:")) {
            assertTrue("$label must contain Base64",actual is String)
            val bytes=Base64.getDecoder().decode(actual as String)
            assertEquals("$label canonical Base64",actual,Base64.getEncoder().encodeToString(bytes))
            assertEquals("$label binary digest",expected.removePrefix("@base64-sha256:"),packageHash(bytes))
            return
        }
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
