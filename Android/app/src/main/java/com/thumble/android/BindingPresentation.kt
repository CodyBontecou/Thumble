package com.thumble.android

import org.json.JSONArray
import org.json.JSONObject
import java.text.Normalizer
import java.util.Locale
import java.util.UUID

/** Display metadata supplied by the Mac, never used to choose or execute outputs. */
data class BindingPresentation(val elementID: UUID, val part: String, val compactText: String, val accessibilityText: String) {
    fun json() = JSONObject().put("input",JSONObject().put("elementID",elementID.toString()).put("part",part))
        .put("compactText",compactText).put("accessibilityText",accessibilityText)
}
data class ProfileBindingPresentations(val profileID: UUID, val orientation: String?, val entries: List<BindingPresentation>) {
    fun json() = JSONObject().put("profileID",profileID.toString()).apply { orientation?.let { put("orientation",it) } }
        .put("entries",JSONArray().apply { entries.forEach { put(it.json()) } })
}
internal object BindingPresentations {
    private val parts=setOf("primary","joystick_up","joystick_down","joystick_left","joystick_right","trigger_digital")
    fun decode(array: JSONArray): List<ProfileBindingPresentations> {
        require(array.length()<=512) { "Too many binding presentation groups." }
        return (0 until array.length()).map { index ->
            val group=array.getJSONObject(index)
            val orientation=if(group.isNull("orientation")) null else group.getString("orientation")
            require(orientation==null || orientation in setOf("portrait","landscape"))
            val entries=group.getJSONArray("entries")
            require(entries.length()<=2048*6) { "Too many binding presentations." }
            ProfileBindingPresentations(UUID.fromString(group.getString("profileID")),orientation,
                (0 until entries.length()).map { entryIndex ->
                    val value=entries.getJSONObject(entryIndex);val input=value.getJSONObject("input")
                    val part=input.getString("part");require(part in parts)
                    BindingPresentation(UUID.fromString(input.getString("elementID")),part,value.getString("compactText"),value.getString("accessibilityText"))
                })
        }
    }
    fun encode(groups: List<ProfileBindingPresentations>) = JSONArray().apply { groups.forEach { put(it.json()) } }
    fun entries(groups: List<ProfileBindingPresentations>,profileID: UUID,landscape: Boolean): List<BindingPresentation> {
        val orientation=if(landscape) "landscape" else "portrait"
        // An explicitly empty orientation group suppresses the common fallback.
        return (groups.firstOrNull { it.profileID==profileID && it.orientation==orientation }
            ?: groups.firstOrNull { it.profileID==profileID && it.orientation==null })?.entries.orEmpty()
    }
    fun text(control: Control,entries: List<BindingPresentation>,accessible: Boolean=false): String? {
        fun lookup(part: String)=entries.firstOrNull { it.elementID==control.id && it.part==part }
            ?.let { if(accessible) it.accessibilityText else it.compactText }
        if(control.kind in setOf("text","decoration")) return null
        if(control.kind=="joystick") {
            val directions=listOf("joystick_up" to if(accessible) "Up " else "↑","joystick_down" to if(accessible) "Down " else "↓",
                "joystick_left" to if(accessible) "Left " else "←","joystick_right" to if(accessible) "Right " else "→")
            return directions.mapNotNull { (part,prefix) -> lookup(part)?.let { prefix+it } }
                .joinToString(if(accessible) ", " else " ").ifEmpty { null }
        }
        return lookup(if(control.kind=="trigger") "trigger_digital" else "primary")
    }
    fun visibleHint(value: String?,label: String,icon: ControlIcon?): String? {
        fun normalized(text: String)=Normalizer.normalize(text.lowercase(Locale.getDefault()),Normalizer.Form.NFD)
            .filterNot { Character.getType(it)==Character.NON_SPACING_MARK.toInt() || it.isWhitespace() || Character.isSpaceChar(it) }
        val trimmed=value?.trim { it.isWhitespace() || Character.isSpaceChar(it) }?.takeIf { it.isNotEmpty() } ?: return null
        if(normalized(trimmed)==normalized(label)) return null
        if(icon?.source=="text" && normalized(trimmed)==normalized(icon.value)) return null
        return trimmed
    }
}
