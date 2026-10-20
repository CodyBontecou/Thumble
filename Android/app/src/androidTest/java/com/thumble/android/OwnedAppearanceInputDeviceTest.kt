package com.thumble.android

import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Bundle
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

/** Actual native View touch owners and paint, using a fake actuator and no network or live outputs. */
@RunWith(AndroidJUnit4::class)
class OwnedAppearanceInputDeviceTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val ids = (1..4).map { UUID.fromString("ad000000-0000-0000-0000-%012d".format(it)) }
    private val colors = mapOf(ControllerActionSet.BASE to 0xff203040.toInt(), ControllerActionSet.LEFT to 0xff305020.toInt(),
        ControllerActionSet.RIGHT to 0xff503020.toInt(), ControllerActionSet.BOTH to 0xff403060.toInt())
    private fun solid(color: Int) = JSONObject().put("kind", "solid").put("color", rgbaJSON(color))
    private fun paint(index: Int, action: ControllerActionSet) = JSONObject().put("shadowStrength", 1).put("shape", "rectangle")
        .put("icon", JSONObject().put("source", "text").put("value", if (index == 0) action.key else "${index + 1}"))
        .put("visualStyle", JSONObject().put("normal", JSONObject().put("fillStyle", solid(colors.getValue(action)))))
    private fun profile(): ControllerProfile {
        val controls = JSONArray()
        ids.forEachIndexed { index, id ->
            val style = paint(index, ControllerActionSet.BASE).put("centerX", .125 + .25 * index).put("centerY", .5)
                .put("widthScale", .7).put("heightScale", .8)
            val element = JSONObject().put("id", id.toString()).put("kind", if (index == 2) "trigger" else "button")
                .put("label", "Control ${index + 1}").put("layout", style)
            if (index == 2) element.put("triggerSettings", JSONObject().put("target", "left").put("orientation", "horizontal").put("deadZone", 0))
            else element.put("output", JSONObject().put("gamepadButtons", JSONArray().put(when (index) {
                0 -> "leftTriggerButton"; 1 -> "rightTriggerButton"; else -> "south"
            })))
            controls.put(element)
        }
        val layout = JSONObject().put("elements", controls).put("colorSchemePreference", "light").put("accentStyle", "monochrome")
            .put("showsButtonLabels", true).put("backgroundFillStyle", solid(colors.getValue(ControllerActionSet.BASE)))
            .put("deviceCanvas", JSONObject().put("frameID", "iphone-17-pro-landscape"))
        val variants = JSONArray()
        for (scheme in listOf("light", "dark")) for (action in ControllerActionSet.entries) {
            val appearances = JSONObject(); ids.forEachIndexed { index, id -> appearances.put(id.toString(), paint(index, action)) }
            variants.put(JSONObject().put("colorScheme", scheme).put("actionSet", action.key).put("appearance", JSONObject()
                .put("accentStyle", "monochrome").put("showsButtonLabels", true).put("backgroundFillStyle", solid(colors.getValue(action)))
                .put("artworkLayers", JSONArray()).put("controls", appearances).put("topBar", JSONObject().put("shadowStrength", 1))
                .put("controlBar", JSONObject()).put("styleLibrary", JSONObject().put("styles", JSONArray()))
                .put("assetLibrary", JSONObject().put("assets", JSONArray()))))
        }
        return ControllerProfile.parse(JSONObject().put("id", "ad100000-0000-0000-0000-000000000001").put("name", "Owned trigger paint")
            .put("outputMode", "custom").put("customization", layout).put("appearanceBank", JSONObject().put("schemaVersion", 1).put("variants", variants)))
    }
    private data class Edge(val id: UUID, val down: Boolean, val press: Long)
    private class Output: KeypadHapticOutput {
        var plays = 0; var cancels = 0
        override fun play(feedback: KeypadHaptic, intensity: Double) { plays++ }
        override fun cancel() { cancels++ }
    }
    private fun sized(surface: ControllerSurface) {
        surface.measure(View.MeasureSpec.makeMeasureSpec(1600, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(700, View.MeasureSpec.EXACTLY))
        surface.layout(0, 0, 1600, 700)
    }
    private fun assertPaint(surface: ControllerSurface, action: ControllerActionSet, evidence: String? = null) {
        assertEquals(action, surface.displayedActionSet)
        val first = surface.getChildAt(0) as ControlFaceView
        assertEquals(action.key, first.appliedPresentation!!.getJSONObject("icon").getString("value"))
        val bitmap = Bitmap.createBitmap(1600, 700, Bitmap.Config.ARGB_8888)
        surface.draw(Canvas(bitmap))
        assertEquals(colors.getValue(action), bitmap.getPixel(4, 4))
        if (evidence != null) {
            val folder = File(instrumentation.targetContext.cacheDir, "owned-appearance-evidence").apply { mkdirs() }
            File(folder, "$evidence.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
        bitmap.recycle()
    }
    @Test fun simultaneousDigitalHoldsSwitchPaintWithoutReleasingOtherPointersOrRebuildingViews() {
        val original = profile(); val before = original.source.toString()
        val projection = SkinRenderRepository { error("No package") }.resolve(original, true, false)
        assertNull(projection.warning)
        instrumentation.runOnMainSync {
            val haptic = Output(); val surface = ControllerSurface(instrumentation.targetContext, hapticOutput = haptic)
            val edges = mutableListOf<Edge>(); var releases = 0
            surface.onEdge = { id, down, press -> edges.add(Edge(id, down, press)) }
            surface.onReleaseAll = { releases++ }
            surface.show(projection.profile, 1, true, false, projection.appearanceFrames); sized(surface)
            val children = (0 until surface.childCount).map(surface::getChildAt)
            val frames = children.map { listOf(it.left, it.top, it.right, it.bottom) }
            val points = children.map { it.left + it.width / 2f to it.top + it.height / 2f }
            val began = SystemClock.uptimeMillis()
            fun touch(action: Int, vararg contacts: Pair<Int, Int>) {
                val properties = contacts.map { (pointer, _) -> MotionEvent.PointerProperties().apply { id = pointer; toolType = MotionEvent.TOOL_TYPE_FINGER } }.toTypedArray()
                val coordinates = contacts.map { (_, index) -> MotionEvent.PointerCoords().apply {
                    x = points[index].first; y = points[index].second; pressure = 1f; size = 1f
                } }.toTypedArray()
                val event = MotionEvent.obtain(began, SystemClock.uptimeMillis(), action, contacts.size, properties, coordinates, 0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0)
                surface.dispatchTouchEvent(event); event.recycle()
            }
            assertPaint(surface, ControllerActionSet.BASE, "base")
            touch(MotionEvent.ACTION_DOWN, 4 to 3) // Hold an unrelated face throughout all layer switches.
            val unrelated = edges.single()
            touch(MotionEvent.ACTION_POINTER_DOWN or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), 4 to 3, 1 to 0)
            assertPaint(surface, ControllerActionSet.LEFT, "left-held")
            touch(MotionEvent.ACTION_POINTER_DOWN or (2 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), 4 to 3, 1 to 0, 2 to 1)
            assertPaint(surface, ControllerActionSet.BOTH, "both-held")
            surface.show(projection.profile, 1, true, false, projection.appearanceFrames) // Ordinary Compose update is a no-op.
            assertEquals(3, edges.size); assertEquals(0, releases); assertEquals(0, haptic.cancels)
            children.forEachIndexed { index, view -> assertSame(view, surface.getChildAt(index)) }
            assertEquals(frames, children.map { listOf(it.left, it.top, it.right, it.bottom) })
            touch(MotionEvent.ACTION_POINTER_UP or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), 4 to 3, 1 to 0, 2 to 1)
            assertPaint(surface, ControllerActionSet.RIGHT, "right-held")
            touch(MotionEvent.ACTION_POINTER_UP or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), 4 to 3, 2 to 1)
            assertPaint(surface, ControllerActionSet.BASE)
            assertTrue(surface.getChildAt(3).isPressed); assertEquals(3, haptic.plays)
            assertTrue(edges.none { it.id == unrelated.id && !it.down })
            surface.cancelTouches()
            assertEquals(1, releases); assertEquals(1, haptic.cancels)
            assertEquals(listOf(unrelated, unrelated.copy(down = false)), edges.filter { it.id == unrelated.id })
            ids.take(2).forEach { id ->
                val pair = edges.filter { it.id == id }; assertEquals(2, pair.size)
                assertTrue(pair.first().down); assertFalse(pair.last().down); assertEquals(pair.first().press, pair.last().press)
            }
            assertPaint(surface, ControllerActionSet.BASE)
        }
        assertEquals(before, original.source.toString())
    }
    @Test fun identicalAssetIconDescriptorsUseEachStatesOwnedBytesRatherThanAnOldPainter() {
        val original = profile()
        val raw = original.source
        val descriptor = JSONObject().put("source", "asset").put("value", "same-icon").put("renderingMode", "original").put("placement", "center")
        val iconColors = mapOf(ControllerActionSet.BASE to 0xffe03020.toInt(), ControllerActionSet.LEFT to 0xff20d040.toInt(),
            ControllerActionSet.RIGHT to 0xff2040e0.toInt(), ControllerActionSet.BOTH to 0xffe0d020.toInt())
        for (variant in AppearanceJSON.objects(raw.getJSONObject("appearanceBank").getJSONArray("variants"))) {
            val action = ControllerActionSet.entries.first { it.key == variant.getString("actionSet") }
            val image = Bitmap.createBitmap(4, 4, Bitmap.Config.ARGB_8888).apply { eraseColor(iconColors.getValue(action)) }
            val encoded = java.io.ByteArrayOutputStream().also { image.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
            image.recycle()
            val library = JSONObject().put("assets", JSONArray().put(JSONObject().put("id", "same-icon").put("name", "State icon")
                .put("contentType", "image/png").put("byteCount", encoded.size).put("role", "icon")
                .put("data", android.util.Base64.encodeToString(encoded, android.util.Base64.NO_WRAP))))
            val paint = variant.getJSONObject("appearance")
            paint.put("assetLibrary", library)
            paint.getJSONObject("controls").getJSONObject(ids.first().toString()).put("icon", AppearanceJSON.objectCopy(descriptor))
            if (variant.getString("colorScheme") == "light" && action == ControllerActionSet.BASE) {
                raw.getJSONObject("customization").put("assetLibrary", AppearanceJSON.objectCopy(library))
                raw.getJSONObject("customization").getJSONArray("elements").getJSONObject(0).getJSONObject("layout")
                    .put("icon", AppearanceJSON.objectCopy(descriptor))
            }
        }
        val projection = SkinRenderRepository { error("No package") }.resolve(original, true, false)
        assertNull(projection.warning)
        instrumentation.runOnMainSync {
            val surface = ControllerSurface(instrumentation.targetContext, hapticOutput = Output())
            surface.show(projection.profile, 1, true, false, projection.appearanceFrames); sized(surface)
            fun iconColor(action: ControllerActionSet) {
                val bitmap = Bitmap.createBitmap(1600, 700, Bitmap.Config.ARGB_8888)
                surface.draw(Canvas(bitmap))
                val child = surface.getChildAt(0)
                assertEquals(action, surface.displayedActionSet)
                assertEquals(iconColors.getValue(action), bitmap.getPixel(child.left + child.width / 2, child.top + child.height / 2))
                bitmap.recycle()
            }
            iconColor(ControllerActionSet.BASE)
            fun progress(value: Float) = surface.getChildAt(2).performAccessibilityAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_SET_PROGRESS.id,
                Bundle().apply { putFloat(AccessibilityNodeInfo.ACTION_ARGUMENT_PROGRESS_VALUE, value) })
            assertTrue(progress(.9f)); iconColor(ControllerActionSet.LEFT)
            assertTrue(progress(0f)); iconColor(ControllerActionSet.BASE)
            surface.cancelTouches()
        }
    }
    @Test fun accessibilityAnalogThresholdFocusLossAndProfileReplacementResetPaintAndInputOwners() {
        val original = profile(); val projection = SkinRenderRepository { error("No package") }.resolve(original, true, false)
        instrumentation.runOnMainSync {
            val surface = ControllerSurface(instrumentation.targetContext, hapticOutput = Output())
            val values = mutableListOf<Double>(); var releases = 0
            surface.onTrigger = { _, value, _ -> values.add(value) }; surface.onReleaseAll = { releases++ }
            surface.show(projection.profile, 1, true, false, projection.appearanceFrames); sized(surface)
            val trigger = surface.getChildAt(2)
            fun progress(value: Float) {
                assertTrue(trigger.performAccessibilityAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_SET_PROGRESS.id,
                    Bundle().apply { putFloat(AccessibilityNodeInfo.ACTION_ARGUMENT_PROGRESS_VALUE, value) }))
            }
            progress(.5f); assertPaint(surface, ControllerActionSet.BASE)
            progress(.75f); assertPaint(surface, ControllerActionSet.LEFT)
            assertSame(trigger, surface.getChildAt(2)); assertEquals(listOf(.5, .75), values)
            surface.onWindowFocusChanged(false)
            assertEquals(0.0, values.last(), 0.0); assertEquals(1, releases)
            assertPaint(surface, ControllerActionSet.BASE)
            progress(.8f); assertPaint(surface, ControllerActionSet.LEFT)
            surface.show(projection.profile, 2, true, false, projection.appearanceFrames); sized(surface)
            assertEquals(0.0, values.last(), 0.0); assertEquals(2, releases)
            assertPaint(surface, ControllerActionSet.BASE)
            surface.getChildAt(0).performClick() // A complete accessible digital click must not strand a layer.
            assertPaint(surface, ControllerActionSet.BASE)
            surface.cancelTouches()
        }
    }
}
