package com.thumble.rewrite.input

import android.app.Activity
import android.app.Application
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.view.Choreographer
import android.view.MotionEvent
import android.view.View

enum class InputReleaseOrigin {
    PAUSE,
    STOP,
    SCREEN_OFF,
    DETACH,
    FOCUS_LOST,
    RESIZE,
    DISPOSE,
}

/** Transparent native overlay for the React renderer; stable pointer IDs, never indices. */
class InputSurface(context: Context, val engine: InputEngine, haptics: TouchHapticSink? = null) :
    View(context), Choreographer.FrameCallback {
    private val touchHaptics =
        haptics ?: AndroidTouchHaptics(this) { engine.connected || engine.practice }
    var configuration: ControlMap? = null
        private set

    var firstReleaseOrigin: InputReleaseOrigin? = null
        private set

    private fun releaseFrom(reason: ReleaseReason, origin: InputReleaseOrigin) {
        if (engine.connected && firstReleaseOrigin == null) firstReleaseOrigin = origin
        release(reason)
    }

    private val generations = mutableMapOf<Int, String>()
    private var installedAt = Long.MAX_VALUE
    private var registered = false
    private var disposed = false
    private val lifecycle =
        object : Application.ActivityLifecycleCallbacks {
            override fun onActivityPaused(activity: Activity) {
                if (belongsTo(activity))
                    releaseFrom(ReleaseReason.background, InputReleaseOrigin.PAUSE)
            }

            override fun onActivityStopped(activity: Activity) {
                if (belongsTo(activity))
                    releaseFrom(ReleaseReason.background, InputReleaseOrigin.STOP)
            }

            override fun onActivityDestroyed(activity: Activity) {
                if (belongsTo(activity)) dispose()
            }

            override fun onActivityCreated(activity: Activity, state: Bundle?) {}

            override fun onActivityStarted(activity: Activity) {}

            override fun onActivityResumed(activity: Activity) {}

            override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) {}
        }
    private val screen =
        object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (intent.action == Intent.ACTION_SCREEN_OFF)
                    releaseFrom(ReleaseReason.screenLock, InputReleaseOrigin.SCREEN_OFF)
            }
        }

    private fun cancelHaptics() {
        runCatching { touchHaptics.cancel() }
    }

    private fun belongsTo(activity: Activity): Boolean {
        var owner: Context = context
        while (owner is android.content.ContextWrapper) {
            if (owner === activity) return true
            val base = owner.baseContext
            if (base === owner) break
            owner = base
        }
        return owner === activity
    }

    fun configure(map: ControlMap): ActivationReceipt {
        val receipt = engine.activate(map)
        configuration = map
        cancelHaptics()
        generations.clear()
        installedAt = SystemClock.uptimeMillis()
        return receipt
    }

    fun setPractice(enabled: Boolean) {
        if (enabled == engine.practice) return
        cancelHaptics()
        generations.clear()
        engine.setPractice(enabled)
    }

    fun release(reason: ReleaseReason) {
        cancelHaptics()
        generations.clear()
        installedAt = SystemClock.uptimeMillis()
        engine.cancel(reason)
    }

    fun dispose() {
        if (!disposed) {
            releaseFrom(ReleaseReason.disposed, InputReleaseOrigin.DISPOSE)
            disposed = true
            unregister()
        }
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        if (disposed) return
        val application = context.applicationContext as Application
        application.registerActivityLifecycleCallbacks(lifecycle)
        if (Build.VERSION.SDK_INT >= 33)
            context.registerReceiver(
                screen,
                IntentFilter(Intent.ACTION_SCREEN_OFF),
                Context.RECEIVER_NOT_EXPORTED,
            )
        else context.registerReceiver(screen, IntentFilter(Intent.ACTION_SCREEN_OFF))
        registered = true
        Choreographer.getInstance().postFrameCallback(this)
    }

    private fun unregister() {
        Choreographer.getInstance().removeFrameCallback(this)
        if (registered) {
            (context.applicationContext as Application).unregisterActivityLifecycleCallbacks(
                lifecycle
            )
            context.unregisterReceiver(screen)
            registered = false
        }
    }

    override fun onDetachedFromWindow() {
        releaseFrom(ReleaseReason.disconnected, InputReleaseOrigin.DETACH)
        unregister()
        super.onDetachedFromWindow()
    }

    override fun onWindowFocusChanged(hasWindowFocus: Boolean) {
        super.onWindowFocusChanged(hasWindowFocus)
        if (!hasWindowFocus) releaseFrom(ReleaseReason.background, InputReleaseOrigin.FOCUS_LOST)
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        if (oldw > 0 && oldh > 0 && (w != oldw || h != oldh))
            releaseFrom(ReleaseReason.rotation, InputReleaseOrigin.RESIZE)
    }

    override fun doFrame(frameTimeNanos: Long) {
        if (!isAttachedToWindow || disposed) return
        engine.tick()
        if (!engine.connected && !engine.practice) cancelHaptics()
        Choreographer.getInstance().postFrameCallback(this)
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (disposed || width <= 0 || height <= 0) return false
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN,
            MotionEvent.ACTION_POINTER_DOWN -> {
                if (event.downTime <= installedAt) return true
                val i = event.actionIndex
                val id = event.getPointerId(i)
                val generation = engine.generation
                if (
                    engine.begin(
                        id.toLong(),
                        generation,
                        event.getX(i).toDouble() / width,
                        event.getY(i).toDouble() / height,
                    )
                ) {
                    generations[id] = generation
                    if (engine.connected || engine.practice) {
                        configuration
                            ?.controls
                            ?.asReversed()
                            ?.firstOrNull {
                                it.contains(
                                    event.getX(i).toDouble() / width,
                                    event.getY(i).toDouble() / height,
                                )
                            }
                            ?.let { region ->
                                runCatching {
                                    touchHaptics.accepted(
                                        id.toLong(),
                                        region.hapticFeedback ?: TouchHapticFeedback(),
                                    )
                                }
                            }
                    }
                }
            }
            MotionEvent.ACTION_MOVE ->
                for (i in 0 until event.pointerCount) {
                    val id = event.getPointerId(i)
                    val generation = generations[id] ?: continue
                    engine.move(
                        id.toLong(),
                        generation,
                        event.getX(i).toDouble() / width,
                        event.getY(i).toDouble() / height,
                    )
                }
            MotionEvent.ACTION_UP,
            MotionEvent.ACTION_POINTER_UP -> {
                val id = event.getPointerId(event.actionIndex)
                generations.remove(id)?.let {
                    runCatching { touchHaptics.ended(id.toLong()) }
                    engine.end(id.toLong(), it)
                }
                if (event.actionMasked == MotionEvent.ACTION_UP) performClick()
            }
            MotionEvent.ACTION_CANCEL -> release(ReleaseReason.touchCancelled)
        }
        return true
    }

    override fun performClick(): Boolean {
        super.performClick()
        return true
    }

    companion object {
        /** Attach an already authenticated engine; its admitted map remains authoritative. */
        fun connected(
            context: Context,
            engine: InputEngine,
            haptics: TouchHapticSink? = null,
        ): InputSurface {
            val map = engine.claimTouchSurface()
            return InputSurface(context, engine, haptics).apply {
                configuration = map
                installedAt = SystemClock.uptimeMillis()
            }
        }
    }
}
