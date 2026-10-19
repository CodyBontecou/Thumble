package com.thumble.android

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.MotionEvent
import android.view.PixelCopy
import android.view.View
import android.view.ViewGroup
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

@RunWith(AndroidJUnit4::class)
class RendererDeviceTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private fun await(description: String, condition: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 10_000
        while (!condition() && SystemClock.elapsedRealtime() < deadline) SystemClock.sleep(20)
        assertTrue(description, condition())
    }
    private fun solid(color: Int) = JSONObject().put("kind", "solid").put("color", rgbaJSON(color))
    private fun gradient(type: String = "linear") = JSONObject().put("kind", "gradient").put("gradient",
        JSONObject().put("type", type).put("angleDegrees", 0).put("stops", JSONArray()
            .put(JSONObject().put("offset", 1).put("color", rgbaJSON(Color.BLUE)))
            .put(JSONObject().put("offset", 0).put("color", rgbaJSON(Color.RED)))))
    private fun pixels(shape: String, style: JSONObject = JSONObject(), fill: JSONObject = solid(Color.RED)): Bitmap {
        val bitmap = Bitmap.createBitmap(200, 100, Bitmap.Config.ARGB_8888)
        ControlDrawable(shape, style, fill, 1f).apply { setBounds(0, 0, 200, 100); draw(Canvas(bitmap)) }
        return bitmap
    }
    @Test fun canonicalShapeCornersGradientAndAlphaRenderOnAndroid() {
        val bitmap = pixels("circle")
        assertEquals("circle uses the authored rectangular frame with capsule radii", Color.RED, bitmap.getPixel(40, 50))
        assertEquals(0, Color.alpha(bitmap.getPixel(0, 0)))
        bitmap.recycle()
        for (shape in listOf("polygon", "star")) pixels(shape).useBitmap {
            assertEquals(Color.RED, it.getPixel(100, 50)); assertEquals(0, Color.alpha(it.getPixel(10, 10)))
        }
        pixels("rectangle", fill = solid(0x80FF0000.toInt())).useBitmap { assertEquals(128, Color.alpha(it.getPixel(100, 50))) }
        pixels("rounded_rectangle", JSONObject().put("cornerRadii", JSONObject().put("topLeading", 30).put("topTrailing", 0).put("bottomLeading", 0).put("bottomTrailing", 0))).useBitmap {
            assertEquals(0, Color.alpha(it.getPixel(1, 1))); assertEquals(Color.RED, it.getPixel(198, 1))
        }
        pixels("rectangle", fill = gradient()).useBitmap {
            assertTrue(Color.red(it.getPixel(10, 50)) > 230); assertTrue(Color.blue(it.getPixel(190, 50)) > 230)
        }
        pixels("rectangle", fill = gradient("radial")).useBitmap {
            assertTrue(Color.red(it.getPixel(100, 50)) > 250)
            assertTrue(Color.blue(it.getPixel(190, 50)) in 110..120) // Native end radius = max(width,height).
        }
        val explicit = JSONObject().put("lightFillColor", rgbaJSON(Color.GREEN)).put("fillStyle", gradient())
        assertEquals("gradient", resolvedFill(explicit, false, Color.BLACK).getString("kind"))
        for (pattern in listOf("dots", "grid", "checker", "diagonal")) {
            val tile = tile(pattern)
            pixels("rectangle", fill = tile).useBitmap {
                when (pattern) {
                    "dots" -> { assertEquals(Color.RED, it.getPixel(13, 13)); assertEquals(Color.WHITE, it.getPixel(6, 6)) }
                    "grid" -> { assertTrue(Color.red(it.getPixel(13, 6)) > Color.blue(it.getPixel(13, 6))); assertEquals(Color.WHITE, it.getPixel(6, 6)) }
                    "checker" -> { assertEquals(Color.RED, it.getPixel(3, 3)); assertEquals(Color.WHITE, it.getPixel(15, 3)) }
                    "diagonal" -> { assertTrue(Color.blue(it.getPixel(6, 7)) < 50); assertEquals(Color.WHITE, it.getPixel(2, 2)) }
                }
            }
            tile.getJSONObject("tile").put("opacity", 0)
            pixels("rectangle", fill = tile).useBitmap { assertEquals(Color.WHITE, it.getPixel(13, 13)) }
        }
    }
    private fun Bitmap.useBitmap(block: (Bitmap) -> Unit) { try { block(this) } finally { recycle() } }
    private fun tile(pattern: String) = JSONObject().put("kind", "tile").put("tile", JSONObject()
        .put("pattern", pattern).put("foregroundColor", rgbaJSON(Color.RED)).put("backgroundColor", rgbaJSON(Color.WHITE)))

    @Test fun forcedProfileAppearanceDoesNotRetireHeldTouchesOnSystemThemeUpdates() {
        val raw = fixture("portrait")
        raw.getJSONObject("customization").put("colorSchemePreference", "dark")
        val profile = ControllerProfile.parse(raw)
        instrumentation.runOnMainSync {
            val surface = ControllerSurface(instrumentation.targetContext)
            surface.show(profile, 1, false, false)
            surface.measure(View.MeasureSpec.makeMeasureSpec(1000, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(1000, View.MeasureSpec.EXACTLY))
            surface.layout(0, 0, 1000, 1000)
            var ups = 0
            surface.onEdge = { _, down, _ -> if (!down) ups++ }
            val first = surface.getChildAt(0)
            val event = MotionEvent.obtain(0, 0, MotionEvent.ACTION_DOWN, first.left + first.width / 2f, first.top + first.height / 2f, 0)
            surface.dispatchTouchEvent(event); event.recycle()
            assertTrue(first.isPressed)
            surface.show(profile, 1, false, false)
            surface.show(profile, 1, false, true)
            assertSame(first, surface.getChildAt(0)); assertTrue(first.isPressed); assertEquals(0, ups)
            val bitmap = Bitmap.createBitmap(1000, 1000, Bitmap.Config.ARGB_8888)
            surface.draw(Canvas(bitmap))
            assertEquals(Color.rgb(18, 18, 18), bitmap.getPixel(0, 0)); bitmap.recycle()
            surface.cancelTouches(); assertEquals(1, ups)
        }
    }

    @Test fun asymmetricHitInsetsPreserveAuthoredHitCenterAndVisualOffset() {
        val raw = fixture("portrait")
        val element = raw.getJSONObject("customization").getJSONArray("elements").getJSONObject(0)
        element.put("kind", "button").getJSONObject("layout").put("hitInsets", JSONObject().put("leading", 40).put("trailing", 0).put("top", 0).put("bottom", 0))
        raw.getJSONObject("customization").put("elements", JSONArray().put(element))
        instrumentation.runOnMainSync {
            val surface = ControllerSurface(instrumentation.targetContext)
            val profile = ControllerProfile.parse(raw)
            surface.show(profile, 1, false, false)
            surface.measure(View.MeasureSpec.makeMeasureSpec(1000, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(1000, View.MeasureSpec.EXACTLY))
            surface.layout(0, 0, 1000, 1000)
            val density = surface.resources.displayMetrics.density
            val frame = ControlGeometry.resolve(profile.controls(false).single(), 1000 / density.toDouble(), 1000 / density.toDouble(), false)
            val child = surface.getChildAt(0)
            assertEquals(frame.centerX * density, child.left + child.width / 2.0, 1.0)
            var downs = 0
            surface.onEdge = { _, down, _ -> if (down) downs++ }
            val event = MotionEvent.obtain(0, 0, MotionEvent.ACTION_DOWN, ((frame.centerX - frame.width / 2 - 15) * density).toFloat(), (frame.centerY * density).toFloat(), 0)
            surface.dispatchTouchEvent(event); event.recycle()
            assertEquals("touch in the authored leading hit region", 1, downs)
            surface.cancelTouches()
            element.getJSONObject("layout").put("rotationDegrees", 90)
            surface.show(ControllerProfile.parse(raw), 2, false, false)
            surface.measure(View.MeasureSpec.makeMeasureSpec(1000, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(1000, View.MeasureSpec.EXACTLY))
            surface.layout(0, 0, 1000, 1000)
            val rotated = surface.getChildAt(0)
            assertEquals((frame.centerX - 20) * density, rotated.left + rotated.width / 2.0, 1.0)
            assertEquals((frame.centerY + 20) * density, rotated.top + rotated.height / 2.0, 1.0)
        }
    }

    private fun fixture(orientation: String): JSONObject {
        val elements = JSONArray()
        val shapes = listOf("circle", "ellipse", "polygon", "star", "rounded_rectangle", "capsule")
        for ((index, shape) in shapes.withIndex()) {
            val style = JSONObject().put("centerX", .25 + (index % 2) * .5).put("centerY", .2 + (index / 2) * .3)
                .put("shape", shape).put("widthScale", 1.5).put("heightScale", .7)
                .put("lightFillStyle", gradient(if (index == 1) "radial" else "linear"))
                .put("darkFillColor", rgbaJSON(Color.rgb(50 + index * 20, 100, 160)))
            if (index == 4) style.put("cornerRadii", JSONObject().put("topLeading", 24).put("topTrailing", 0).put("bottomLeading", 0).put("bottomTrailing", 24))
            if (index == 2 || index == 4) style.put("lightFillStyle", tile(if (index == 2) "grid" else "checker"))
            if (index == 0) style.put("icon", JSONObject().put("source", "sf_symbol").put("value", "arrow.up").put("placement", "leading"))
            if (index == 1) style.put("icon", JSONObject().put("source", "text").put("value", "↗").put("placement", "top"))
            if (index == 3) style.put("icon", JSONObject().put("source", "sf_symbol").put("value", "command.square").put("placement", "center"))
            if (index == 5) style.put("icon", JSONObject().put("source", "asset").put("value", "fixture-icon").put("placement", "leading").put("renderingMode", "original"))
            elements.put(JSONObject().put("id", UUID(0x1111L, index.toLong() + 1)).put("kind", "button").put("label", shape).put("layout", style))
        }
        val pixels = Bitmap.createBitmap(4,4,Bitmap.Config.ARGB_8888)
        for (y in 0..3) for (x in 0..3) pixels.setPixel(x,y,if (x < 2) Color.rgb(30,120,180) else Color.rgb(210,230,240))
        val bytes = java.io.ByteArrayOutputStream(); pixels.compress(Bitmap.CompressFormat.PNG,100,bytes); pixels.recycle()
        val assets = JSONObject().put("assets", JSONArray().put(JSONObject().put("id","fixture-icon").put("name","Fixture icon")
            .put("data",android.util.Base64.encodeToString(bytes.toByteArray(),android.util.Base64.NO_WRAP))))
        val artwork = JSONArray().put(JSONObject().put("id","underlay").put("plane","underlay").put("frame",JSONObject().put("x",0).put("y",.02).put("width",1).put("height",.03))
            .put("fillStyle",solid(Color.rgb(30,120,180))).put("opacity",.3))
            .put(JSONObject().put("id","overlay").put("plane","overlay").put("frame",JSONObject().put("x",.02).put("y",.94).put("width",.96).put("height",.02))
                .put("fillStyle",solid(Color.rgb(30,120,180))).put("opacity",.4).put("rotationDegrees",2))
        return JSONObject().put("id", if (orientation == "portrait") "22aa418b-aa10-4bb0-8220-6c23fed80200" else "22aa418b-aa10-4bb0-8220-6c23fed80201")
            .put("name", "Renderer acceptance").put("orientationPreference", orientation)
            .put("customization", JSONObject().put("elements", elements).put("assetLibrary", assets).put("artworkLayers", artwork)
                .put("backgroundLightFillStyle", solid(Color.WHITE)).put("backgroundDarkFillStyle", solid(Color.rgb(18, 18, 18))))
    }
    private fun findSurface(view: View): ControllerSurface? {
        if (view is ControllerSurface) return view
        if (view is ViewGroup) for (index in 0 until view.childCount) findSurface(view.getChildAt(index))?.let { return it }
        return null
    }
    @Test fun visibleSavedControllerRendersCanonicalShapesInBothThemesAndOrientations() {
        val portrait = ControllerProfile.parse(fixture("portrait")); val landscape = ControllerProfile.parse(fixture("landscape"))
        val store = MemorySessionStore().apply { saveSnapshot(ProfileSnapshot(listOf(portrait, landscape), portrait.id)) }
        val previous = ClientDependencies.sessionStore
        ClientDependencies.sessionStore = { store }
        try { ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { it.showSavedKeypad() }
            for (profile in listOf(portrait, landscape)) {
                scenario.onActivity { it.selectProfile(profile.id) }
                await("saved controller laid out in ${profile.orientationPreference}") {
                    var ready = false
                    scenario.onActivity { activity ->
                        val surface = findSurface(activity.window.decorView)
                        val isLandscape = activity.resources.configuration.orientation == android.content.res.Configuration.ORIENTATION_LANDSCAPE
                        ready = activity.connectionState.snapshot.selectedID == profile.id && isLandscape == (profile === landscape) && surface != null && surface.childCount == 6 && surface.width > 0
                    }
                    ready
                }
                for (dark in listOf(false, true)) {
                    scenario.onActivity { activity -> findSurface(activity.window.decorView)!!.show(profile, activity.connectionState.surfaceRevision, profile === landscape, dark) }
                    instrumentation.waitForIdleSync()
                    // PixelCopy is issued on a drawn frame, not merely after a queued invalidate.
                    val ready = CountDownLatch(1)
                    scenario.onActivity { activity -> activity.window.decorView.postOnAnimation { ready.countDown() } }
                    assertTrue(ready.await(5, TimeUnit.SECONDS))
                    val done = CountDownLatch(1); val result = AtomicInteger(-1)
                    lateinit var bitmap: Bitmap
                    scenario.onActivity { activity ->
                        bitmap = Bitmap.createBitmap(activity.window.decorView.width, activity.window.decorView.height, Bitmap.Config.ARGB_8888)
                        PixelCopy.request(activity.window, bitmap, { code -> result.set(code); done.countDown() }, Handler(Looper.getMainLooper()))
                    }
                    assertTrue(done.await(5, TimeUnit.SECONDS)); assertEquals(PixelCopy.SUCCESS, result.get())
                    File(instrumentation.targetContext.cacheDir, "renderer-${profile.orientationPreference}-${if (dark) "dark" else "light"}.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
                    bitmap.recycle()
                }
            }
            scenario.onActivity { it.finish() }
        } } finally { ClientDependencies.sessionStore = previous }
    }
}
