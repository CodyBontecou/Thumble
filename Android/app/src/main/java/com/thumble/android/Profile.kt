package com.thumble.android

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** Read-only subset of the canonical profile. Bindings stay authoritative on the host. */
data class ControllerProfile(val id: UUID, val name: String, val source: JSONObject) {
    val launchTargetName: String? get() = source.optJSONObject("launchTarget")?.takeIf {
        it.optString("kind","application") == "application"
    }?.optString("displayName")?.trim()?.ifBlank { "Application" }?.take(160)
    val orientationPreference: String get() = source.optString("orientationPreference", "automatic")
        .takeIf { it in setOf("automatic", "portrait", "landscape") } ?: "automatic"
    fun layout(landscape: Boolean): JSONObject = source.optJSONObject(
        if (landscape) "landscapeCustomization" else "portraitCustomization"
    ) ?: source.getJSONObject("customization")

    fun controls(landscape: Boolean): List<Control> {
        val layout = layout(landscape)
        val elements = layout.optJSONArray("elements") ?: error("This profile has no canonical elements. Update Thumble Mac.")
        require(elements.length() <= 2048) { "Profile has too many controls." }
        val overrides = layout.swiftMap("buttonCustomizations")
        val labels = layout.swiftMap("labelOverrides")
        val seen = mutableSetOf<UUID>()
        return (0 until elements.length()).mapNotNull { index ->
            val element = elements.getJSONObject(index)
            val id = UUID.fromString(element.getString("id"))
            require(seen.add(id)) { "Profile contains duplicate control IDs." }
            val kind = element.optString("kind", "button")
            val builtin = kind == "button" && id.starterSlot() != null
            val style = (if (builtin) overrides[id.toString().uppercase()] as? JSONObject else null)
                ?: element.optJSONObject("layout") ?: JSONObject()
            if (style.optBoolean("isHidden")) return@mapNotNull null
            if (kind !in SUPPORTED_CONTROL_KINDS) return@mapNotNull null
            Control(id, (if (builtin) labels[id.toString().uppercase()] as? String else null) ?: element.optString("label", "Button"),
                kind, style, layout.optString("controlScale", "standard"), element)
        }.let { controls ->
            val declared = layout.optJSONObject("designMetadata")?.optJSONArray("layerOrder")
            val order = linkedMapOf<UUID, Int>()
            val available = controls.associateBy { it.id }
            if (declared != null) for (index in 0 until declared.length()) {
                val value = declared.opt(index)
                val kind = if (value is JSONObject) value.optString("kind") else
                    value?.toString()?.takeIf { '.' in it }?.substringBefore('.') ?: "builtin"
                val raw = if (value is JSONObject) when (value.optString("kind")) {
                    "builtin" -> value.optString("button")
                    "custom" -> value.optString("id")
                    else -> ""
                } else value?.toString()?.substringAfter('.') ?: ""
                runCatching { UUID.fromString(raw) }.getOrNull()?.let { id ->
                    val control = available[id]
                    if (control != null && kind == if (control.isBuiltin) "builtin" else "custom") order.putIfAbsent(id, order.size)
                }
            }
            // Metadata normalization appends controls omitted from an explicit order.
            controls.forEach { order.putIfAbsent(it.id, order.size) }
            controls.sortedWith(compareBy<Control> { it.style.optInt("zIndex").coerceIn(-100, 100) }.thenBy { order[it.id] })
        }
    }
    fun unsupportedKinds(landscape: Boolean): List<String> {
        val elements = layout(landscape).optJSONArray("elements") ?: JSONArray()
        return (0 until elements.length()).map { elements.getJSONObject(it) }
            .filterNot { it.optJSONObject("layout")?.optBoolean("isHidden") == true }
            .map { it.optString("kind") }.filter { it !in SUPPORTED_CONTROL_KINDS }.distinct()
    }
    companion object {
        fun parse(json: JSONObject): ControllerProfile {
            ProfileFramePolicy.validateStoredProfile(json)
            val id = UUID.fromString(json.getString("id"))
            require(json.has("customization")) { "Profile is missing its layout." }
            val profile = ControllerProfile(id, json.optString("name", "Keypad").take(160), json)
            profile.controls(false); profile.controls(true)
            artworkLayers(profile.layout(false).optJSONArray("artworkLayers")); artworkLayers(profile.layout(true).optJSONArray("artworkLayers"))
            return profile
        }
    }
}

/** The primary preference governs all orientation variants, as in the native model. */
internal fun ControllerProfile.skinColorScheme(systemDark: Boolean): String =
    when(source.getJSONObject("customization").optString("colorSchemePreference", "system")) {
        "dark" -> "dark"; "light" -> "light"; else -> if(systemDark) "dark" else "light"
    }

internal val SUPPORTED_CONTROL_KINDS = setOf("button", "joystick", "trigger", "trackpad", "text", "decoration")
data class Control(val id: UUID, val label: String, val kind: String, val style: JSONObject, val scale: String, val source: JSONObject = JSONObject()) {
    val legend: String get() = source.optJSONObject("presentation")?.let {
        if (it.has("legend") && !it.isNull("legend")) it.optString("legend") else null
    } ?: label
    val accessibilityName: String get() = source.optJSONObject("presentation")?.optString("accessibilityName")?.takeUnless { it.isBlank() || it == "null" } ?: label
}

internal fun JSONObject.swiftMap(key: String): Map<String, Any> {
    val value = opt(key)
    return when (value) {
        is JSONObject -> value.keys().asSequence().associate { it.uppercase() to value.get(it) }
        is JSONArray -> {
            require(value.length() % 2 == 0) { "Invalid profile map: $key" }
            (0 until value.length() step 2).associate { value.getString(it).uppercase() to value.get(it + 1) }
        }
        else -> emptyMap()
    }
}

data class ProfileSnapshot(val profiles: List<ControllerProfile> = emptyList(), val selectedID: UUID? = null,
    val defaultID: UUID? = null, val bindingPresentations: List<ProfileBindingPresentations> = emptyList()) {
    val selected: ControllerProfile? get() = profiles.firstOrNull { it.id == selectedID }
    fun applying(message: JSONObject): ProfileSnapshot {
        val array = message.optJSONArray("gamepadProfiles")
        require(array == null || array.length() <= 256) { "Host sent too many profiles." }
        val incoming = array?.let { (0 until it.length()).map { index -> ControllerProfile.parse(it.getJSONObject(index)) } } ?: profiles
        require(incoming.map { it.id }.distinct().size == incoming.size) { "Duplicate profile IDs." }
        val selected = message.optString("gamepadProfileID").takeIf { it.isNotBlank() && it != "null" }
            ?.let(UUID::fromString) ?: selectedID ?: incoming.firstOrNull()?.id
        // Profile arrays carry both orientation variants. The scalar is the legacy active variant.
        val scalar = message.optJSONObject("gamepadCustomization")
        val next = if (array == null && scalar != null && selected != null) incoming.map {
            if (it.id == selected) ControllerProfile.parse(JSONObject(it.source.toString()).put("customization", scalar)) else it
        } else incoming
        val default = if (message.has("defaultGamepadProfileID")) message.optString("defaultGamepadProfileID")
            .takeIf { it.isNotBlank() && it != "null" }?.let(UUID::fromString) else defaultID
        val bindings=message.optJSONArray("bindingPresentations")?.let(BindingPresentations::decode) ?: bindingPresentations
        return ProfileSnapshot(next, selected, default?.takeIf { id -> next.any { it.id == id } }, bindings)
    }
}
