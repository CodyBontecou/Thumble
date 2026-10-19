package com.thumble.android

import android.content.Context
import android.graphics.Color
import android.graphics.Canvas
import android.graphics.Paint
import android.os.Bundle
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import android.view.MotionEvent
import android.view.ViewGroup
import android.widget.TextView
import android.graphics.drawable.StateListDrawable
import org.json.JSONObject
import java.util.UUID
import kotlin.math.*

/** Native children expose labels to accessibility; one router owns all simultaneous pointers. */
internal class ControllerSurface(context: Context, private val legacyArtworkBlending: Boolean = android.os.Build.VERSION.SDK_INT < 29) : ViewGroup(context) {
    var onEdge: (UUID, Boolean, Long) -> Unit = { _, _, _ -> }
    var onReleaseAll: () -> Unit = {}
    var onPartEdge: (UUID, InputPart, Boolean, Long) -> Unit = { _, _, _, _ -> }
    var onStick: (String, Double, Double, Boolean) -> Unit = { _, _, _, _ -> }
    var onTrigger: (String, Double, Boolean) -> Unit = { _, _, _ -> }
    var onPointer: (String, Double, Double, String?, Boolean?) -> Unit = { _, _, _, _, _ -> }
    private val router = ControlGestures(::hit, ::local,
        { id, down, press -> onEdge(id, down, press) },
        { id, part, down, press -> onPartEdge(id, part, down, press) },
        { target, x, y, final -> onStick(target, x, y, final) },
        { target, value, final -> onTrigger(target, value, final) },
        { kind, x, y, button, down -> onPointer(kind, x, y, button, down) })
    private val indicatorPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private var controls = emptyList<Control>()
    private var currentProfile: ControllerProfile? = null
    private var currentRevision = -1L
    private var currentLandscape = false
    private var dark = false
    private var canvasLayout = JSONObject()
    private var assets = AssetImages()
    private var effectCache = EffectRasterCache()
    private var artwork = ArtworkPainter(null, assets, resources.displayMetrics.density, legacyArtworkBlending)
    private var legacyArtworkBuffer: android.graphics.Bitmap? = null
    private data class Faces(val normal: JSONObject, val engaged: JSONObject)
    private var faces = emptyList<Faces>()
    private var accessibilityPress = 1_000_000_000L

    fun show(profile: ControllerProfile?, revision: Long, landscape: Boolean, isDark: Boolean) {
        val layout = profile?.layout(landscape) ?: JSONObject()
        val resolvedDark = when (layout.optString("colorSchemePreference")) { "dark" -> true; "light" -> false; else -> isDark }
        if (currentProfile === profile && currentRevision == revision && currentLandscape == landscape && dark == resolvedDark) return
        if (currentProfile != null) cancelTouches()
        currentProfile = profile; currentRevision = revision; currentLandscape = landscape; dark = resolvedDark
        controls = profile?.controls(landscape).orEmpty()
        canvasLayout = layout
        assets = AssetImages(layout.optJSONObject("assetLibrary") ?: JSONObject())
        effectCache = EffectRasterCache()
        clipChildren = false
        artwork = ArtworkPainter(layout.optJSONArray("artworkLayers"), assets, resources.displayMetrics.density, legacyArtworkBlending)
        artwork.resize(width, height)
        if (!artwork.requiresSoftwareBuffer) legacyArtworkBuffer = null
        faces = controls.map { control -> Faces(ControlPresentation.resolve(control, layout, PresentationState.NORMAL, dark),
            ControlPresentation.resolve(control, layout, if (control.kind in setOf("joystick", "trigger", "trackpad")) PresentationState.ACTIVE else PresentationState.PRESSED, dark)) }
        removeAllViews()
        controls.forEach { control ->
            addView(ControlFaceView(context).apply {
                drawIndicator = { canvas -> drawIndicator(canvas, control, width, height) }
                text = if (control.kind == "text" || (control.kind != "decoration" && !(control.kind == "joystick" && control.style.optString("joystickVisualStyle") == "thumbstick") && canvasLayout.optBoolean("showsButtonLabels", true) && control.style.optBoolean("showsIntegratedLabel", true))) control.legend.take(120) else ""
                gravity = android.view.Gravity.CENTER
                textSize = 14f
                setPadding(4.dp, 2.dp, 4.dp, 2.dp)
                maxLines = 1
                includeFontPadding = false
                typeface = android.graphics.Typeface.create("sans-serif-medium", android.graphics.Typeface.NORMAL)
                setAutoSizeTextTypeUniformWithConfiguration(8, if (control.legend.length <= 2) 32 else 16, 1, android.util.TypedValue.COMPLEX_UNIT_SP)
                ellipsize = android.text.TextUtils.TruncateAt.END
                contentDescription = control.accessibilityName
                isClickable = control.kind in setOf("button", "joystick", "trackpad")
                isFocusable = control.kind in setOf("button", "joystick", "trigger", "trackpad")
                importantForAccessibility = if (control.kind == "decoration") IMPORTANT_FOR_ACCESSIBILITY_NO else IMPORTANT_FOR_ACCESSIBILITY_YES
                if (isClickable) setOnClickListener {
                    when (control.kind) {
                        "button" -> {
                            val token = ++accessibilityPress
                            onEdge(control.id, true, token); onEdge(control.id, false, token)
                        }
                        "joystick" -> router.accessibilityDirection(control, InputPart.JOYSTICK_UP)
                        "trackpad" -> router.click("left")
                    }
                    renderColors(); invalidate()
                }
                accessibilityDelegate = controlAccessibility(control)
                rotation = (control.style.finite("rotationDegrees", 0.0) % 360.0).toFloat()
            })
        }
        val backgroundFill = canvasLayout.optJSONObject(if (dark) "backgroundDarkFillStyle" else "backgroundLightFillStyle")
            ?: canvasLayout.optJSONObject("backgroundFillStyle")
            ?: JSONObject().put("kind", "solid").put("color", canvasLayout.optJSONObject(if (dark) "backgroundDarkColor" else "backgroundLightColor")
                ?: rgbaJSON(if (dark) 0xFF10141C.toInt() else 0xFFF4F6FA.toInt()))
        setBackground(ControlDrawable("rectangle", JSONObject(), backgroundFill, resources.displayMetrics.density, assets))
        renderColors()
        requestLayout()
    }
    private val Int.dp: Int get() = (this * resources.displayMetrics.density).roundToInt()
    private fun renderColors() {
        val pressed = router.pressedIDs()
        controls.forEachIndexed { index, control ->
            val view = getChildAt(index) as TextView
            val engaged = when (control.kind) {
                "joystick" -> router.joystickVectors[control.id]?.neutral == false
                "trigger" -> (router.triggerValues[control.id] ?: 0.0) > TriggerSettings.parse(control.source.optJSONObject("triggerSettings")).deadZone
                else -> control.id in pressed
            }
            val pair = faces[index]
            val face = if (engaged) pair.engaged else pair.normal
            view.setTextColor(rgbaColor(face.optJSONObject("foregroundColor"), if (dark) Color.WHITE else Color.BLACK))
            view.isPressed = engaged
            if (control.kind != "text" && view.background !is StateListDrawable) {
                fun drawable(presentation: JSONObject) = ControlDrawable(control.shape, control.style, presentation.getJSONObject("fillStyle"), resources.displayMetrics.density, assets, presentation,effectCache)
                view.background = StateListDrawable().apply {
                    addState(intArrayOf(android.R.attr.state_pressed), drawable(pair.engaged))
                    addState(intArrayOf(), drawable(pair.normal))
                }
            }
            view.alpha = face.finite("opacity", 1.0).toFloat()
            view.scaleX = ControlPresentation.effectiveScale(control, engaged, face); view.scaleY = view.scaleX
            val faceView = view as ControlFaceView
            faceView.effectSignature = when (control.kind) {
                "joystick" -> router.joystickVectors[control.id].toString()
                "trigger" -> router.triggerValues[control.id].toString()
                else -> "static"
            }
            if (faceView.appliedPresentation !== face) {
                applyContent(view, control, face)
                faceView.appliedPresentation = face
            }
            view.invalidate()
        }
    }
    private fun applyContent(view: TextView, control: Control, face: JSONObject) {
        val content = face.optJSONObject("content")
        val icon = ControlIcon.parse(face.optJSONObject("icon"))
        val faceView = view as ControlFaceView
        faceView.configure(control, content, icon, assets, canvasLayout.optBoolean("showsButtonLabels", true),effectCache)
        val visible = faceView.metrics.legendVisible
        val legend = content?.let { if (it.has("legend") && !it.isNull("legend")) it.optString("legend") else null } ?: control.legend
        val text = if (visible) legend else ""
        if (view.text.toString() != text) view.text = text
        val family = when (content?.optString("fontDesign")) { "serif" -> "serif"; "monospaced" -> "monospace"; else -> "sans-serif" }
        val weight = when (content?.optString("fontWeight")) { "regular" -> 400; "medium" -> 500; "bold" -> 700; else -> 600 }
        view.typeface = if (android.os.Build.VERSION.SDK_INT >= 28) android.graphics.Typeface.create(android.graphics.Typeface.create(family, android.graphics.Typeface.NORMAL), weight, false)
            else android.graphics.Typeface.create(if (weight in 500..600 && family == "sans-serif") "sans-serif-medium" else family, if (weight >= 700) android.graphics.Typeface.BOLD else android.graphics.Typeface.NORMAL)
        view.maxLines = content?.optInt("lineLimit", 1) ?: 1
        val font = content?.optDouble("fontSize")?.takeIf { it.isFinite() }
        if (font != null) {
            view.setAutoSizeTextTypeWithDefaults(TextView.AUTO_SIZE_TEXT_TYPE_NONE)
            view.setTextSize(android.util.TypedValue.COMPLEX_UNIT_SP, font.toFloat())
        } else view.setAutoSizeTextTypeUniformWithConfiguration(8, if (legend.length <= 2) 32 else 16, 1, android.util.TypedValue.COMPLEX_UNIT_SP)
        view.letterSpacing = ((content?.finite("tracking", 0.0) ?: 0.0) / (font ?: 16.0)).toFloat()
        val padding = ((content?.finite("labelPadding", defaultLabelPadding(control)) ?: defaultLabelPadding(control)) * resources.displayMetrics.density).roundToInt()
        view.setPadding(padding, 2.dp, padding, 2.dp)
        view.gravity = android.view.Gravity.CENTER_VERTICAL or when (content?.optString("alignment")) {
            "leading" -> android.view.Gravity.START; "trailing" -> android.view.Gravity.END; else -> android.view.Gravity.CENTER_HORIZONTAL
        }
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        setMeasuredDimension(MeasureSpec.getSize(widthMeasureSpec), MeasureSpec.getSize(heightMeasureSpec))
    }
    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        artwork.resize(w, h)
        legacyArtworkBuffer = null
    }
    override fun draw(canvas: Canvas) {
        if (!artwork.requiresSoftwareBuffer || width <= 0 || height <= 0) { super.draw(canvas); return }
        val bitmap = legacyArtworkBuffer ?: android.graphics.Bitmap.createBitmap(width, height, android.graphics.Bitmap.Config.ARGB_8888).also { legacyArtworkBuffer = it }
        bitmap.eraseColor(Color.TRANSPARENT)
        super.draw(Canvas(bitmap))
        canvas.drawBitmap(bitmap, 0f, 0f, null)
    }
    override fun dispatchDraw(canvas: Canvas) {
        val saved = canvas.save(); canvas.clipRect(0,0,width,height)
        artwork.draw(canvas, "underlay", legacyArtworkBuffer)
        super.dispatchDraw(canvas)
        artwork.draw(canvas, "overlay", legacyArtworkBuffer)
        canvas.restoreToCount(saved)
    }
    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        val density = resources.displayMetrics.density
        val w = width.toDouble() / density
        val h = height.toDouble() / density
        controls.forEachIndexed { index, control ->
            val frame = ControlGeometry.resolve(control, w, h, canvasLayout.optString("layoutMode") == "southpaw")
            val cw = frame.width; val ch = frame.height
            val insets = control.style.optJSONObject("hitInsets")
            fun inset(key: String) = insets?.finite(key, 0.0)?.coerceIn(0.0, 96.0) ?: 0.0
            val dx = (inset("leading") - inset("trailing")) / 2
            val dy = (inset("top") - inset("bottom")) / 2
            val angle = Math.toRadians(control.style.finite("rotationDegrees", 0.0) % 360)
            // Native positions the rotated interaction frame at hitCenter, then
            // offsets the face inside it. At zero rotation these offsets cancel.
            val passive = control.kind in setOf("text", "decoration")
            val cx = frame.centerX + if (passive) 0.0 else -dx + dx * cos(angle) - dy * sin(angle)
            val cy = frame.centerY + if (passive) 0.0 else -dy + dx * sin(angle) + dy * cos(angle)
            val child = getChildAt(index)
            val pxW = max(1, (cw * density).roundToInt()); val pxH = max(1, (ch * density).roundToInt())
            child.measure(MeasureSpec.makeMeasureSpec(pxW, MeasureSpec.EXACTLY), MeasureSpec.makeMeasureSpec(pxH, MeasureSpec.EXACTLY))
            val x = ((cx - cw / 2) * density).roundToInt(); val y = ((cy - ch / 2) * density).roundToInt()
            child.layout(x, y, x + pxW, y + pxH)
        }
    }
    private fun visualLocal(control: Control, point: Vector): LocalContact {
        val index = controls.indexOfFirst { it.id == control.id }
        if (index < 0) return LocalContact(0.0, 0.0, 1.0, 1.0)
        val child = getChildAt(index)
        val density = resources.displayMetrics.density
        val w = child.width / density.toDouble(); val h = child.height / density.toDouble()
        val dx = point.x - child.left / density - w / 2; val dy = point.y - child.top / density - h / 2
        val angle = Math.toRadians(-child.rotation.toDouble())
        return LocalContact(dx * cos(angle) - dy * sin(angle) + w / 2, dx * sin(angle) + dy * cos(angle) + h / 2, w, h)
    }
    private fun local(control: Control, point: Vector): LocalContact {
        val p = visualLocal(control, point)
        val insets = control.style.optJSONObject("hitInsets")
        if (insets == null && control.kind == "joystick") {
            val visualSide = min(p.width, p.height)
            val side = if (control.style.optString("joystickVisualStyle") == "thumbstick") max(104.0, max(visualSide + 20, visualSide * 2.55)) else visualSide + 20
            return LocalContact(p.x + (side - p.width) / 2, p.y + (side - p.height) / 2, side, side)
        }
        fun inset(key: String) = if (insets == null) 10.0 else insets.finite(key, 0.0).coerceIn(0.0, 96.0)
        val leading = inset("leading"); val trailing = inset("trailing"); val top = inset("top"); val bottom = inset("bottom")
        return LocalContact(p.x + leading, p.y + top, p.width + leading + trailing, p.height + top + bottom)
    }
    private fun containsHit(control: Control, point: Vector, outset: Double = 0.0): Boolean {
        val p = local(control, point)
        if (p.width <= 0 || p.height <= 0 || p.x !in -outset..(p.width + outset) || p.y !in -outset..(p.height + outset)) return false
        if (control.kind == "joystick" && control.style.optString("joystickVisualStyle") == "thumbstick") {
            val visual = visualLocal(control, point)
            val radius = max(44.0, min(visual.width, visual.height)) / 2
            return hypot(p.x - p.width / 2, p.y - p.height / 2) <= radius
        }
        // Native iOS deliberately gives circular/capsule buttons rectangular hit bounds.
        val shape = control.shape
        if (control.kind != "button" || shape !in setOf("polygon", "star")) return true
        val count = if (shape == "star") 10 else 3
        val polygon = (0 until count).map { index ->
            val angle = -Math.PI / 2 + index * 2 * Math.PI / count
            val scale = if (shape == "star" && index % 2 != 0) .45 else 1.0
            Vector(p.width / 2 + cos(angle) * (p.width / 2 + outset) * scale,
                p.height / 2 + sin(angle) * (p.height / 2 + outset) * scale)
        }
        var inside = false
        var previous = polygon.last()
        for (vertex in polygon) {
            if ((vertex.y > p.y) != (previous.y > p.y) && p.x < (previous.x - vertex.x) * (p.y - vertex.y) / (previous.y - vertex.y) + vertex.x) inside = !inside
            previous = vertex
        }
        return inside
    }
    private fun hit(point: Vector, previousButton: UUID?): Control? {
        controls.firstOrNull { it.id == previousButton && it.kind == "button" && containsHit(it, point, 18.0) }?.let { return it }
        // Match the iOS global capture order, then select the smallest hit area.
        for (kind in listOf("trigger", "joystick", "button", "trackpad")) {
            val candidates = controls.asReversed().filter { it.kind == kind && containsHit(it, point) }
            candidates.minByOrNull { control -> val p = local(control, point); p.width * p.height }?.let { return it }
        }
        return null
    }
    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        val phase = when (event.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> TouchPhase.DOWN
            MotionEvent.ACTION_MOVE -> TouchPhase.MOVE
            MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP -> TouchPhase.UP
            MotionEvent.ACTION_CANCEL -> TouchPhase.CANCEL
            else -> return true
        }
        if (phase == TouchPhase.CANCEL) {
            cancelTouches()
            parent?.requestDisallowInterceptTouchEvent(false)
            return true
        }
        val density = resources.displayMetrics.density
        val contacts = (0 until event.pointerCount).map { Contact(event.getPointerId(it), Vector((event.getX(it) / density).toDouble(), (event.getY(it) / density).toDouble())) }
        router.handle(phase, event.getPointerId(event.actionIndex), contacts, event.eventTime)
        parent?.requestDisallowInterceptTouchEvent(event.actionMasked != MotionEvent.ACTION_UP)
        renderColors(); invalidate()
        return true
    }

    private fun controlAccessibility(control: Control) = object : View.AccessibilityDelegate() {
        override fun onInitializeAccessibilityNodeInfo(host: View, info: AccessibilityNodeInfo) {
            super.onInitializeAccessibilityNodeInfo(host, info)
            when (control.kind) {
                "joystick" -> for ((id, label) in listOf(R.id.control_up to "Up", R.id.control_down to "Down", R.id.control_left to "Left", R.id.control_right to "Right")) {
                    info.addAction(AccessibilityNodeInfo.AccessibilityAction(id, label))
                }
                "trigger" -> {
                    info.className = "android.widget.SeekBar"
                    info.rangeInfo = AccessibilityNodeInfo.RangeInfo.obtain(AccessibilityNodeInfo.RangeInfo.RANGE_TYPE_FLOAT, 0f, 1f, (router.triggerValues[control.id] ?: 0.0).toFloat())
                    info.addAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_SET_PROGRESS)
                    info.addAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_FORWARD)
                    info.addAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_BACKWARD)
                }
                "trackpad" -> info.addAction(AccessibilityNodeInfo.AccessibilityAction(R.id.control_right_click, "Right Click"))
            }
        }
        override fun performAccessibilityAction(host: View, action: Int, args: Bundle?): Boolean {
            if (control.kind == "joystick") {
                val part = when (action) {
                    R.id.control_up -> InputPart.JOYSTICK_UP; R.id.control_down -> InputPart.JOYSTICK_DOWN
                    R.id.control_left -> InputPart.JOYSTICK_LEFT; R.id.control_right -> InputPart.JOYSTICK_RIGHT
                    else -> null
                }
                if (part != null) { router.accessibilityDirection(control, part); renderColors(); invalidate(); return true }
            }
            if (control.kind == "trigger") {
                val current = router.triggerValues[control.id] ?: 0.0
                val value = when (action) {
                    AccessibilityNodeInfo.ACTION_SCROLL_FORWARD -> current + .1
                    AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD -> current - .1
                    AccessibilityNodeInfo.AccessibilityAction.ACTION_SET_PROGRESS.id -> args?.getFloat(AccessibilityNodeInfo.ACTION_ARGUMENT_PROGRESS_VALUE)?.toDouble()
                    else -> null
                }
                if (value != null) { router.accessibilityTrigger(control, value); renderColors(); invalidate(); return true }
            }
            if (control.kind == "trackpad" && action == R.id.control_right_click) { router.click("right"); return true }
            return super.performAccessibilityAction(host, action, args)
        }
    }

    private fun drawIndicator(canvas: Canvas, control: Control, width: Int, height: Int) {
            if (control.kind != "joystick" && control.kind != "trigger") return
            indicatorPaint.color = if (dark) 0x99FFFFFF.toInt() else 0x99000000.toInt()
            if (control.kind == "joystick") {
                val vector = router.joystickVectors[control.id] ?: Vector()
                val radius = min(width, height) * .17f
                canvas.drawCircle(width / 2f + (vector.x * width * .25).toFloat(),
                    height / 2f + (vector.y * height * .25).toFloat(), radius, indicatorPaint)
            } else {
                val value = (router.triggerValues[control.id] ?: 0.0).toFloat()
                val horizontal = TriggerSettings.parse(control.source.optJSONObject("triggerSettings")).horizontal
                if (horizontal) canvas.drawRect(0f, height - 5.dp.toFloat(), width * value, height.toFloat(), indicatorPaint)
                else canvas.drawRect(width - 5.dp.toFloat(), height - height * value, width.toFloat(), height.toFloat(), indicatorPaint)
            }
    }
    fun cancelTouches() {
        router.cancel()
        onReleaseAll()
        renderColors(); invalidate()
    }
    override fun onDetachedFromWindow() { cancelTouches(); super.onDetachedFromWindow() }
    override fun onWindowFocusChanged(hasWindowFocus: Boolean) {
        if (!hasWindowFocus) cancelTouches()
        super.onWindowFocusChanged(hasWindowFocus)
    }

}
internal class ControlFaceView(context: Context) : TextView(context) {
    var appliedPresentation: JSONObject? = null
    var drawIndicator: (Canvas) -> Unit = {}
    private var control: Control? = null
    private var content: JSONObject? = null
    private var icon: ControlIcon? = null
    private var labels = true
    private val painters = mutableMapOf<ControlIcon, IconPainter>()
    private var iconPainter: IconPainter? = null
    private var effectCache = EffectRasterCache()
    private val effectID = EffectRasterCache.id()
    var effectSignature = "static"
    private var lastDynamicKey: String? = null
    var metrics = IconLayout(0.0, Vector(), Vector(), false)
        private set
    fun configure(control: Control, content: JSONObject?, icon: ControlIcon?, assets: AssetImages, labels: Boolean, effects: EffectRasterCache) {
        this.control = control; this.content = content; this.icon = icon; this.labels = labels
        effectCache = effects
        iconPainter = if (icon != null && control.kind in setOf("button", "trigger", "decoration")) painters.getOrPut(icon) { IconPainter(icon, assets) } else null
        updateMetrics()
    }
    private fun updateMetrics() {
        val density = resources.displayMetrics.density
        control?.let { metrics = iconLayout(it, width / density.toDouble(), height / density.toDouble(), content, icon, labels) }
    }
    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) { super.onSizeChanged(w, h, oldw, oldh); updateMetrics() }
    override fun draw(canvas: Canvas) {
        val radius = (appliedPresentation?.finite("blurRadius",0.0) ?: 0.0).toFloat() * resources.displayMetrics.density
        if (radius <= .01f || width <= 0 || height <= 0) { super.draw(canvas); return }
        val key = "$effectID:$width:$height:${System.identityHashCode(appliedPresentation)}:$effectSignature"
        if (effectSignature != "static" && lastDynamicKey != key) { lastDynamicKey?.let { effectCache.remove(it) }; lastDynamicKey = key }
        val raster = effectCache.get(key) {
            val extent = (background?.current as? ControlDrawable)?.visualOutset ?: 0f
            val pad = ceil(extent + radius * 3 + 2).toInt()
            val scale = max(1.0,sqrt((width+2.0*pad)*(height+2.0*pad)/1_048_576)).toFloat()
            val bitmap = android.graphics.Bitmap.createBitmap(ceil((width+2*pad)/scale).toInt(),ceil((height+2*pad)/scale).toInt(),android.graphics.Bitmap.Config.ARGB_8888)
            val local = Canvas(bitmap); local.scale(1/scale,1/scale); local.translate(pad.toFloat(),pad.toFloat()); drawUnblurred(local)
            val blurred = blurBitmap(bitmap,radius/scale)
            if (blurred !== bitmap) bitmap.recycle()
            EffectRaster(blurred,-pad.toFloat(),-pad.toFloat(),scale)
        }
        raster.draw(canvas)
    }
    private fun drawUnblurred(canvas: Canvas) = super.draw(canvas)
    override fun onDraw(canvas: Canvas) {
        drawIndicator(canvas)
        val density = resources.displayMetrics.density
        iconPainter?.draw(canvas, width / 2f + (metrics.offset.x * density).toFloat(), height / 2f + (metrics.offset.y * density).toFloat(), (metrics.size * density).toFloat(), currentTextColor)
        val saved = canvas.save()
        canvas.translate((metrics.labelOffset.x * density).toFloat(), (metrics.labelOffset.y * density).toFloat())
        super.onDraw(canvas); canvas.restoreToCount(saved)
    }
}
internal fun JSONObject.finite(key: String, fallback: Double): Double = optDouble(key, fallback).takeIf { it.isFinite() } ?: fallback
