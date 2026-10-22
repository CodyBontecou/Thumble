package com.thumble.rewrite.bridge

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import android.view.MotionEvent
import android.view.View
import android.view.ViewTreeObserver
import android.widget.FrameLayout
import com.thumble.rewrite.input.*
import expo.modules.kotlin.AppContext
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import expo.modules.kotlin.viewevent.EventDispatcher
import expo.modules.kotlin.views.ExpoView
import kotlin.math.ceil

class ThumbleInputModule : Module() {
    override fun definition() = ModuleDefinition {
        Name("ThumbleNativeInput")
        View(ThumbleInputView::class) {
            Events("onAdmission", "onCatalog", "onControlMap")
            Prop("practiceMap") { view: ThumbleInputView, value: Map<String, Any?> ->
                view.pendingPractice = value
            }
            Prop("outputMode") { view: ThumbleInputView, value: String ->
                view.connectionOutputMode = value
            }
            Prop("connect") { view: ThumbleInputView, value: Boolean ->
                view.connectionRequested = value
            }
            Prop("connectionMap") { view: ThumbleInputView, value: Map<String, Any?> ->
                view.pendingConnection = value
            }
            OnViewDidUpdateProps { view: ThumbleInputView ->
                view.admitPractice()
                view.admitConnection()
            }
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
    val onCatalog by EventDispatcher()
    val onControlMap by EventDispatcher()
    internal var connectionRequested = false
    // A different output intent requires a new native view, never an in-place fallback.
    internal var connectionOutputMode = "recording"
        set(value) {
            if (connectionAttempted && value != field) {
                release(ReleaseReason.disposed)
                onAdmission(mapOf("admission" to mapOf("version" to 1, "status" to "unavailable")))
            }
            field = value
        }

    internal var pendingConnection: Map<String, Any?>? = null
    internal var pendingPractice: Map<String, Any?>? = null
    private var practiceAdmitted = false

    internal fun admitPractice() {
        val map = pendingPractice ?: return
        if (practiceAdmitted || connectionRequested || pendingConnection != null) return
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

    private var feedbackPublications = 0L
    val nativeFeedbackPublications: Long
        get() = feedbackPublications

    private var feedbackState = GamepadReport.neutral()
    var engine =
        InputEngine(
            { false },
            { state ->
                if (feedbackPublications < Long.MAX_VALUE) feedbackPublications++
                feedbackState = state
                invalidate()
            },
        )
        private set

    var surface = InputSurface(context, engine)
        private set

    private var liveOwned = false
    private var liveMode = false
    private var connectionAttempted = false
    private var connection: PhoneConnection? = null

    internal fun admitConnection() {
        if (!connectionRequested && pendingConnection == null) return
        if (disposed || connectionAttempted || !isAttachedToWindow || width <= 0 || height <= 0)
            return
        connectionAttempted = true
        try {
            check(pendingPractice == null)
            val outputMode =
                when (connectionOutputMode) {
                    "recording" -> PhoneOutputMode.RECORDING
                    "macos-hid" -> PhoneOutputMode.MACOS_HID
                    else -> error("invalid_output_mode")
                }
            val flow =
                PhoneConnection(
                    this,
                    ::publishFeedback,
                    ::adoptConnectedEngine,
                    status = { status ->
                        onAdmission(mapOf("admission" to mapOf("version" to 1, "status" to status)))
                    },
                    catalogResult = { catalog -> onCatalog(mapOf("catalog" to catalog)) },
                    installedMap = { map -> onControlMap(mapOf("map" to map)) },
                    testOnlyMapProvider = NativeInputTestHost.current(),
                    outputMode = outputMode,
                )
            connection = flow
            flow.start()
        } catch (_: Exception) {
            onAdmission(mapOf("admission" to mapOf("version" to 1, "status" to "unavailable")))
        }
    }

    private fun publishFeedback(state: com.thumble.rewrite.contracts.GamepadStateV1) {
        if (feedbackPublications < Long.MAX_VALUE) feedbackPublications++
        feedbackState = state
        invalidate()
    }

    fun adoptConnectedEngine(next: InputEngine) {
        check(!disposed && isAttachedToWindow)
        val nextSurface = InputSurface.connected(context, next)
        val map = checkNotNull(nextSurface.configuration)
        detachCapture()
        surface.dispose()
        engine = next
        surface = nextSurface
        configured = map
        liveOwned = true
        liveMode = true
        attachCapture()
        check(next.connected)
        onAdmission(
            mapOf(
                "admission" to
                    mapOf(
                        "version" to 1,
                        "status" to "ready",
                        "generation" to map.generation,
                        "revision" to map.revision,
                        "practice" to false,
                        "connected" to true,
                    )
            )
        )
    }

    private var configured: ControlMap? = null
    private var disposed = false
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private var captureHost: FrameLayout? = null
    private val regions = mutableListOf<TouchRegion>()
    val nativeCaptureViews: List<View>
        get() = regions.toList()

    private var captureVisible = false
    private var observer: ViewTreeObserver? = null
    private val align = ViewTreeObserver.OnPreDrawListener {
        syncCapture()
        true
    }

    init {
        setWillNotDraw(false)
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        attachCapture()
        admitConnection()
    }

    private fun attachCapture() {
        if (disposed) return
        // Each region is a direct Activity child, so Android can split a second
        // pointer to navigation instead of assigning it to a full-screen portal.
        val host = rootView.findViewById<FrameLayout>(android.R.id.content) ?: return
        captureHost = host
        // ViewGroupOverlay participates in native attachment/frame callbacks but
        // never receives system touches. Region views forward their own streams.
        host.overlay.add(surface)
        rebuildRegions()
        observer = rootView.viewTreeObserver.also { it.addOnPreDrawListener(align) }
        syncCapture()
    }

    override fun onDetachedFromWindow() {
        connection?.close()
        detachCapture()
        super.onDetachedFromWindow()
    }

    private fun detachCapture() {
        observer?.takeIf { it.isAlive }?.removeOnPreDrawListener(align)
        observer = null
        captureHost?.let { host ->
            regions.forEach { host.removeView(it) }
            host.overlay.remove(surface)
        }
        regions.clear()
        captureHost = null
        captureVisible = false
        surface.release(ReleaseReason.disconnected)
    }

    private fun rebuildRegions() {
        val host = captureHost ?: return
        regions.forEach { host.removeView(it) }
        regions.clear()
        for (control in configured?.controls.orEmpty()) {
            val region = TouchRegion(context, this, control)
            region.visibility = View.GONE
            host.addView(region, FrameLayout.LayoutParams(0, 0))
            regions.add(region)
        }
    }

    internal fun syncCapture(): Boolean {
        if (liveOwned && !engine.connected) {
            liveOwned = false
            connection?.close()
            onAdmission(mapOf("admission" to mapOf("version" to 1, "status" to "disconnected")))
        }
        admitConnection()
        val host = captureHost ?: return false
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
            if (captureVisible) surface.release(ReleaseReason.disconnected)
            captureVisible = false
            regions.forEach { it.visibility = View.GONE }
            return false
        }
        host.getLocationOnScreen(location)
        val left = visible.left - location[0]
        val top = visible.top - location[1]
        if (
            surface.left != left ||
                surface.top != top ||
                surface.width != width ||
                surface.height != height
        ) {
            if (surface.width > 0 && surface.height > 0) surface.release(ReleaseReason.rotation)
            surface.layout(left, top, left + width, top + height)
        }
        for (region in regions) {
            val c = region.control
            val x = (c.x * width).toInt()
            val y = (c.y * height).toInt()
            val w = ceil((c.x + c.width) * width).toInt() - x
            val h = ceil((c.y + c.height) * height).toInt() - y
            val params = region.layoutParams as FrameLayout.LayoutParams
            if (
                params.width != w ||
                    params.height != h ||
                    params.leftMargin != left + x ||
                    params.topMargin != top + y
            ) {
                params.width = w
                params.height = h
                params.leftMargin = left + x
                params.topMargin = top + y
                region.layoutParams = params
            }
            region.visibility = View.VISIBLE
        }
        captureVisible = true
        return true
    }

    private fun containsControl(x: Float, y: Float): Boolean =
        configured?.controls.orEmpty().any {
            x >= it.x * width &&
                x < (it.x + it.width) * width &&
                y >= it.y * height &&
                y < (it.y + it.height) * height
        }

    private class TouchRegion(
        context: Context,
        private val anchor: ThumbleInputView,
        val control: ControlRegion,
    ) : View(context) {
        init {
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }

        // This inaccessible proxy only forwards streams; InputSurface owns performClick.
        @SuppressLint("ClickableViewAccessibility")
        override fun onTouchEvent(event: MotionEvent): Boolean {
            if (!anchor.syncCapture()) return false
            val own = IntArray(2)
            val full = IntArray(2)
            getLocationOnScreen(own)
            anchor.surface.getLocationOnScreen(full)
            val translated = MotionEvent.obtain(event)
            try {
                translated.offsetLocation(
                    (own[0] - full[0]).toFloat(),
                    (own[1] - full[1]).toFloat(),
                )
                if (
                    translated.actionMasked == MotionEvent.ACTION_DOWN &&
                        !anchor.containsControl(translated.x, translated.y)
                )
                    return false
                return anchor.surface.onTouchEvent(translated)
            } finally {
                translated.recycle()
            }
        }
    }

    fun configure(raw: Map<String, Any?>): Map<String, Any> {
        check(!disposed && !liveMode) { "unavailable" }
        val next = decode(raw)
        val previous = configured
        if (
            previous == null ||
                previous.generation != next.generation ||
                previous.revision != next.revision ||
                previous.controls.map {
                    it.copy(
                        hapticFeedback = (it.hapticFeedback ?: TouchHapticFeedback()).normalized
                    )
                } !=
                    next.controls.map {
                        it.copy(
                            hapticFeedback = (it.hapticFeedback ?: TouchHapticFeedback()).normalized
                        )
                    }
        ) {
            surface.configure(next)
            configured = next
            rebuildRegions()
        }
        return mapOf("version" to 1, "generation" to next.generation, "revision" to next.revision)
    }

    fun practice(enabled: Boolean) {
        check(!disposed && !liveMode) { "unavailable" }
        surface.setPractice(enabled)
    }

    fun release(reason: ReleaseReason) {
        if (disposed) return
        if (reason == ReleaseReason.disposed) {
            disposed = true
            connection?.close()
            detachCapture()
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
            val vertical = control.action.endsWith("VerticalTrigger")
            val horizontal = control.action.endsWith("HorizontalTrigger")
            if (vertical || horizontal) {
                val amount =
                    if (control.action.startsWith("left")) state.leftTrigger else state.rightTrigger
                paint.color = 0x4d007aff
                canvas.drawRect(
                    left,
                    if (vertical) (bottom - (bottom - top) * amount).toFloat() else top,
                    if (horizontal) (left + (right - left) * amount).toFloat() else right,
                    bottom,
                    paint,
                )
            } else {
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
            }
            if (
                control.action in
                    listOf("leftStick", "rightStick", "leftStandardStick", "rightStandardStick")
            ) {
                val isLeft = control.action.startsWith("left")
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
                    require(
                        c.keys ==
                            setOf("id", "action", "x", "y", "width", "height") +
                                if (c.containsKey("hapticFeedback")) setOf("hapticFeedback")
                                else emptySet()
                    ) {
                        "invalid_control_map"
                    }
                    ControlRegion(
                        text(c["id"], 64),
                        text(c["action"], 64),
                        number(c["x"]),
                        number(c["y"]),
                        number(c["width"]),
                        number(c["height"]),
                        if (c.containsKey("hapticFeedback"))
                            TouchHapticFeedback.decode(
                                org.json.JSONObject(
                                    c["hapticFeedback"] as? Map<*, *>
                                        ?: error("invalid_haptic_feedback")
                                )
                            )
                        else null,
                    )
                },
        )
    }
}
