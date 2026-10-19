package com.thumble.android

import android.content.Context
import android.media.AudioAttributes
import android.os.Build
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import android.view.View

internal interface KeypadHapticOutput {
    fun play(feedback: KeypadHaptic, intensity: Double)
    fun cancel()
}

/** Touch usage honors Android's user policy; this never requests bypass flags. */
internal class AndroidKeypadHaptics(private val view: View): KeypadHapticOutput {
    private val vibrator: Vibrator? = if (Build.VERSION.SDK_INT >= 31)
        view.context.getSystemService(VibratorManager::class.java)?.defaultVibrator
        else view.context.getSystemService(Vibrator::class.java)
    private var pending: Runnable? = null
    private var playing = false
    override fun play(feedback: KeypadHaptic, intensity: Double) {
        val wave=feedback.waveform(intensity) ?: return
        // Queue after the authoritative input edge; a lifecycle change can retire it.
        pending?.let(view::removeCallbacks)
        val task=Runnable {
            pending=null
            if (!view.isAttachedToWindow || !view.hasWindowFocus() || !view.isShown || !view.isHapticFeedbackEnabled) return@Runnable
            val motor=vibrator ?: return@Runnable
            runCatching {
                if (Settings.System.getInt(view.context.contentResolver,Settings.System.HAPTIC_FEEDBACK_ENABLED,1) == 0 || !motor.hasVibrator()) return@runCatching
                val amplitudes=if (motor.hasAmplitudeControl()) wave.amplitudes else wave.amplitudes.map { if (it == 0) 0 else VibrationEffect.DEFAULT_AMPLITUDE }.toIntArray()
                val effect=VibrationEffect.createWaveform(wave.timings,amplitudes,-1)
                if (Build.VERSION.SDK_INT >= 33) motor.vibrate(effect,VibrationAttributes.createForUsage(VibrationAttributes.USAGE_TOUCH))
                else motor.vibrate(effect,AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
                playing=true
            }
        }
        pending=task;view.post(task)
    }
    override fun cancel() {
        pending?.let(view::removeCallbacks);pending=null
        if (playing) runCatching { vibrator?.cancel() }
        playing=false
    }
}
