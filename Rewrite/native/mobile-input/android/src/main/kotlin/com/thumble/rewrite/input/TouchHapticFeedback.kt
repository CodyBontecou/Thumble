package com.thumble.rewrite.input

import kotlin.math.ceil
import org.json.JSONObject

/** Retained configuration metadata only, never an input report or remote rumble command. */
data class TouchHapticFeedback(
    val style: Style = Style.light,
    val pattern: Pattern = Pattern.single,
    val intensity: Double = style.defaultIntensity,
    val sharpness: Double = style.defaultSharpness,
    val duration: Double = 0.06,
) {
    enum class Style(val defaultIntensity: Double, val defaultSharpness: Double) {
        none(0.0, 0.0),
        light(.45, .48),
        medium(.62, .56),
        heavy(.82, .66),
        soft(.38, .24),
        rigid(.70, .92),
    }

    enum class Pattern {
        single,
        double,
        pulse,
        buzz,
    }

    val normalized: TouchHapticFeedback
        get() =
            if (style == Style.none)
                copy(pattern = Pattern.single, intensity = 0.0, sharpness = 0.0)
            else this

    companion object {
        fun decode(value: JSONObject): TouchHapticFeedback {
            require(
                value.keys().asSequence().toSet() ==
                    setOf("style", "pattern", "intensity", "sharpness", "duration")
            ) {
                "invalid_haptic_feedback"
            }
            fun number(key: String) =
                (value.get(key) as? Number)?.toDouble() ?: error("invalid_haptic_feedback")
            val feedback =
                TouchHapticFeedback(
                    Style.valueOf(
                        value.get("style") as? String ?: error("invalid_haptic_feedback")
                    ),
                    Pattern.valueOf(
                        value.get("pattern") as? String ?: error("invalid_haptic_feedback")
                    ),
                    number("intensity"),
                    number("sharpness"),
                    number("duration"),
                )
            require(feedback.valid()) { "invalid_haptic_feedback" }
            return feedback.normalized
        }
    }

    fun valid() =
        intensity.isFinite() &&
            intensity in 0.0..1.0 &&
            sharpness.isFinite() &&
            sharpness in 0.0..1.0 &&
            duration.isFinite() &&
            duration in 0.02..0.30
}

data class TouchHapticPulse(val delayMilliseconds: Double, val intensity: Double)

/** UI-thread-only bounded policy, independent of Android/React APIs. */
class TouchHapticPolicy {
    private val owner = Thread.currentThread()
    private var lastObserved: Double? = null
    private var lastStarted: Double? = null

    fun schedule(
        feedback: TouchHapticFeedback,
        nowMilliseconds: Double,
        intensityScale: Double = 1.0,
        enabled: Boolean = true,
    ): List<TouchHapticPulse> {
        check(Thread.currentThread() === owner) { "wrong_feedback_thread" }
        if (
            !nowMilliseconds.isFinite() ||
                nowMilliseconds < 0 ||
                nowMilliseconds > 9007199254740991.0 ||
                lastObserved?.let { nowMilliseconds < it } == true
        )
            return emptyList()
        lastObserved = nowMilliseconds
        if (
            !enabled ||
                !feedback.valid() ||
                feedback.style == TouchHapticFeedback.Style.none ||
                !intensityScale.isFinite() ||
                intensityScale !in 0.0..1.0 ||
                feedback.intensity * intensityScale <= 0 ||
                lastStarted?.let { nowMilliseconds - it < 50 } == true
        )
            return emptyList()
        lastStarted = nowMilliseconds
        val intensity = feedback.intensity * intensityScale
        return when (feedback.pattern) {
            TouchHapticFeedback.Pattern.single,
            TouchHapticFeedback.Pattern.pulse -> listOf(TouchHapticPulse(0.0, intensity))
            TouchHapticFeedback.Pattern.double ->
                listOf(
                    TouchHapticPulse(0.0, intensity),
                    TouchHapticPulse(
                        feedback.duration.coerceIn(0.045, 0.18) * 1000,
                        intensity * 0.85,
                    ),
                )
            TouchHapticFeedback.Pattern.buzz ->
                (0 until ceil(maxOf(feedback.duration, 0.08) / 0.045).toInt().coerceIn(2, 6)).map {
                    TouchHapticPulse(it * 45.0, intensity * if (it % 2 == 0) 0.92 else 0.68)
                }
        }
    }
}
