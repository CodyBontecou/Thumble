package com.thumble.android

import org.json.JSONObject
import kotlin.math.max
import kotlin.math.min

internal data class ControlIcon(val source: String, val value: String, val placement: String, val scale: Double,
    val tint: JSONObject?, val renderingMode: String) {
    companion object {
        fun parse(json: JSONObject?): ControlIcon? {
            if (json == null) return null
            val source = json.optString("source")
            if (source !in setOf("text", "asset", "sf_symbol")) return null
            val value = json.optString("value").trim().take(80)
            if (value.isEmpty()) return null
            return ControlIcon(source, value, json.optString("placement", "center").takeIf { it in setOf("leading", "trailing", "top", "bottom", "center", "background") } ?: "center",
                json.finite("scale", 1.0).coerceIn(.2, 3.0), json.optJSONObject("tintColor"), json.optString("renderingMode", "template"))
        }
    }
}

internal data class IconLayout(val size: Double, val offset: Vector, val labelOffset: Vector, val legendVisible: Boolean)
/** GamepadNativeContentPresentation icon/legend metrics, in density-independent units. */
internal fun iconLayout(control: Control, width: Double, height: Double, content: JSONObject?, icon: ControlIcon?, showsLabels: Boolean): IconLayout {
    val legend = content?.let { if (it.has("legend") && !it.isNull("legend")) it.optString("legend") else null } ?: control.legend
    val visible = control.kind == "text" || (control.kind != "decoration" && showsLabels && control.style.optBoolean("showsIntegratedLabel", true)
        && !(control.kind == "joystick" && control.style.optString("joystickVisualStyle") == "thumbstick")
        && (control.kind in setOf("joystick", "trackpad") || icon?.placement != "center" || ControlTypography.shortLegend(legend)))
    val padding = content?.finite("labelPadding", defaultLabelPadding(control)) ?: defaultLabelPadding(control)
    val labelOffset = if (content?.has("labelPlacement") == true) when (content.optString("labelPlacement")) {
        "top" -> Vector(0.0, -height * .32 + padding); "bottom" -> Vector(0.0, height * .32 - padding)
        "leading" -> Vector(-width * .28 + padding, 0.0); "trailing" -> Vector(width * .28 - padding, 0.0); else -> Vector()
    } else if (control.kind == "joystick") Vector(0.0, height * .34)
        else if (control.kind in setOf("trackpad", "text")) Vector()
        else when (icon?.placement) {
            "leading" -> Vector(width * .11, 0.0); "trailing" -> Vector(-width * .11, 0.0)
            "top" -> Vector(0.0, height * .15); "bottom" -> Vector(0.0, -height * .15); else -> Vector()
        }
    val offset = when (icon?.placement) {
        "leading" -> Vector(-width * .20, 0.0); "trailing" -> Vector(width * .20, 0.0)
        "top" -> Vector(0.0, -height * .18); "bottom" -> Vector(0.0, height * .18); else -> Vector()
    }
    return IconLayout(icon?.let { max(12.0, min(width, height) * .34 * it.scale) } ?: 0.0, offset, labelOffset, visible)
}
internal fun defaultLabelPadding(control: Control): Double = when (control.kind) { "text" -> 2.0; "trackpad" -> 0.0; "trigger" -> 8.0; else -> 4.0 }
