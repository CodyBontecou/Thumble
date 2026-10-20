package com.thumble.android

import org.json.JSONObject
import org.json.JSONArray
import org.erdtman.jcs.JsonCanonicalizer
import org.junit.Assert.*
import org.junit.Test

class PortableProfileArtifactTest {
    private fun fixture()=javaClass.classLoader!!.getResourceAsStream("profile-artifact/v1.json")!!.readBytes()
    private fun signed(raw: JSONObject): ByteArray {
        val content=JSONObject(raw.toString()).apply { remove("exportedAt");remove("contentHash") }
        raw.getJSONObject("contentHash").put("value",packageHash(JsonCanonicalizer(content.toString()).encodedUTF8))
        return raw.toString().toByteArray()
    }
    @Test fun nativeFixtureHashAndRawBytesAndFutureMetadataAreRetained() {
        val bytes=fixture();val value=PortableProfileArtifact.decode(bytes)
        assertArrayEquals(bytes,value.rawData());assertEquals(packageHash(bytes),value.rawSHA256)
        assertEquals(JSONObject(bytes.toString(Charsets.UTF_8)).getJSONObject("contentHash").getString("value"),value.contentHash)
        val snapshot=value.profileSnapshot();assertEquals(value.activeProfileID,snapshot.selectedID)
        assertEquals("未来 Pad 🎛️",snapshot.selected!!.name)
        assertTrue(snapshot.selected!!.source.has("futureProfileField"))
        val mutated=value.rawData();mutated.fill(0);assertArrayEquals(bytes,value.rawData())
    }
    @Test fun rfc8785NumbersUtf16KeyOrderingAndNegativeZeroMatchNativeVectors() {
        val canonical=JsonCanonicalizer("""{"numbers":[333333333.33333329,1E30,4.50,2e-3,1e-27,-0.0,1e23],"keys":{"\u20ac":1,"\ud83d\ude00":2,"\ufb33":3}}""").encodedString
        assertEquals("""{"keys":{"€":1,"😀":2,"דּ":3},"numbers":[333333333.3333333,1e+30,4.5,0.002,1e-27,0,1e+23]}""",canonical)
    }
    @Test fun portabilityAndIntegrityRejectCredentialAliasesLaunchTargetsAndUndeclaredBindings() {
        fun rejected(change: (JSONObject)->Unit) { val raw=JSONObject(fixture().toString(Charsets.UTF_8));change(raw);assertTrue(runCatching { PortableProfileArtifact.decode(signed(raw)) }.isFailure) }
        rejected { it.put("unknown",JSONObject().put("Au_thorization","secret")) }
        rejected { it.put("unknown",JSONObject().put("imageData","bytes")) }
        rejected { it.put("Key_Bindings",JSONObject()) }
        rejected { it.put("Artifact_Version",1) }
        rejected { it.getJSONArray("profiles").getJSONObject(0).put("launchTarget",JSONObject.NULL) }
        rejected { raw -> raw.put("profileKeyBindings",JSONObject().put(raw.getString("activeProfileID"),JSONObject().put("00000000-0000-0000-0000-000000000999",JSONObject().put("keyCode",1)))) }
        rejected { it.getJSONArray("profiles").getJSONObject(0).getJSONObject("customization").getJSONArray("elements").getJSONObject(0).put("kind","not-a-kind") }
        val raw=JSONObject(fixture().toString(Charsets.UTF_8));raw.put("unknown",true)
        assertTrue(runCatching { PortableProfileArtifact.decode(raw.toString().toByteArray()) }.isFailure)
        val allowed=JSONObject(fixture().toString(Charsets.UTF_8)).put("future",JSONObject().put("credential",JSONObject.NULL))
        PortableProfileArtifact.decode(signed(allowed))
    }
    @Test fun scannerEnforcesNativeDepthContainerStringsAndIjsonWithoutChangingTransportLimits() {
        for(raw in listOf("{\"x\":1,\"x\":2}","{\"x\":null,\"\\u0078\":2}","{\"x\":9007199254740992}","{\"x\":-9007199254740992}","{\"x\":1e999}","{\"x\":\"\\ud800\"}","{\"x\":\"\\udfff\"}","{\"x\":1,}","{\"x\":1}junk","\ufeff{}"))
            assertTrue(runCatching { PackageJSON.objectValue(raw.toByteArray(),portable=true) }.isFailure)
        PackageJSON.objectValue("{\"x\":9223372036854775807}".toByteArray())
        PackageJSON.objectValue("{\"x\":9007199254740991}".toByteArray(),true)
        assertTrue(runCatching { PackageJSON.objectValue(("{\"x\":"+"[".repeat(64)+"0"+"]".repeat(64)+"}").toByteArray(),true) }.isFailure)
        assertTrue(runCatching { PackageJSON.objectValue(JSONObject().put("x",JSONArray().apply { repeat(4097) { put(0) } }).toString().toByteArray(),true) }.isFailure)
        assertTrue(runCatching { PackageJSON.objectValue(JSONObject().put("x","a".repeat(256*1024+1)).toString().toByteArray(),true) }.isFailure)
        assertTrue(runCatching { PackageJSON.objectValue(JSONObject().put("a".repeat(257),0).toString().toByteArray(),true) }.isFailure)
    }
    @Test fun executableBindingsRequireCurrentNativeEnumsAndTypedStrokeFields() {
        fun artifact(element: JSONObject): ByteArray {
            val raw=JSONObject(fixture().toString(Charsets.UTF_8))
            val target=raw.getJSONArray("profiles").getJSONObject(0).getJSONObject("customization").getJSONArray("elements").getJSONObject(0)
            for(key in element.keys()) target.put(key,element.get(key))
            return signed(raw)
        }
        val output=JSONObject().put("gamepadButtons",JSONArray().put("south")).put("keyboard",JSONObject().put("keyCode",12).put("modifiersRawValue",1))
        PortableProfileArtifact.decode(artifact(JSONObject().put("output",output).put("partOutputs",JSONArray().put("primary").put(output))))
        for(change in listOf(
            JSONObject().put("output",JSONObject()),
            JSONObject().put("output",JSONObject().put("gamepadButtons",JSONArray().put("future-gamepad-button"))),
            JSONObject().put("output",JSONObject().put("gamepadButtons",JSONArray()).put("keyboard",JSONObject().put("keyCode",12).put("modifiers",1))),
            JSONObject().put("partOutputs",JSONObject().put("primary",output)),
            JSONObject().put("partOutputs",JSONArray().put("primary").put(output).put("primary").put(output)),
            JSONObject().put("partOutputs",JSONArray().put("future-part").put(output)),
            JSONObject().put("partOutputs",JSONArray().put("primary")),
            JSONObject().put("legacySlot",JSONObject.NULL)
        )) assertTrue(change.toString(),runCatching { PortableProfileArtifact.decode(artifact(change)) }.isFailure)
    }
    @Test fun executableControlSettingsRejectCoercedOrIncompleteNativeCodableValues() {
        val valid=JSONObject()
            .put("joystickMapping",JSONObject().apply { for(direction in listOf("up","down","left","right")) put(direction,JSONObject().put("gamepadButtons",JSONArray())) })
            .put("joystickOutputSettings",JSONObject().put("analogTarget","left_stick").put("sendsDigitalDirections",false).put("deadZone",.12).put("sensitivity",1.0).put("invertX",false).put("invertY",false).put("snapToCardinal",false))
            .put("triggerSettings",JSONObject().put("target","right").put("orientation","vertical").put("deadZone",.03).put("sensitivity",1.0).put("sendsDigitalButton",false).put("digitalThreshold",.5))
            .put("trackpadSettings",JSONObject().put("sensitivity",1.2).put("scrollSensitivity",.85).put("tapToClick",true).put("twoFingerScroll",true).put("naturalScrolling",true))
        fun decode(settings: JSONObject) {
            val raw=JSONObject(fixture().toString(Charsets.UTF_8))
            val target=raw.getJSONArray("profiles").getJSONObject(0).getJSONObject("customization").getJSONArray("elements").getJSONObject(0)
            for(key in settings.keys()) target.put(key,settings.get(key))
            PortableProfileArtifact.decode(signed(raw))
        }
        decode(valid)
        for(field in valid.keys()) {
            val original=valid.getJSONObject(field)
            for(key in original.keys()) {
                val missing=JSONObject(valid.toString());missing.getJSONObject(field).remove(key)
                assertTrue("$field.$key missing",runCatching { decode(missing) }.isFailure)
                val wrong=JSONObject(valid.toString());wrong.getJSONObject(field).put(key,"wrong-type")
                assertTrue("$field.$key type",runCatching { decode(wrong) }.isFailure)
            }
        }
    }
    @Test fun portableProfileModelsAgreeWithNativeDecoderFixtures() {
        val cases=JSONObject(javaClass.classLoader!!.getResourceAsStream("android-profile-models/v1.json")!!.bufferedReader().use { it.readText() }).getJSONArray("cases")
        assertTrue(cases.length()>=93)
        repeat(cases.length()) { index ->
            val case=cases.getJSONObject(index);val profile=case.getJSONObject("profile")
            val raw=JSONObject(fixture().toString(Charsets.UTF_8)).put("profiles",JSONArray().put(profile))
                .put("activeProfileID",profile.getString("id")).put("defaultProfileID",JSONObject.NULL)
            raw.remove("profileKeyBindings");raw.remove("profileOutputBindings")
            val result=runCatching { PortableProfileArtifact.decode(signed(raw)) }
            assertEquals(case.getString("name"),case.getBoolean("accepted"),result.isSuccess)
            if(result.isSuccess) {
                fun sortSets(value: Any) {
                    when(value) {
                        is JSONObject -> for(key in value.keys()) {
                            val child=value.get(key)
                            if(key=="gamepadButtons" && child is JSONArray) value.put(key,JSONArray((0 until child.length()).map { child.getString(it) }.distinct().sorted()))
                            else sortSets(child)
                        }
                        is JSONArray -> repeat(value.length()) { sortSets(value.get(it)) }
                    }
                }
                val expected=case.getJSONObject("normalizedProfile").getJSONObject("customization").getJSONArray("elements")
                val actual=result.getOrThrow().profileSnapshot().selected!!.source.getJSONObject("customization").getJSONArray("elements")
                sortSets(expected);sortSets(actual)
                assertTrue(case.getString("name")+" normalized elements\nexpected $expected\nactual $actual",sameSkinJSON(expected,actual))
            }
        }
    }
    @Test fun duplicateUuidBindingOwnersAndStyleAliasesCannotCollapseBeforeValidation() {
        val raw=JSONObject(fixture().toString(Charsets.UTF_8));val p=raw.getJSONArray("profiles").getJSONObject(0);val id=p.getJSONObject("customization").getJSONArray("elements").getJSONObject(0).getString("id")
        p.getJSONObject("customization").put("buttonCustomizations",JSONArray().put(id.lowercase()).put(JSONObject()).put(id.uppercase()).put(JSONObject()))
        assertTrue(runCatching { PortableProfileArtifact.decode(signed(raw)) }.isFailure)
    }
}
