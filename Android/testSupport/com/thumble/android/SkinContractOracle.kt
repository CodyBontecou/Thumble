package com.thumble.android

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import java.io.ByteArrayOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

internal class SkinContractOracle(private val load: () -> JSONObject) {
    private fun input(oracle: JSONObject,row: JSONObject): JSONObject {
        val result=JSONObject(oracle.getJSONObject("bases").getJSONObject(row.getString("base")).toString())
        val path=row.getJSONArray("path")
        if(path.length()==0) return result
        var parent: Any=result
        repeat(path.length()-1) { i -> parent=if(parent is JSONObject) (parent as JSONObject).get(path.getString(i)) else (parent as JSONArray).get(path.getInt(i)) }
        val key=path.getString(path.length()-1)
        if(parent is JSONObject) {
            if(row.getBoolean("remove")) parent.remove(key) else parent.put(key,row.get("replacement"))
        } else (parent as JSONArray).put(path.getInt(path.length()-1),row.get("replacement"))
        return result
    }
    private fun archive(compatibility: JSONObject): ByteArray {
        val skin=JSONObject().put("base",JSONObject().put("roleRules",JSONArray()).put("buttonRules",JSONArray()).put("styleLibrary",JSONObject().put("styles",JSONArray()))).put("variants",JSONArray()).toString().toByteArray()
        val manifest=JSONObject().put("schema","com.codybontecou.pocketpad.skin-package").put("schemaVersion",2).put("identifier","com.example.contract").put("version","1.0.0").put("kind","skin")
            .put("name","Contract").put("author",JSONObject().put("name","Tests")).put("summary","").put("license","MIT").put("tags",JSONArray())
            .put("assets",JSONArray()).put("previews",JSONArray()).put("skinPath","skin.json").put("skinSHA256",packageHash(skin)).put("compatibility",compatibility)
        val bytes=ByteArrayOutputStream()
        ZipOutputStream(bytes).use { zip ->
            for((name,data) in listOf("skin.json" to skin,"manifest.json" to manifest.toString().toByteArray())) {
                zip.putNextEntry(ZipEntry(name));zip.write(data);zip.closeEntry()
            }
        }
        return bytes.toByteArray()
    }
    fun typedContractsAndNormalizationMatchNative() {
        val oracle=load();val cases=oracle.getJSONArray("cases");assertEquals(217,cases.length());var accepted=0
        repeat(cases.length()) { index ->
            val row=cases.getJSONObject(index)
            if(row.getBoolean("accepted")) {
                accepted++
                val raw=input(oracle,row);val before=raw.toString()
                val result=try { SkinContractCodec.compatibility(raw) } catch(e: Exception) { throw AssertionError("Native accepted contract $index ${row.getString("base")}",e) }
                equal("contract $index",row.getJSONObject("expected"),result)
                assertEquals("Input contract must not change",before,raw.toString())
            }
        }
        assertEquals(56,accepted)
    }
    fun malformedNestedContractsMatchNativeRejections() {
        val oracle=load();val cases=oracle.getJSONArray("cases");var rejected=0
        repeat(cases.length()) { index ->
            val row=cases.getJSONObject(index)
            if(!row.getBoolean("accepted")) {
                rejected++
                try { SkinContractCodec.compatibility(input(oracle,row));fail("Native rejected contract $index") } catch(_: SkinPackageException) { }
            }
        }
        val duplicateJSON=oracle.getJSONArray("duplicateJSON")
        repeat(duplicateJSON.length()) { i ->
            val row=duplicateJSON.getJSONObject(i);var accepted=true
            try { PackageJSON.objectValue(row.getString("rawJSON").toByteArray(Charsets.UTF_8)) } catch(_: SkinPackageException) { accepted=false }
            assertEquals("Native JSON key equality $i",row.getBoolean("accepted"),accepted)
        }
        assertEquals(161,rejected)
    }
    fun packageCompatibilityValidationMatchesNativeAfterDecodeNormalization() {
        val oracle=load();val cases=oracle.getJSONArray("cases")
        repeat(cases.length()) { index ->
            val row=cases.getJSONObject(index)
            var result: SkinPackage?=null
            try { result=SkinPackageCodec.decode(archive(input(oracle,row))) } catch(_: SkinPackageException) { }
            val accepted=row.optBoolean("validPackage",false)
            assertEquals("Native package acceptance $index ${row.getString("base")}",accepted,result!=null)
            if(result!=null) equal("stored normalized contract $index",row.getJSONObject("expected"),result!!.manifestJSON().getJSONObject("compatibility"))
        }
    }
    fun malformedReplacementPreservesInstalledArchive(root: java.io.File) {
        try {
            val source=JSONObject(load().getJSONObject("bases").getJSONObject("rich").toString())
            val store=SkinLibrary(root);val original=archive(source);val reference=store.install(original).reference
            source.getJSONObject("capturedGeometry").getJSONArray("variants").getJSONObject(0)
                .getJSONObject("nativeLayout").getJSONArray("chromeSamples").getJSONObject(0).put("isConnected","invalid")
            try { store.install(archive(source),SkinInstallPolicy.REPLACE_SAME_VERSION);fail("Malformed contract must not replace an installed package") } catch(e: SkinPackageException) { assertEquals("invalid-skin-contract",e.code) }
            assertArrayEquals(original,SkinLibrary(root).archiveFor(reference))
        } finally { root.deleteRecursively() }
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
