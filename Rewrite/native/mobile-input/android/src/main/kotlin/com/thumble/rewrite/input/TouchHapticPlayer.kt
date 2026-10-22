package com.thumble.rewrite.input

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.HapticFeedbackConstants
import android.view.View

object TouchHapticPreferences {
    private const val KEY = "touch-haptic-intensity.v1"

    fun intensity(context: Context): Double = runCatching {
        context
            .getSharedPreferences("rewrite.phone.v1", Context.MODE_PRIVATE)
            .getFloat(KEY, 1f)
            .toDouble()
            .takeIf { it.isFinite() }
            ?.coerceIn(0.0, 1.0) ?: 0.0
    }
        .getOrDefault(0.0)

    fun setEnabled(context: Context, enabled: Boolean) {
        context
            .getSharedPreferences("rewrite.phone.v1", Context.MODE_PRIVATE)
            .edit()
            .putFloat(KEY, if (enabled) 1f else 0f)
            .apply()
    }
}

interface TouchHapticSink {
    fun accepted(id: Long, feedback: TouchHapticFeedback)

    fun ended(id: Long)

    fun cancel()
}

/**
 * Platform effects approximate canonical strength/sharpness/continuous duration.
 * View.performHapticFeedback respects view/global user settings; never ignore them.
 */
internal class AndroidTouchHaptics(private val view: View, private val active: () -> Boolean) :
    TouchHapticSink {
    private val policy = TouchHapticPolicy()
    private val handler = Handler(Looper.getMainLooper())
    private val pending = mutableListOf<Runnable>()
    private var owner: Long? = null

    override fun accepted(id: Long, feedback: TouchHapticFeedback) {
        val pulses =
            policy.schedule(
                feedback,
                SystemClock.uptimeMillis().toDouble(),
                TouchHapticPreferences.intensity(view.context),
                view.isHapticFeedbackEnabled,
            )
        if (pulses.isEmpty()) return
        cancel()
        owner = id
        for (pulse in pulses) {
            val action = Runnable {
                if (
                    owner == id &&
                        active() &&
                        view.isAttachedToWindow &&
                        view.isHapticFeedbackEnabled &&
                        TouchHapticPreferences.intensity(view.context) > 0
                ) {
                    val effect =
                        when (feedback.style) {
                            TouchHapticFeedback.Style.none -> return@Runnable
                            TouchHapticFeedback.Style.light,
                            TouchHapticFeedback.Style.soft -> HapticFeedbackConstants.CLOCK_TICK
                            TouchHapticFeedback.Style.medium,
                            TouchHapticFeedback.Style.rigid -> HapticFeedbackConstants.KEYBOARD_TAP
                            TouchHapticFeedback.Style.heavy -> HapticFeedbackConstants.LONG_PRESS
                        }
                    view.performHapticFeedback(effect)
                }
            }
            if (pulse.delayMilliseconds == 0.0) action.run()
            else {
                pending.add(action)
                handler.postDelayed(action, pulse.delayMilliseconds.toLong())
            }
        }
    }

    override fun ended(id: Long) {
        if (owner == id) cancel()
    }

    override fun cancel() {
        pending.forEach { handler.removeCallbacks(it) }
        pending.clear()
        owner = null
    }
}
