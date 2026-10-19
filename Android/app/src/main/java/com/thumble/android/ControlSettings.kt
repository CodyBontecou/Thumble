package com.thumble.android

import org.json.JSONObject
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.min

internal data class Vector(val x: Double = 0.0, val y: Double = 0.0) {
    val neutral get() = abs(x) < .001 && abs(y) < .001
    fun radialClamp(): Vector {
        val distance = hypot(x, y)
        return if (distance > 1) Vector(x / distance, y / distance) else this
    }
}

/** Canonical element-part wire codes; output bindings remain owned by the Mac. */
enum class InputPart(val wire: Int) {
    PRIMARY(0), JOYSTICK_UP(1), JOYSTICK_DOWN(2), JOYSTICK_LEFT(3), JOYSTICK_RIGHT(4), TRIGGER_DIGITAL(5)
}

internal data class JoystickSettings(
    val target: String? = null, val digital: Boolean = true,
    val deadZone: Double = .12, val sensitivity: Double = 1.0,
    val invertX: Boolean = false, val invertY: Boolean = false, val cardinal: Boolean = false
) {
    fun transform(vector: Vector): Vector {
        var x = vector.x * sensitivity * if (invertX) -1 else 1
        var y = vector.y * sensitivity * if (invertY) -1 else 1
        val distance = hypot(x, y)
        if (distance <= deadZone) return Vector()
        val scaled = min(1.0, (distance - deadZone) / (1 - deadZone).coerceAtLeast(.001))
        x = x / distance * scaled; y = y / distance * scaled
        if (cardinal && abs(x) != abs(y)) {
            if (abs(x) > abs(y)) { y = 0.0; x = if (x >= 0) scaled else -scaled }
            else { x = 0.0; y = if (y >= 0) scaled else -scaled }
        }
        return Vector(x.coerceIn(-1.0, 1.0), y.coerceIn(-1.0, 1.0))
    }
    companion object {
        fun parse(json: JSONObject?): JoystickSettings {
            val target = when (json?.optString("analogTarget")) { "leftStick" -> "left"; "rightStick" -> "right"; else -> null }
            return JoystickSettings(target, json?.optBoolean("sendsDigitalDirections", true) != false || target == null,
                setting(json, "deadZone", .12, 0.0, .85), setting(json, "sensitivity", 1.0, .2, 3.0),
                json?.optBoolean("invertX") == true, json?.optBoolean("invertY") == true, json?.optBoolean("snapToCardinal") == true)
        }
    }
}

internal data class TriggerSettings(val target: String = "right", val horizontal: Boolean = false,
    val deadZone: Double = .03, val sensitivity: Double = 1.0, val digital: Boolean = false, val threshold: Double = .5) {
    fun transform(value: Double): Double {
        val scaled = value.coerceIn(0.0, 1.0) * sensitivity
        return if (scaled <= deadZone) 0.0 else ((scaled - deadZone) / (1 - deadZone).coerceAtLeast(.001)).coerceIn(0.0, 1.0)
    }
    companion object {
        fun parse(json: JSONObject?) = TriggerSettings(if (json?.optString("target") == "left") "left" else "right",
            json?.optString("orientation") == "horizontal", setting(json, "deadZone", .03, 0.0, .85),
            setting(json, "sensitivity", 1.0, .2, 3.0), json?.optBoolean("sendsDigitalButton") == true,
            setting(json, "digitalThreshold", .5, .01, 1.0))
    }
}

internal data class TrackpadSettings(val sensitivity: Double = 1.2, val scrollSensitivity: Double = .85,
    val tap: Boolean = true, val scroll: Boolean = true, val natural: Boolean = true) {
    companion object {
        fun parse(json: JSONObject?) = TrackpadSettings(setting(json, "sensitivity", 1.2, .2, 4.0),
            setting(json, "scrollSensitivity", .85, .1, 4.0), json?.optBoolean("tapToClick", true) != false,
            json?.optBoolean("twoFingerScroll", true) != false, json?.optBoolean("naturalScrolling", true) != false)
    }
}

private fun setting(json: JSONObject?, key: String, fallback: Double, low: Double, high: Double): Double {
    if (json == null || !json.has(key)) return fallback
    return json.optDouble(key, low).takeIf { it.isFinite() }?.coerceIn(low, high) ?: low
}
