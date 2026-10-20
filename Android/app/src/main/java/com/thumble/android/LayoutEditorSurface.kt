package com.thumble.android

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.os.Bundle
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.FrameLayout
import java.util.UUID
import kotlin.math.*

/** The editor never connects the renderer's runtime input callbacks. */
internal class LayoutEditorSurface(context: Context) : FrameLayout(context) {
    private val renderer = ControllerSurface(context)
    private val overlay = EditOverlay(context)
    var onPatch: (LayoutControlPatch?, Boolean) -> Unit
        get() = overlay.onPatch
        set(value) { overlay.onPatch = value }
    var onDelete: (Control) -> Unit
        get() = overlay.onDelete
        set(value) { overlay.onDelete = value }
    init {
        addView(renderer, LayoutParams(-1, -1))
        renderer.importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        addView(overlay, LayoutParams(-1, -1))
    }
    fun show(profile: ControllerProfile, landscape: Boolean, dark: Boolean, enabled: Boolean, tint: Int, onTint: Int) {
        renderer.show(profile, 0, landscape, dark)
        overlay.show(profile, landscape, enabled, tint, onTint)
    }
    private class EditOverlay(context: Context) : ViewGroup(context) {
        var onPatch: (LayoutControlPatch?, Boolean) -> Unit = { _, _ -> }
        var onDelete: (Control) -> Unit = {}
        private var profile: ControllerProfile? = null
        private var controls = emptyList<Control>()
        private var selected: UUID? = null
        private var southpaw = false
        private var enabled = true
        private var tint = android.graphics.Color.BLUE
        private var onTint = android.graphics.Color.WHITE
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        private val density get() = resources.displayMetrics.density.toDouble()
        private val canvasWidth get() = width / density
        private val canvasHeight get() = height / density
        private data class Gesture(val pointer: Int, val control: Control, val frame: ControlFrame,
            val x: Double, val y: Double, val mode: String, val corner: LayoutResizeCorner? = null)
        private var gesture: Gesture? = null
        init { setWillNotDraw(false); isFocusable = false; clipChildren = false }
        private fun cancelGesture() {
            if (gesture == null) return
            gesture = null
            parent?.requestDisallowInterceptTouchEvent(false)
            onPatch(null, false)
            invalidate()
        }
        override fun onWindowFocusChanged(hasWindowFocus: Boolean) {
            if (!hasWindowFocus) cancelGesture()
            super.onWindowFocusChanged(hasWindowFocus)
        }
        override fun onDetachedFromWindow() {
            cancelGesture()
            super.onDetachedFromWindow()
        }
        override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
            if (w != oldw || h != oldh) cancelGesture()
            super.onSizeChanged(w, h, oldw, oldh)
        }
        fun show(value: ControllerProfile, landscape: Boolean, interactive: Boolean, color: Int, foreground: Int) {
            val readinessChanged = enabled != interactive
            enabled = interactive; tint = color; onTint = foreground
            if (profile === value) {
                if (readinessChanged) {
                    for (i in 0 until childCount) getChildAt(i).isEnabled = interactive
                    sendAccessibilityEvent(android.view.accessibility.AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED)
                }
                invalidate(); return
            }
            profile = value; southpaw = value.layout(landscape).optString("layoutMode") == "southpaw"
            controls = value.controls(landscape)
            if (controls.none { it.id == selected }) selected = null
            removeAllViews()
            controls.forEach { control ->
                addView(View(context).apply {
                    contentDescription = "Edit ${control.accessibilityName}" + if (control.style.optBoolean("isLocationLocked")) ", locked" else ""
                    importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_YES
                    isFocusable = true; isClickable = true
                    isEnabled = interactive
                    setOnClickListener { select(control) }
                    accessibilityDelegate = object : AccessibilityDelegate() {
                        override fun onInitializeAccessibilityNodeInfo(host: View, info: AccessibilityNodeInfo) {
                            super.onInitializeAccessibilityNodeInfo(host, info)
                            info.className = "android.widget.Button"
                            info.isSelected = selected == control.id
                            val f = frame(control)
                            info.text = "Position ${(f.centerX / canvasWidth * 100).roundToInt()} percent across, ${(f.centerY / canvasHeight * 100).roundToInt()} percent down. " +
                                "Size ${(control.style.finite("widthScale",1.0)*100).roundToInt()} by ${(control.style.finite("heightScale",1.0)*100).roundToInt()} percent. " +
                                "Rotation ${control.style.finite("rotationDegrees",0.0).roundToInt()} degrees."
                            if (!enabled) { info.isEnabled = false; return }
                            if (!control.style.optBoolean("isLocationLocked")) {
                                listOf("Move left", "Move right", "Move up", "Move down", "Enlarge", "Reduce", "Rotate counterclockwise", "Rotate clockwise")
                                    .forEachIndexed { i, name -> info.addAction(AccessibilityNodeInfo.AccessibilityAction(0x01020000 + i, name)) }
                            }
                            info.addAction(AccessibilityNodeInfo.AccessibilityAction(0x01020008, "Delete ${control.accessibilityName}"))
                        }
                        override fun performAccessibilityAction(host: View, action: Int, args: Bundle?): Boolean {
                            if (!enabled) return false
                            val frame = frame(control)
                            val patch = when (action - 0x01020000) {
                                0 -> LayoutControlEdits.move(control, frame, -4.0, 0.0, canvasWidth, canvasHeight)
                                1 -> LayoutControlEdits.move(control, frame, 4.0, 0.0, canvasWidth, canvasHeight)
                                2 -> LayoutControlEdits.move(control, frame, 0.0, -4.0, canvasWidth, canvasHeight)
                                3 -> LayoutControlEdits.move(control, frame, 0.0, 4.0, canvasWidth, canvasHeight)
                                4 -> LayoutControlEdits.scale(control, .1)
                                5 -> LayoutControlEdits.scale(control, -.1)
                                6 -> LayoutControlEdits.rotate(control, -15.0)
                                7 -> LayoutControlEdits.rotate(control, 15.0)
                                8 -> { select(control); onDelete(control); return true }
                                else -> return super.performAccessibilityAction(host, action, args)
                            }
                            select(control); patch?.let { onPatch(it, true) }; return patch != null
                        }
                    }
                })
            }
            requestLayout(); invalidate()
            sendAccessibilityEvent(android.view.accessibility.AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED)
        }
        private fun select(control: Control) { selected = control.id; invalidate(); announceForAccessibility("Selected ${control.accessibilityName}") }
        private fun frame(control: Control) = ControlGeometry.resolve(control, canvasWidth, canvasHeight, southpaw)
        private fun local(frame: ControlFrame, control: Control, x: Double, y: Double): Pair<Double, Double> {
            val angle = Math.toRadians(-control.style.finite("rotationDegrees", 0.0))
            val dx = x - frame.centerX; val dy = y - frame.centerY
            return dx * cos(angle) - dy * sin(angle) to dx * sin(angle) + dy * cos(angle)
        }
        override fun onMeasure(w: Int, h: Int) { setMeasuredDimension(MeasureSpec.getSize(w), MeasureSpec.getSize(h)) }
        override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
            controls.forEachIndexed { i, control ->
                val f = frame(control)
                val cw = (max(48.0, f.width) * density).roundToInt(); val ch = (max(48.0, f.height) * density).roundToInt()
                val child = getChildAt(i)
                child.measure(MeasureSpec.makeMeasureSpec(cw, MeasureSpec.EXACTLY), MeasureSpec.makeMeasureSpec(ch, MeasureSpec.EXACTLY))
                val x = (f.centerX * density - cw / 2).roundToInt(); val y = (f.centerY * density - ch / 2).roundToInt()
                child.layout(x, y, x + cw, y + ch)
                child.rotation = control.style.finite("rotationDegrees", 0.0).toFloat()
            }
        }
        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            controls.forEach { control ->
                val f = frame(control); val active = selected == control.id
                val locked = control.style.optBoolean("isLocationLocked")
                val saved = canvas.save()
                canvas.scale(density.toFloat(), density.toFloat())
                canvas.rotate(control.style.finite("rotationDegrees", 0.0).toFloat(), f.centerX.toFloat(), f.centerY.toFloat())
                canvas.translate(f.centerX.toFloat(), f.centerY.toFloat())
                paint.color = tint; paint.alpha = if (active) 255 else 110; paint.style = Paint.Style.STROKE; paint.strokeWidth = if (active) 2f else 1f
                canvas.drawRoundRect((-f.width/2-3).toFloat(), (-f.height/2-3).toFloat(), (f.width/2+3).toFloat(), (f.height/2+3).toFloat(), 8f, 8f, paint)
                if (active) {
                    paint.style = Paint.Style.FILL
                    if (!locked) {
                        LayoutResizeCorner.entries.forEach { corner ->
                            canvas.drawCircle((if(corner.leading) -f.width/2 else f.width/2).toFloat(), (if(corner.top) -f.height/2 else f.height/2).toFloat(), 6f, paint)
                        }
                        canvas.drawCircle((f.width/2+26).toFloat(), (-f.height/2-26).toFloat(), 12f, paint)
                        paint.color = onTint; paint.textSize = 18f; paint.textAlign = Paint.Align.CENTER
                        canvas.drawText("↻", (f.width/2+26).toFloat(), (-f.height/2-20).toFloat(), paint)
                    }
                    paint.color = tint; canvas.drawCircle(0f, (f.height/2+28).toFloat(), 12f, paint)
                    paint.color = onTint; paint.textSize = 20f; paint.textAlign = Paint.Align.CENTER
                    canvas.drawText("×", 0f, (f.height/2+35).toFloat(), paint)
                }
                canvas.restoreToCount(saved)
            }
        }
        override fun dispatchTouchEvent(event: MotionEvent): Boolean {
            if (!enabled && gesture == null) return true
            val index = gesture?.let { event.findPointerIndex(it.pointer) } ?: event.actionIndex
            if (index < 0) { cancelGesture(); return true }
            val x = event.getX(index) / density; val y = event.getY(index) / density
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    val selectedControl = controls.firstOrNull { it.id == selected }
                    var hit: Gesture? = null
                    if (selectedControl != null) {
                        val f = frame(selectedControl); val p = local(f, selectedControl, x, y)
                        if (hypot(p.first, p.second - f.height/2-28) <= 24) {
                            onDelete(selectedControl); return true
                        }
                        if (!selectedControl.style.optBoolean("isLocationLocked")) {
                            if (hypot(p.first-f.width/2-26, p.second+f.height/2+26) <= 24)
                                hit = Gesture(event.getPointerId(index), selectedControl, f, x, y, "rotate")
                            if (hit == null) LayoutResizeCorner.entries.firstOrNull { corner ->
                                hypot(p.first - (if(corner.leading) -f.width/2 else f.width/2), p.second - (if(corner.top) -f.height/2 else f.height/2)) <= 24
                            }?.let { hit = Gesture(event.getPointerId(index), selectedControl, f, x, y, "resize", it) }
                        }
                    }
                    if (hit == null) {
                        val control = controls.asReversed().firstOrNull { c ->
                            val f = frame(c); val p = local(f, c, x, y)
                            abs(p.first) <= max(24.0, f.width/2+6) && abs(p.second) <= max(24.0, f.height/2+6)
                        }
                        selected = control?.id
                        control?.let { if(!it.style.optBoolean("isLocationLocked")) hit = Gesture(event.getPointerId(index), it, frame(it), x, y, "move") }
                    }
                    gesture = hit; invalidate(); parent?.requestDisallowInterceptTouchEvent(true)
                }
                MotionEvent.ACTION_MOVE, MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP -> {
                    val g = gesture ?: return true
                    if (event.actionMasked == MotionEvent.ACTION_POINTER_UP && event.getPointerId(event.actionIndex) != g.pointer) return true
                    val patch = when (g.mode) {
                        "resize" -> LayoutControlEdits.resize(g.control, g.frame, g.corner!!, x-g.x, y-g.y, canvasWidth, canvasHeight)
                        "rotate" -> LayoutControlEdits.rotate(g.control, (atan2(y-g.frame.centerY,x-g.frame.centerX)-atan2(g.y-g.frame.centerY,g.x-g.frame.centerX))*180/Math.PI)
                        else -> LayoutControlEdits.move(g.control, g.frame, x-g.x, y-g.y, canvasWidth, canvasHeight)
                    }
                    val final = event.actionMasked != MotionEvent.ACTION_MOVE
                    onPatch(patch, final)
                    if (final) { gesture = null; parent?.requestDisallowInterceptTouchEvent(false); performClick() }
                }
                MotionEvent.ACTION_CANCEL -> cancelGesture()
            }
            return true
        }
        override fun performClick(): Boolean { super.performClick(); return true }
    }
}
