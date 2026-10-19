package com.thumble.android

import java.util.UUID
import kotlin.math.max
import kotlin.math.min

internal data class ControlFrame(val centerX: Double, val centerY: Double, val width: Double, val height: Double) {
    val left get() = centerX - width / 2
    val top get() = centerY - height / 2
}

internal fun UUID.starterSlot(): Int? = if (mostSignificantBits == 0L && leastSignificantBits in 0x101L..0x10aL)
    (leastSignificantBits - 0x100L).toInt() else null
internal val Control.isBuiltin get() = kind == "button" && id.starterSlot() != null
internal val Control.shape: String get() = style.optString("shape").takeIf { it in setOf("rectangle", "rounded_rectangle", "capsule", "circle", "ellipse", "polygon", "star") }
    ?: when { kind == "joystick" -> "circle"; id.starterSlot() in setOf(9, 10) -> "capsule"; else -> "rounded_rectangle" }

/** GamepadLayoutResolver geometry, independent of Android pixels and font scaling. */
internal object ControlGeometry {
    fun resolve(control: Control, width: Double, height: Double, southpaw: Boolean): ControlFrame {
        val w = max(1.0, width); val h = max(1.0, height)
        val shortest = min(w, h); val landscape = w >= h
        val scale = when (control.scale) { "compact" -> .86; "large" -> 1.14; else -> 1.0 }
        val side = min(86 * scale, max(50 * scale, shortest * (if (landscape) .24 else .20) * scale))
        val base = when (control.kind) {
            "joystick" -> min(128 * scale, max(82 * scale, shortest * (if (landscape) .30 else .24) * scale)).let { it to it }
            "trigger" -> min(148 * scale, max(86 * scale, shortest * (if (landscape) .30 else .24) * scale)) to
                min(58 * scale, max(34 * scale, shortest * (if (landscape) .11 else .09) * scale))
            "trackpad" -> min(230 * scale, max(142 * scale, shortest * (if (landscape) .48 else .42) * scale)) to
                min(150 * scale, max(92 * scale, shortest * (if (landscape) .28 else .24) * scale))
            "text" -> side to max(24.0, side * .58)
            "decoration" -> side to side
            else -> when (control.id.starterSlot()) {
                9 -> side * 1.48 to side * .72
                10 -> side * 1.66 to side * .72
                else -> side to side
            }
        }
        // Native keeps authored aspect ratios for every shape, including circle,
        // and centers an oversized control instead of shrinking its visual frame.
        val cw = base.first * control.style.finite("widthScale", 1.0).coerceIn(.001, 12.0)
        val ch = base.second * control.style.finite("heightScale", 1.0).coerceIn(.001, 12.0)
        val fallback = if (control.isBuiltin) defaultCenter(control.id, southpaw, w, h, cw, ch) else .5 to .5
        val halfW = min(w / 2, max(cw / 2, 1.0)); val halfH = min(h / 2, max(ch / 2, 1.0))
        val x = (control.style.finite("centerX", fallback.first).coerceIn(0.0, 1.0) * w).coerceIn(halfW, max(halfW, w - halfW))
        val y = (control.style.finite("centerY", fallback.second).coerceIn(0.0, 1.0) * h).coerceIn(halfH, max(halfH, h - halfH))
        return ControlFrame(x, y, cw, ch)
    }
}
