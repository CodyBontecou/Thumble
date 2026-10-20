package com.thumble.android

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import kotlin.math.*

/** Geometry-only patch: never copies hydrated artwork or appearance into saved layouts. */
internal data class LayoutControlPatch(val id: UUID, val values: Map<String, Double> = emptyMap(), val delete: Boolean = false) {
    init {
        require(values.keys.all { it in setOf("centerX", "centerY", "widthScale", "heightScale", "rotationDegrees") })
        require(values.values.all { it.isFinite() })
    }
    fun applying(snapshot: LayoutSnapshot): LayoutSnapshot {
        val raw = snapshot.json()
        val elements = raw.getJSONArray("elements")
        val index = (0 until elements.length()).firstOrNull { UUID.fromString(elements.getJSONObject(it).getString("id")) == id }
            ?: return snapshot
        val element = elements.getJSONObject(index)
        val builtin = element.optString("kind", "button") == "button" && id.starterSlot() != null
        if (delete && !builtin) {
            elements.remove(index)
            // Legacy mirrors, if present, must not resurrect a deleted custom element.
            raw.optJSONArray("customButtons")?.let { buttons ->
                for (i in buttons.length() - 1 downTo 0) if (buttons.optJSONObject(i)?.optString("id")?.equals(id.toString(), true) == true) buttons.remove(i)
            }
            pruneDeletedReferences(raw)
        } else {
            val overrides = raw.swiftMap("buttonCustomizations")
            val old = if (builtin) overrides[id.toString().uppercase()] as? JSONObject else null
            val style = JSONObject((old ?: element.optJSONObject("layout") ?: JSONObject()).toString())
            if (!delete && style.optBoolean("isLocationLocked")) return snapshot
            if (delete) style.put("isHidden", true)
            values.forEach { (key, value) -> style.put(key, value) }
            if (builtin) {
                // Preserve Swift's alternating UUID-keyed dictionary wire representation.
                val map = JSONArray()
                overrides.forEach { (key, value) -> if (!key.equals(id.toString(), true)) map.put(key).put(value) }
                map.put(id.toString().uppercase()).put(style)
                raw.put("buttonCustomizations", map)
                // Swift setButtonCustomization owns both representations. An old
                // declared layout makes a native echo differ from the pending edit.
                element.put("layout", JSONObject(style.toString()))
            } else {
                element.put("layout", style)
                raw.optJSONArray("customButtons")?.let { mirrors ->
                    repeat(mirrors.length()) { i ->
                        val mirror=mirrors.getJSONObject(i)
                        if(mirror.optString("id").equals(id.toString(),true)) mirror.put("layout",JSONObject(style.toString()))
                    }
                }
            }
        }
        return LayoutSnapshot.capture(raw)
    }
    private fun pruneDeletedReferences(raw: JSONObject) {
        for(field in listOf("labelOverrides","buttonCustomizations")) {
            when(val map=raw.opt(field)) {
                is JSONObject -> map.keys().asSequence().filter { it.equals(id.toString(),true) }.toList().forEach(map::remove)
                is JSONArray -> {
                    for(i in map.length()-2 downTo 0 step 2) if(map.getString(i).equals(id.toString(),true)) {
                        map.remove(i+1);map.remove(i)
                    }
                }
            }
        }
        fun matches(value: Any?) = when(value) {
            is JSONObject -> value.optString("kind")=="custom" && value.optString("id").equals(id.toString(),true)
            is String -> value.startsWith("custom.") && value.substringAfter('.').equals(id.toString(),true)
            else -> false
        }
        fun prune(array: JSONArray?) {
            if(array!=null) for(i in array.length()-1 downTo 0) if(matches(array.opt(i))) array.remove(i)
        }
        raw.optJSONObject("designMetadata")?.let { metadata ->
            prune(metadata.optJSONArray("layerOrder"))
            metadata.optJSONArray("groups")?.let { groups ->
                for(i in groups.length()-1 downTo 0) {
                    val children=groups.getJSONObject(i).optJSONArray("children")
                    prune(children)
                    if(children!=null && children.length()==0) groups.remove(i)
                }
            }
            if(defaultDesignMetadata(metadata,raw.getJSONArray("elements"))) raw.remove("designMetadata")
        }
    }
    private fun defaultDesignMetadata(metadata: JSONObject,elements: JSONArray): Boolean {
        val known=setOf("schemaVersion","layerOrder","groups","grid","guides","notes","tags","sourceTemplateID","sourceTemplateRevision")
        if(metadata.keys().asSequence().any { it !in known }) return false
        fun emptyArray(key: String)=metadata.optJSONArray(key)?.length().let { it==null || it==0 }
        fun emptyText(key: String)=!metadata.has(key) || metadata.isNull(key) || metadata.getString(key).trim().isEmpty()
        if(metadata.optInt("schemaVersion",1)>1 || !emptyArray("groups") || !emptyArray("guides") || !emptyArray("tags") ||
            !emptyText("notes") || !emptyText("sourceTemplateID") || (metadata.has("sourceTemplateRevision") && !metadata.isNull("sourceTemplateRevision"))) return false
        val grid=metadata.optJSONObject("grid")
        if(grid!=null && (grid.keys().asSequence().any { it !in setOf("showsGrid","snapToGrid","snapToObjects","gridSize","snapTolerance") } ||
            grid.optBoolean("showsGrid") || grid.optBoolean("snapToGrid") || !grid.optBoolean("snapToObjects",true) ||
            grid.finite("gridSize",16.0)!=16.0 || grid.finite("snapTolerance",6.0)!=6.0)) return false
        fun identity(value: Any?): String? = when(value) {
            is String -> if('.' in value) value.lowercase() else if(value=="top_bar_activation") "system.$value" else "builtin.${value.lowercase()}"
            is JSONObject -> when(value.optString("kind")) {
                "system" -> "system.${value.optString("system")}" 
                "builtin" -> "builtin.${value.optString("button").lowercase()}"
                "custom" -> "custom.${value.optString("id").lowercase()}"
                else -> null
            }
            else -> null
        }
        val order=metadata.optJSONArray("layerOrder") ?: return true
        if(order.length()==0) return true
        val implicit=mutableListOf("system.top_bar_activation")
        repeat(elements.length()) { i ->
            val element=elements.getJSONObject(i);val uuid=UUID.fromString(element.getString("id"))
            val kind=if(element.optString("kind","button")=="button" && uuid.starterSlot()!=null) "builtin" else "custom"
            implicit += "$kind.${uuid.toString().lowercase()}"
        }
        return (0 until order.length()).map { identity(order.opt(it)) }==implicit
    }
}

internal enum class LayoutResizeCorner(val leading: Boolean, val top: Boolean) {
    TOP_LEFT(true, true), TOP_RIGHT(false, true), BOTTOM_RIGHT(false, false), BOTTOM_LEFT(true, false)
}

/** Matches the iOS editor's unrotated frame resize and canvas-clamped nudge rules. */
internal object LayoutControlEdits {
    fun rotation(value: Double): Double {
        if (!value.isFinite()) return 0.0
        var angle = value % 360
        if (angle > 180) angle -= 360
        if (angle <= -180) angle += 360
        return if (abs(angle) < .001) 0.0 else angle
    }
    fun move(control: Control, frame: ControlFrame, dx: Double, dy: Double, width: Double, height: Double): LayoutControlPatch? {
        if (!editable(control, width, height) || !dx.isFinite() || !dy.isFinite() || (abs(dx) <= .001 && abs(dy) <= .001)) return null
        val halfW = min(width / 2, max(frame.width / 2, 1.0))
        val halfH = min(height / 2, max(frame.height / 2, 1.0))
        return LayoutControlPatch(control.id, mapOf(
            "centerX" to ((frame.centerX + dx).coerceIn(halfW, max(halfW, width - halfW)) / width),
            "centerY" to ((frame.centerY + dy).coerceIn(halfH, max(halfH, height - halfH)) / height)))
    }
    fun rotate(control: Control, delta: Double): LayoutControlPatch? =
        if (control.style.optBoolean("isLocationLocked") || !delta.isFinite() || abs(delta) <= .001) null
        else LayoutControlPatch(control.id, mapOf("rotationDegrees" to rotation(control.style.finite("rotationDegrees", 0.0) + delta)))
    fun scale(control: Control, delta: Double): LayoutControlPatch? =
        if (control.style.optBoolean("isLocationLocked") || !delta.isFinite() || abs(delta) <= .001) null
        else LayoutControlPatch(control.id, mapOf("widthScale" to (control.style.finite("widthScale", 1.0) + delta).coerceIn(.001, 12.0),
            "heightScale" to (control.style.finite("heightScale", 1.0) + delta).coerceIn(.001, 12.0)))
    fun resize(control: Control, frame: ControlFrame, corner: LayoutResizeCorner, dx: Double, dy: Double, width: Double, height: Double): LayoutControlPatch? {
        if (!editable(control, width, height) || !dx.isFinite() || !dy.isFinite() || (abs(dx) <= .001 && abs(dy) <= .001)) return null
        val baseW = max(1.0, frame.width / max(control.style.finite("widthScale", 1.0), .001))
        val baseH = max(1.0, frame.height / max(control.style.finite("heightScale", 1.0), .001))
        fun axis(low: Double, high: Double, delta: Double, leading: Boolean, base: Double, limit: Double): Pair<Double, Double> {
            val minimum = max(1.0, base * .001)
            val maximum = max(minimum, min(limit, base * 12))
            val fixed = if (leading) high else low
            val proposed = if (leading) (low + delta).coerceIn(0.0, max(0.0, high - minimum))
                else (high + delta).coerceIn(low + minimum, max(low + minimum, limit))
            val size = (if (leading) fixed - proposed else proposed - fixed).coerceIn(minimum, maximum)
            return if (leading) fixed - size to fixed else fixed to fixed + size
        }
        val x = axis(frame.left, frame.left + frame.width, dx, corner.leading, baseW, width)
        val y = axis(frame.top, frame.top + frame.height, dy, corner.top, baseH, height)
        return LayoutControlPatch(control.id, mapOf("centerX" to ((x.first + x.second) / 2 / width).coerceIn(0.0, 1.0),
            "centerY" to ((y.first + y.second) / 2 / height).coerceIn(0.0, 1.0),
            "widthScale" to ((x.second - x.first) / baseW).coerceIn(.001, 12.0),
            "heightScale" to ((y.second - y.first) / baseH).coerceIn(.001, 12.0)))
    }
    private fun editable(control: Control, width: Double, height: Double) =
        !control.style.optBoolean("isLocationLocked") && width.isFinite() && height.isFinite() && width > 1 && height > 1
}
