package com.thumble.rewrite.bridge

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.ViewTreeObserver
import android.widget.FrameLayout
import com.thumble.rewrite.input.*
import expo.modules.kotlin.AppContext
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import expo.modules.kotlin.viewevent.EventDispatcher
import expo.modules.kotlin.views.ExpoView

class ThumbleInputModule : Module() {
    override fun definition() = ModuleDefinition {
        Name("ThumbleNativeInput")
        View(ThumbleInputView::class) {
            Events("onAdmission")
            Prop("practiceMap") { view: ThumbleInputView, value: Map<String, Any?> ->
                view.pendingPractice = value
            }
            OnViewDidUpdateProps { view: ThumbleInputView -> view.admitPractice() }
            AsyncFunction("configure") { view: ThumbleInputView, map: Map<String, Any?> ->
                view.configure(map)
            }
            AsyncFunction("setPractice") { view: ThumbleInputView, enabled: Boolean ->
                view.practice(enabled)
            }
            AsyncFunction("release") { view: ThumbleInputView, reason: String ->
                view.release(ReleaseReason.valueOf(reason))
            }
            AsyncFunction("snapshot") { view: ThumbleInputView -> view.snapshot() }
            OnViewDestroys { view: ThumbleInputView -> view.release(ReleaseReason.disposed) }
        }
    }
}

class ThumbleInputView(context: Context, appContext: AppContext) : ExpoView(context, appContext) {
    val onAdmission by EventDispatcher()
    internal var pendingPractice: Map<String, Any?>? = null
    private var practiceAdmitted = false

    internal fun admitPractice() {
        val map = pendingPractice ?: return
        if (practiceAdmitted) return
        practiceAdmitted = true
        try {
            val receipt = configure(map)
            practice(true)
            check(engine.practice && !engine.connected)
            onAdmission(
                mapOf(
                    "admission" to
                        (receipt +
                            mapOf("status" to "ready", "practice" to true, "connected" to false))
                )
            )
        } catch (_: Exception) {
            release(ReleaseReason.disposed)
            onAdmission(mapOf("admission" to mapOf("version" to 1, "status" to "unavailable")))
        }
    }

    private var feedbackState = GamepadReport.neutral()
    val engine =
        InputEngine(
            { false },
            { state ->
                feedbackState = state
                invalidate()
            },
        )
    val surface = InputSurface(context, engine)
    private var configured: ControlMap? = null
    private var disposed = false
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private var portal: TouchPortal? = null
    private var observer: ViewTreeObserver? = null
    private val align = ViewTreeObserver.OnPreDrawListener {
        syncPortal()
        true
    }

    init {
        setWillNotDraw(false)
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        if (disposed) return
        // Activity-owned sibling, outside ReactSurfaceView and its JS dispatcher.
        val content = rootView.findViewById<ViewGroup>(android.R.id.content) ?: return
        val next = TouchPortal(context, this)
        next.addView(surface, FrameLayout.LayoutParams(-1, -1))
        content.addView(next, ViewGroup.LayoutParams(0, 0))
        portal = next
        observer = rootView.viewTreeObserver.also { it.addOnPreDrawListener(align) }
        syncPortal()
    }

    override fun onDetachedFromWindow() {
        detachPortal()
        super.onDetachedFromWindow()
    }

    private fun detachPortal() {
        observer?.takeIf { it.isAlive }?.removeOnPreDrawListener(align)
        observer = null
        portal?.let {
            it.removeView(surface)
            (it.parent as? ViewGroup)?.removeView(it)
        }
        portal = null
        surface.release(ReleaseReason.disconnected)
    }

    internal fun syncPortal(): Boolean {
        val overlay = portal ?: return false
        val host = overlay.parent as? ViewGroup ?: return false
        val visible = Rect()
        val location = IntArray(2)
        getLocationOnScreen(location)
        var ancestor: View? = this
        var opaque = true
        while (ancestor != null) {
            if (ancestor.alpha <= 0f || ancestor.visibility != View.VISIBLE) opaque = false
            ancestor = ancestor.parent as? View
        }
        val available =
            !disposed &&
                configured != null &&
                (engine.practice || engine.connected) &&
                isShown &&
                opaque &&
                width > 0 &&
                height > 0 &&
                getGlobalVisibleRect(visible) &&
                visible == Rect(location[0], location[1], location[0] + width, location[1] + height)
        if (!available) {
            if (overlay.visibility == View.VISIBLE) surface.release(ReleaseReason.disconnected)
            overlay.visibility = View.GONE
            return false
        }
        host.getLocationOnScreen(location)
        val desired =
            FrameLayout.LayoutParams(width, height).apply {
                leftMargin = visible.left - location[0]
                topMargin = visible.top - location[1]
            }
        val old = overlay.layoutParams as? FrameLayout.LayoutParams
        if (
            old == null ||
                old.width != width ||
                old.height != height ||
                old.leftMargin != desired.leftMargin ||
                old.topMargin != desired.topMargin
        ) {
            surface.release(ReleaseReason.rotation)
            overlay.layoutParams = desired
        }
        overlay.visibility = View.VISIBLE
        return true
    }

    internal fun containsControl(x: Float, y: Float): Boolean =
        configured?.controls.orEmpty().any {
            x >= it.x * width &&
                x < (it.x + it.width) * width &&
                y >= it.y * height &&
                y < (it.y + it.height) * height
        }

    private class TouchPortal(context: Context, private val anchor: ThumbleInputView) :
        FrameLayout(context) {
        init {
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        }

        override fun dispatchTouchEvent(event: MotionEvent): Boolean {
            if (!anchor.syncPortal()) return false
            if (
                event.actionMasked == MotionEvent.ACTION_DOWN &&
                    !anchor.containsControl(event.x, event.y)
            )
                return false
            return super.dispatchTouchEvent(event)
        }
    }

    fun configure(raw: Map<String, Any?>): Map<String, Any> {
        check(!disposed) { "disposed" }
        val next = decode(raw)
        val previous = configured
        if (
            previous == null ||
                previous.generation != next.generation ||
                previous.revision != next.revision ||
                previous.controls != next.controls
        ) {
            surface.configure(next)
            configured = next
        }
        return mapOf("version" to 1, "generation" to next.generation, "revision" to next.revision)
    }

    fun practice(enabled: Boolean) {
        check(!disposed) { "disposed" }
        surface.setPractice(enabled)
    }

    fun release(reason: ReleaseReason) {
        if (disposed) return
        if (reason == ReleaseReason.disposed) {
            disposed = true
            detachPortal()
            surface.dispose()
        } else surface.release(reason)
    }

    fun snapshot(): Map<String, Any?> {
        val state = engine.state
        return mapOf(
            "generation" to engine.generation,
            "connected" to engine.connected,
            "practice" to engine.practice,
            "lastRelease" to engine.lastRelease?.name,
            "state" to
                mapOf(
                    "buttons" to state.buttons.map { it.name },
                    "leftStickX" to state.leftStickX,
                    "leftStickY" to state.leftStickY,
                    "rightStickX" to state.rightStickX,
                    "rightStickY" to state.rightStickY,
                    "leftTrigger" to state.leftTrigger,
                    "rightTrigger" to state.rightTrigger,
                ),
        )
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val state = feedbackState
        for (control in configured?.controls.orEmpty()) {
            val left = (control.x * width).toFloat()
            val top = (control.y * height).toFloat()
            val right = ((control.x + control.width) * width).toFloat()
            val bottom = ((control.y + control.height) * height).toFloat()
            val active =
                state.buttons.any { it.name == control.action } ||
                    (control.action == "leftTrigger" && state.leftTrigger > 0) ||
                    (control.action == "rightTrigger" && state.rightTrigger > 0)
            if (active) {
                paint.color = 0x4d007aff
                canvas.drawRoundRect(
                    left,
                    top,
                    right,
                    bottom,
                    12f * resources.displayMetrics.density,
                    12f * resources.displayMetrics.density,
                    paint,
                )
            }
            if (control.action == "leftStick" || control.action == "rightStick") {
                val isLeft = control.action == "leftStick"
                val x = if (isLeft) state.leftStickX else state.rightStickX
                val y = if (isLeft) state.leftStickY else state.rightStickY
                paint.color = 0xa6007aff.toInt()
                canvas.drawCircle(
                    ((left + right) / 2 + x * (right - left) * .32).toFloat(),
                    ((top + bottom) / 2 + y * (bottom - top) * .32).toFloat(),
                    minOf(right - left, bottom - top) * .18f,
                    paint,
                )
            }
        }
    }

    private fun decode(raw: Map<String, Any?>): ControlMap {
        require(raw.keys == setOf("version", "generation", "revision", "controls")) {
            "invalid_control_map"
        }
        fun number(value: Any?): Double =
            (value as? Number)?.toDouble()?.takeIf { it.isFinite() } ?: error("invalid_control_map")
        fun text(value: Any?, limit: Int): String =
            (value as? String)?.takeIf { it.toByteArray(Charsets.UTF_8).size <= limit }
                ?: error("invalid_control_map")
        require(number(raw["version"]) == 1.0) { "invalid_control_map" }
        val controls = raw["controls"] as? List<*> ?: error("invalid_control_map")
        require(controls.size in 1..64) { "invalid_control_map" }
        return ControlMap(
            generation = text(raw["generation"], 20),
            revision = text(raw["revision"], 20),
            controls =
                controls.map { value ->
                    val c = value as? Map<*, *> ?: error("invalid_control_map")
                    require(c.keys == setOf("id", "action", "x", "y", "width", "height")) {
                        "invalid_control_map"
                    }
                    ControlRegion(
                        text(c["id"], 64),
                        text(c["action"], 64),
                        number(c["x"]),
                        number(c["y"]),
                        number(c["width"]),
                        number(c["height"]),
                    )
                },
        )
    }
}
