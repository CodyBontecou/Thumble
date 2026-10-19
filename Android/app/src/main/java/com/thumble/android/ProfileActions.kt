package com.thumble.android

import org.json.JSONObject
import java.util.UUID

/** Builds only the native control-plane messages; profile values remain server-owned. */
internal object ProfileActions {
    const val ORIENTATION_CAPABILITY="gamepad_profile_orientation_preference_mutation"
    fun defaultProfile(snapshot: ProfileSnapshot,id: UUID): JSONObject? {
        if (snapshot.profiles.none { it.id == id } || snapshot.defaultID == id) return null
        return WireCodec.message("gamepad_default_profile").put("gamepadProfileID",id.toString().uppercase())
            .put("defaultGamepadProfileID",id.toString().uppercase())
    }
    fun orientation(snapshot: ProfileSnapshot,capabilities: Set<String>,preference: String): JSONObject? {
        val profile=snapshot.selected ?: return null
        if (ORIENTATION_CAPABILITY !in capabilities || preference !in setOf("automatic","portrait","landscape") ||
            profile.orientationPreference == preference) return null
        return WireCodec.message(ORIENTATION_CAPABILITY).put("gamepadProfileID",profile.id.toString().uppercase())
            .put("gamepadProfileOrientationPreferenceMutation",preference)
    }
    fun launch(snapshot: ProfileSnapshot): JSONObject? {
        val profile=snapshot.selected?.takeIf { it.launchTargetName != null } ?: return null
        return WireCodec.message("launch_profile_target").put("gamepadProfileID",profile.id.toString().uppercase())
    }
}
