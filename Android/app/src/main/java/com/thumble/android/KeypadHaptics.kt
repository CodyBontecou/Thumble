package com.thumble.android

import org.json.JSONObject
import kotlin.math.*

/** Shared haptic model; time is in seconds, independent of Android's actuator. */
internal data class KeypadHaptic(val style: String = "light", val pattern: String = "single",
    val intensity: Double = .45, val sharpness: Double = .48, val duration: Double = .06) {
    fun json() = JSONObject().put("style",style).put("pattern",pattern).put("intensity",intensity)
        .put("sharpness",sharpness).put("duration",duration)
    fun waveform(globalIntensity: Double = 1.0): HapticWaveform? {
        val strength = (if (intensity.isFinite()) intensity else 0.0).coerceIn(0.0,1.0) * (if (globalIntensity.isFinite()) globalIntensity else 1.0).coerceIn(0.0,1.0)
        if (style == "none" || strength <= 0) return null
        val milliseconds = ((if (duration.isFinite()) duration else .02).coerceIn(.02,.30) * 1000).roundToInt()
        // Android amplitude envelopes approximate Core Haptics' sharpness; frequency
        // is not portable across the API 26+ actuator range.
        val edge=(if (sharpness.isFinite()) sharpness else 0.0).coerceIn(0.0,1.0)
        val attack = (2 + (1-edge)*8).roundToInt()
        val decay = (4 + (1-edge)*12).roundToInt()
        val transientLength = attack + 6 + decay
        val samples = DoubleArray(340)
        fun transient(start: Int, scale: Double = 1.0) {
            for (i in 0 until transientLength) {
                val envelope = when {
                    i < attack -> (i+1.0)/attack
                    i < attack+6 -> 1.0
                    else -> (transientLength-i).toDouble()/decay
                }
                samples[start+i] = min(1.0,samples[start+i]+strength*scale*envelope)
            }
        }
        when (pattern) {
            "double" -> { transient(0); transient(milliseconds.coerceIn(45,180)) }
            "pulse" -> for (i in 0 until max(milliseconds,35)) samples[i] = strength
            "buzz" -> {
                val length=max(milliseconds,80)
                for (i in 0 until length) samples[i]=strength
                transient(0,.85);transient((length*.55).roundToInt(),.85)
            }
            else -> transient(0)
        }
        val last=samples.indexOfLast { it > 0 }
        if (last < 0) return null
        val durations=mutableListOf<Long>();val amplitudes=mutableListOf<Int>()
        for (i in 0..last) {
            val amplitude=if (samples[i] == 0.0) 0 else (samples[i]*255).roundToInt().coerceIn(1,255)
            if (amplitudes.lastOrNull() == amplitude) durations[durations.lastIndex]++
            else { durations.add(1);amplitudes.add(amplitude) }
        }
        return HapticWaveform(durations.toLongArray(),amplitudes.toIntArray())
    }
    companion object {
        private val defaults=mapOf("none" to (0.0 to 0.0),"light" to (.45 to .48),"medium" to (.62 to .56),
            "heavy" to (.82 to .66),"soft" to (.38 to .24),"rigid" to (.70 to .92))
        fun parse(value: JSONObject? = null, legacyStyle: String? = null): KeypadHaptic {
            val style=(value?.optString("style") ?: legacyStyle).takeIf { it in defaults } ?: "light"
            val baseline=defaults.getValue(style)
            fun number(key: String, fallback: Double, low: Double, high: Double): Double =
                if (value?.has(key) == true) value.finite(key,low).coerceIn(low,high) else fallback
            return KeypadHaptic(style,if (style == "none") "single" else value?.optString("pattern").takeIf { it in setOf("single","double","pulse","buzz") } ?: "single",
                if (style == "none") 0.0 else number("intensity",baseline.first,0.0,1.0),
                if (style == "none") 0.0 else number("sharpness",baseline.second,0.0,1.0),number("duration",.06,.02,.30))
        }
    }
}
internal data class HapticWaveform(val timings: LongArray, val amplitudes: IntArray)

internal object HapticIntensity {
    val levels=listOf(0.0,.25,.5,.75,1.0)
    fun normalized(value: Double) = if (value.isFinite()) value.coerceIn(0.0,1.0) else 1.0
    fun label(value: Double) = normalized(value).let { if (it == 0.0) "Off" else "${(it*100).roundToInt()}%" }
}
