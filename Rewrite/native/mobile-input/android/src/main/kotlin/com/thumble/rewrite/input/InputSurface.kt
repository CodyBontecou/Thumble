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

/** Transparent native overlay for the React renderer; stable pointer IDs, never indices. */
class InputSurface(context: Context, val engine: InputEngine) :
    View(context), Choreographer.FrameCallback {
    private val generations = mutableMapOf<Int, String>()
    private var installedAt = Long.MAX_VALUE
    private var registered = false
    private var disposed = false
    private val lifecycle =
        object : Application.ActivityLifecycleCallbacks {
            override fun onActivityPaused(activity: Activity) {
                if (belongsTo(activity)) release(ReleaseReason.background)
            }

            override fun onActivityStopped(activity: Activity) {
                if (belongsTo(activity)) release(ReleaseReason.background)
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
                if (intent.action == Intent.ACTION_SCREEN_OFF) release(ReleaseReason.screenLock)
            }
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
        generations.clear()
        installedAt = SystemClock.uptimeMillis()
        return receipt
    }

    fun setPractice(enabled: Boolean) {
        if (enabled == engine.practice) return
        generations.clear()
        engine.setPractice(enabled)
    }

    private fun release(reason: ReleaseReason) {
        generations.clear()
        engine.cancel(reason)
    }

    fun dispose() {
        if (!disposed) {
            release(ReleaseReason.disposed)
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
        release(ReleaseReason.disconnected)
        unregister()
        super.onDetachedFromWindow()
    }

    override fun onWindowFocusChanged(hasWindowFocus: Boolean) {
        super.onWindowFocusChanged(hasWindowFocus)
        if (!hasWindowFocus) release(ReleaseReason.background)
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        if (oldw > 0 && oldh > 0 && (w != oldw || h != oldh)) release(ReleaseReason.rotation)
    }

    override fun doFrame(frameTimeNanos: Long) {
        if (!isAttachedToWindow || disposed) return
        engine.tick()
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
                )
                    generations[id] = generation
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
                generations.remove(id)?.let { engine.end(id.toLong(), it) }
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
}
