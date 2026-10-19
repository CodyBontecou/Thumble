package com.thumble.android

import org.json.JSONArray
import org.json.JSONObject

internal enum class PresentationState { NORMAL, PRESSED, ACTIVE, DISABLED }

/** Native baseline → applicable token → inline style, with per-field state inheritance. */
internal object ControlPresentation {
    fun effectiveScale(control: Control, engaged: Boolean, presentation: JSONObject): Float {
        val multiplier = if (!engaged) 1.0 else when (control.kind) { "button" -> .94; "trackpad" -> .97; else -> 1.0 }
        return (presentation.finite("scale", 1.0) * multiplier).toFloat()
    }
    fun resolve(control: Control, canvas: JSONObject, state: PresentationState, dark: Boolean): JSONObject {
        val style = control.style
        val engaged = state == PresentationState.PRESSED || state == PresentationState.ACTIVE
        val prefix = if (dark) "dark" else "light"
        val authored = style.optJSONObject("${prefix}FillStyle") ?: style.optJSONObject("fillStyle")
            ?: (style.optJSONObject("${prefix}FillColor") ?: style.optJSONObject("fillColor"))?.let { solid(it) }
        val accent = style.optString("accentStyle").ifEmpty { canvas.optString("accentStyle", "monochrome") }
        val palette = palette(accent, dark)
        val fill = authored?.let { if (engaged) pressedFill(it) else it } ?: solid(hex(palette[if (engaged) 2 else 0]))
        val representative = representative(fill)
        val foreground = if (authored != null) {
            if (representative.finite("red", 0.0) * .299 + representative.finite("green", 0.0) * .587 + representative.finite("blue", 0.0) * .114 > .56) hex("000000") else hex("ffffff")
        } else if (engaged) hex(if (dark) "000000" else "ffffff") else hex(palette[2])
        val stroke = if (authored != null) color(representative.finite("red", 0.0) * .76, representative.finite("green", 0.0) * .76,
            representative.finite("blue", 0.0) * .76, (representative.finite("alpha", 1.0) + .14).coerceIn(.32, 1.0))
            else hex(palette[if (engaged) 3 else 1])
        val shadowStrength = style.finite("shadowStrength", 1.0).coerceIn(0.0, 2.0)
        val result = JSONObject().put("fillStyle", fill).put("foregroundColor", foreground).put("strokeColor", stroke)
            .put("strokeWidth", if (engaged) 2 else 1).put("opacity", if (state == PresentationState.DISABLED) .45 else 1)
            .put("scale", if (engaged) .96 else 1).put("shadowColor", color(0.0, 0.0, 0.0, (if (engaged) .16 else .04) * shadowStrength))
            .put("shadowRadius", (if (engaged) 2 else 1) * maxOf(.25, shadowStrength)).put("shadowX", 0).put("shadowY", (if (engaged) 1 else 2) * shadowStrength)
        val styles = canvas.optJSONObject("styleLibrary")?.optJSONArray("styles")
        val requested = normalizedStyleID(style.optString("styleID"))
        if (requested.isNotEmpty()) for (index in 0 until (styles?.length() ?: 0)) {
            val token = styles!!.optJSONObject(index) ?: continue
            if (normalizedStyleID(token.optString("id")) != requested || token.optString("name").isBlank()) continue
            val applies = token.optJSONArray("appliesTo")
            if (applies == null || applies.length() == 0 || (0 until applies.length()).any { applies.optString(it) == control.kind }) {
                token.optJSONObject("visualStyle")?.let { apply(result, it, state) }
            }
            break // First normalized token owns an ID, even if it does not apply to this kind.
        }
        style.optJSONObject("visualStyle")?.let { apply(result, it, state) }
        style.optJSONObject("icon")?.let { result.put("icon", it) }
        result.optJSONObject("content")?.optJSONObject("icon")?.let { result.put("icon", it) }
        normalize(result)
        return result
    }
    private fun apply(result: JSONObject, visual: JSONObject, state: PresentationState) {
        val normal = visual.optJSONObject("normal") ?: JSONObject()
        val override = when (state) {
            PresentationState.NORMAL -> null
            PresentationState.PRESSED -> visual.optJSONObject("pressed")
            PresentationState.ACTIVE -> visual.optJSONObject("active") ?: visual.optJSONObject("pressed")
            PresentationState.DISABLED -> visual.optJSONObject("disabled")
        }
        val stateStyle = merge(JSONObject(), normal)
        if (override != null) merge(stateStyle, override)
        // Native color-only effects acquire usable defaults before explicit
        // radii/opacity/width from this same state are applied (including zero).
        if (stateStyle.has("innerShadowColor") && result.finite("innerShadowRadius",0.0) <= 0) result.put("innerShadowRadius",4)
        if (stateStyle.has("highlightColor")) {
            if (result.finite("highlightOpacity",0.0) <= 0) result.put("highlightOpacity",.42)
            if (result.finite("highlightRadius",0.0) <= 0) result.put("highlightRadius",8)
        }
        if ((stateStyle.has("bevelHighlightColor") || stateStyle.has("bevelShadowColor")) && result.finite("bevelWidth",0.0) <= 0) result.put("bevelWidth",1)
        merge(result, stateStyle)
        visual.optJSONObject("icon")?.let { result.put("icon", it) }
    }
    private fun merge(base: JSONObject, overlay: JSONObject): JSONObject {
        for (key in overlay.keys()) if (!overlay.isNull(key)) {
            val value = overlay.get(key)
            if (key in setOf("content", "pointing") && value is JSONObject) {
                val nested = JSONObject(base.optJSONObject(key)?.toString() ?: "{}")
                base.put(key, merge(nested, value))
            } else base.put(key, value)
        }
        return base
    }
    private fun normalize(result: JSONObject) {
        val ranges = mapOf("strokeWidth" to (0.0 to 12.0), "opacity" to (0.0 to 1.0), "scale" to (.5 to 1.5), "shadowRadius" to (0.0 to 48.0),
            "shadowX" to (-64.0 to 64.0), "shadowY" to (-64.0 to 64.0), "blurRadius" to (0.0 to 24.0), "glowRadius" to (0.0 to 64.0),
            "innerShadowRadius" to (0.0 to 64.0),"innerShadowX" to (-64.0 to 64.0),"innerShadowY" to (-64.0 to 64.0),
            "highlightRadius" to (0.0 to 64.0),"highlightX" to (-64.0 to 64.0),"highlightY" to (-64.0 to 64.0),"highlightOpacity" to (0.0 to 1.0),
            "bevelWidth" to (0.0 to 24.0),"indexWidth" to (0.0 to 12.0))
        for ((key, range) in ranges) if (result.has(key)) result.put(key, result.finite(key, range.first).coerceIn(range.first, range.second))
        result.optJSONObject("content")?.let { content ->
            for ((key, range) in mapOf("fontSize" to (8.0 to 72.0), "tracking" to (-4.0 to 12.0), "labelPadding" to (0.0 to 32.0))) {
                if (content.has(key)) content.put(key, content.finite(key, range.first).coerceIn(range.first, range.second))
            }
            if (content.has("lineLimit")) content.put("lineLimit", content.optInt("lineLimit", 1).coerceIn(1, 4))
        }
    }
    private fun pressedFill(source: JSONObject): JSONObject {
        if (source.optString("kind") == "image") return source
        val copy = JSONObject(source.toString())
        when (copy.optString("kind")) {
            "solid" -> copy.put("color", darkened(copy.optJSONObject("color")))
            "gradient" -> copy.optJSONObject("gradient")?.optJSONArray("stops")?.let { stops ->
                for (i in 0 until stops.length()) stops.getJSONObject(i).put("color", darkened(stops.getJSONObject(i).optJSONObject("color")))
            }
            "tile" -> copy.optJSONObject("tile")?.let { tile ->
                for (key in listOf("foregroundColor", "backgroundColor")) tile.put(key, darkened(tile.optJSONObject(key)))
            }
            // Native intentionally leaves image fills unchanged when pressed.
        }
        return copy
    }
    private fun darkened(value: JSONObject?): JSONObject = color((value?.finite("red", 0.0) ?: 0.0) * .74,
        (value?.finite("green", 0.0) ?: 0.0) * .74, (value?.finite("blue", 0.0) ?: 0.0) * .74, value?.finite("alpha", 1.0) ?: 1.0)
    private fun representative(fill: JSONObject): JSONObject = when (fill.optString("kind")) {
        "gradient" -> {
            val stops = fill.optJSONObject("gradient")?.optJSONArray("stops") ?: JSONArray()
            val colors = (0 until stops.length()).map { stops.getJSONObject(it).optJSONObject("color") ?: hex("121212") }
            if (colors.isEmpty()) hex("121212") else {
                fun average(key: String, default: Double) = colors.sumOf { it.finite(key, default) } / colors.size
                color(average("red", 0.0), average("green", 0.0), average("blue", 0.0), average("alpha", 1.0))
            }
        }
        "tile" -> {
            val tile = fill.optJSONObject("tile") ?: JSONObject()
            val fg = tile.optJSONObject("foregroundColor") ?: hex("ffffff"); val bg = tile.optJSONObject("backgroundColor") ?: hex("121212")
            fun mixed(key: String) = bg.finite(key, 0.0) * .72 + fg.finite(key, 1.0) * .28
            color(mixed("red"), mixed("green"), mixed("blue"), tile.finite("opacity", 1.0))
        }
        "image" -> color(.12, .12, .14, fill.optJSONObject("image")?.finite("opacity", 1.0) ?: 1.0)
        else -> fill.optJSONObject("color") ?: hex("121212")
    }
    private fun solid(color: JSONObject) = JSONObject().put("kind", "solid").put("color", color)
    private fun color(r: Double, g: Double, b: Double, a: Double = 1.0) = JSONObject().put("red", r.coerceIn(0.0, 1.0)).put("green", g.coerceIn(0.0, 1.0)).put("blue", b.coerceIn(0.0, 1.0)).put("alpha", a.coerceIn(0.0, 1.0))
    private fun hex(raw: String): JSONObject {
        val rgb = raw.take(6).toInt(16)
        return color((rgb shr 16 and 255) / 255.0, (rgb shr 8 and 255) / 255.0, (rgb and 255) / 255.0,
            if (raw.length == 8) raw.takeLast(2).toInt(16) / 255.0 else 1.0)
    }
    private fun palette(accent: String, dark: Boolean): List<String> {
        val chromatic = if (dark) mapOf("blue" to listOf("06193a", "003674", "47a8ff"), "green" to listOf("002608", "004615", "00ca50"),
            "purple" to listOf("290c33", "541a76", "c472fb"), "pink" to listOf("310d1e", "5d0c34", "ff4d8d"))
            else mapOf("blue" to listOf("f0f7ff", "cae7ff", "005ff2"), "green" to listOf("ecfdec", "b9f5bc", "107d32"),
                "purple" to listOf("faf0ff", "f2d9ff", "7d00cc"), "pink" to listOf("ffe8f6", "ffd3e1", "c41562"))
        return chromatic[accent]?.let { it + it[2] } ?: if (dark) listOf("1a1a1a", "ffffff24", "ededed", "ffffff82") else listOf("f2f2f2", "00000014", "171717", "0000003d")
    }
}
