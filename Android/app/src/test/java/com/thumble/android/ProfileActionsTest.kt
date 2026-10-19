package com.thumble.android

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class ProfileActionsTest {
    private fun profile(): ControllerProfile {
        val raw=JSONObject(javaClass.getResource("/controller-templates/v1/productivityStarter.json")!!.readText()).getJSONObject("profile")
        return ControllerProfile.parse(raw.put("orientationPreference","automatic"))
    }
    @Test fun `default identity is authoritative retained on partial messages and removed with its profile`() {
        val profile=profile()
        val message=WireCodec.message("gamepad_profiles").put("gamepadProfiles",JSONArray().put(profile.source))
            .put("gamepadProfileID",profile.id.toString()).put("defaultGamepadProfileID",profile.id.toString())
        val snapshot=ProfileSnapshot().applying(message)
        assertEquals(profile.id,snapshot.defaultID)
        assertEquals(profile.id,snapshot.applying(WireCodec.message("gamepad_customization")).defaultID)
        assertNull(snapshot.applying(WireCodec.message("gamepad_profiles").put("gamepadProfiles",JSONArray())).defaultID)
        assertNull(snapshot.applying(WireCodec.message("gamepad_profiles").put("defaultGamepadProfileID",JSONObject.NULL)).defaultID)
    }
    @Test fun `default request uses both native ID fields without changing the snapshot`() {
        val profile=profile();val snapshot=ProfileSnapshot(listOf(profile),profile.id)
        val request=ProfileActions.defaultProfile(snapshot,profile.id)!!
        assertEquals("gamepad_default_profile",request.getString("type"))
        assertEquals(profile.id.toString().uppercase(),request.getString("gamepadProfileID"))
        assertEquals(request.getString("gamepadProfileID"),request.getString("defaultGamepadProfileID"))
        assertNull(snapshot.defaultID)
        assertNull(ProfileActions.defaultProfile(snapshot,UUID.randomUUID()))
        assertNull(ProfileActions.defaultProfile(snapshot.copy(defaultID=profile.id),profile.id))
    }
    @Test fun `orientation requests require the exact capability and valid changed preference`() {
        val profile=profile();val snapshot=ProfileSnapshot(listOf(profile),profile.id)
        val capabilities=setOf(ProfileActions.ORIENTATION_CAPABILITY)
        assertNull(ProfileActions.orientation(snapshot,emptySet(),"portrait"))
        assertNull(ProfileActions.orientation(snapshot,capabilities,"future"))
        assertNull(ProfileActions.orientation(snapshot,capabilities,"automatic"))
        for (orientation in listOf("portrait","landscape")) {
            val request=ProfileActions.orientation(snapshot,capabilities,orientation)!!
            assertEquals(ProfileActions.ORIENTATION_CAPABILITY,request.getString("type"))
            assertEquals(orientation,request.getString("gamepadProfileOrientationPreferenceMutation"))
            assertEquals(profile.id.toString().uppercase(),request.getString("gamepadProfileID"))
        }
        assertEquals("automatic",profile.orientationPreference)
    }
    @Test fun `launch uses only profile identity and never sends Mac paths or bookmarks back`() {
        val profile=profile();val snapshot=ProfileSnapshot(listOf(profile),profile.id)
        assertNull(ProfileActions.launch(snapshot))
        profile.source.put("launchTarget",JSONObject().put("kind","application").put("displayName"," App ")
            .put("filePath","/Applications/Example.app").put("bookmarkData","fixture"))
        assertEquals("App",profile.launchTargetName)
        val request=ProfileActions.launch(snapshot)!!
        assertEquals("launch_profile_target",request.getString("type"))
        assertEquals(setOf("type","timestamp","gamepadProfileID"),request.keys().asSequence().toSet())
        profile.source.getJSONObject("launchTarget").put("displayName"," ")
        assertEquals("Application",profile.launchTargetName)
        profile.source.getJSONObject("launchTarget").put("kind","future")
        assertNull(profile.launchTargetName);assertNull(ProfileActions.launch(snapshot))
    }
}
