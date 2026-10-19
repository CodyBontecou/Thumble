package com.thumble.android

import org.json.JSONObject
import org.junit.Assert.*
import java.util.Base64

internal class SkinProfileOracle(private val load: () -> JSONObject) {
    private fun packageValue(v: JSONObject, compatibility: JSONObject? = null, replaceCompatibility: Boolean = false): SkinPackage {
        val data=v.getJSONObject("assetPayloads")
        val assets=data.keys().asSequence().associateWith { Base64.getDecoder().decode(data.getString(it)) }
        val manifest=JSONObject(v.getJSONObject("manifest").toString())
        if(replaceCompatibility) {
            if(compatibility==null) manifest.remove("compatibility") else manifest.put("compatibility",compatibility)
        }
        return SkinPackage(byteArrayOf(),manifest,v.getJSONObject("skin"),null,assets,emptyMap())
    }
    fun canonicalProfilesMatchNativeWithoutChangingBindingsOrInput() {
        val v=load();val cases=v.getJSONArray("cases");assertEquals(86,cases.length())
        val packageValue=packageValue(v);val profiles=v.getJSONObject("profiles")
        repeat(cases.length()) { index ->
            val row=cases.getJSONObject(index);val local=profiles.getJSONObject(row.getString("profile"));val before=local.toString()
            val baseline=row.optString("baseline").takeIf { it.isNotEmpty() }?.let { profiles.getJSONObject(it) }
            val result=SkinProfileResolver.apply(packageValue,local,row.getString("orientation"),row.getString("scheme"),row.getBoolean("preserve"),baseline)
            equal("profile $index ${row.getString("profile")}",row.getJSONObject("expected"),result.customization)
            assertEquals("Saved input must remain unchanged",before,local.toString())
            val originalElements=local.getJSONArray("elements");val resolvedElements=result.customization.getJSONArray("elements")
            assertEquals(originalElements.length(),resolvedElements.length())
            repeat(originalElements.length()) { e ->
                val original=originalElements.getJSONObject(e);val resolved=resolvedElements.getJSONObject(e)
                for(field in listOf("id","kind","label","output","defaultOutput","partOutputs","joystickMapping","joystickOutputSettings","triggerSettings","trackpadSettings","presentation","futureAppearance"))
                    equal("input $index/$e/$field",original.opt(field),resolved.opt(field))
            }
        }
    }
    fun compatibilityAndArtworkGatingMatchNative() {
        val v=load();val cases=v.getJSONArray("compatibilityCases");assertEquals(22,cases.length())
        repeat(cases.length()) { index ->
            val row=cases.getJSONObject(index);val compatibility=row.optJSONObject("compatibility")
            val packageValue=packageValue(v,compatibility,true)
            val result=SkinProfileResolver.apply(packageValue,row.getJSONObject("local"),row.getString("orientation"),"dark",false)
            equal("compatibility ${row.getString("name")}",row.getJSONObject("expected"),result.compatibility.json())
            equal("gated appearance ${row.getString("name")}",row.getJSONObject("expectedResolved"),result.customization)
        }
    }
    fun nativeCanvasCatalogAndDefaultsMatch() {
        val v=load();val cases=v.getJSONArray("canvases");assertEquals(68,cases.length())
        repeat(cases.length()) { index ->
            val row=cases.getJSONObject(index)
            val size=SkinCanvas.from(JSONObject().put("deviceCanvas",JSONObject().put("frameID",row.getString("id"))))
            assertEquals(row.getDouble("width"),size.width,0.0);assertEquals(row.getDouble("height"),size.height,0.0)
        }
        val geometries=v.getJSONArray("geometries");assertEquals(22,geometries.length())
        repeat(geometries.length()) { index ->
            val row=geometries.getJSONObject(index)
            val local=v.getJSONObject("profiles").getJSONObject(row.getString("profile"));val size=SkinCanvas.from(local)
            val actual=SkinCompatibility.geometry(local).associateBy { it.id }
            val expected=row.getJSONArray("controls")
            assertEquals("Visible geometry count",expected.length(),actual.size)
            repeat(expected.length()) { c ->
                val control=expected.getJSONObject(c);val geometry=actual.getValue(control.getString("id"))
                val output=JSONObject().put("id",geometry.id).put("kind",geometry.kind).put("role",geometry.role).put("rotation",geometry.rotation)
                    .put("frame",JSONObject().put("x",geometry.frame.left/size.width).put("y",geometry.frame.top/size.height)
                        .put("width",geometry.frame.width/size.width).put("height",geometry.frame.height/size.height))
                equal("geometry ${row.getString("profile")}/$c",control,output)
            }
        }
        equal("default control",v.getJSONObject("defaultLayout"),SkinProfileResolver.defaultLayout())
        equal("default top bar",v.getJSONObject("defaultTopBar"),SkinProfileResolver.defaultTopBar())
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
