package com.thumble.android

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.os.SystemClock
import android.util.Base64
import android.view.MotionEvent
import android.view.View
import android.widget.TextView
import android.view.PixelCopy
import android.os.Handler
import android.os.Looper
import android.view.ViewGroup
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayOutputStream
import java.util.UUID
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

@RunWith(AndroidJUnit4::class)
class AssetStyleDeviceTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private fun png(width: Int, height: Int, color: (Int, Int) -> Int): String {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val pixels = IntArray(width * height) { color(it % width, it / width) }
        bitmap.setPixels(pixels, 0, width, 0, 0, width, height)
        val bytes = ByteArrayOutputStream(); bitmap.compress(Bitmap.CompressFormat.PNG, 100, bytes); bitmap.recycle()
        return Base64.encodeToString(bytes.toByteArray(), Base64.NO_WRAP)
    }
    private fun image(data: String? = null, id: String? = null, content: String = "fill") = JSONObject().put("kind", "image")
        .put("image", JSONObject().put("contentMode", content).apply { if (data != null) put("data", data); if (id != null) put("assetID", id) })
    private fun library(data: String) = JSONObject().put("assets", JSONArray().put(JSONObject().put("id", " photo id ").put("name", "Picture").put("data", data)))
    private fun render(fill: JSONObject, assets: AssetImages = AssetImages(), size: Int = 20): Bitmap {
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        ControlDrawable("rectangle", JSONObject(), fill, 1f, assets).apply { setBounds(0, 0, size, size); draw(Canvas(bitmap)) }
        return bitmap
    }
    private fun Bitmap.check(block: (Bitmap) -> Unit) { try { block(this) } finally { recycle() } }

    @Test fun imageLibraryResolutionInlinePrecedenceDecodeCacheAndInvalidDataAreBounded() {
        val red = png(4, 2) { _, _ -> Color.RED }; val blue = png(4, 2) { _, _ -> Color.BLUE }
        val assets = AssetImages(library(red))
        val fill = image(id = "photo id").getJSONObject("image")
        val first = assets.image(fill)!!
        assertEquals(Color.RED, first.bitmap.getPixel(0, 0)); assertSame(first.bitmap, assets.image(fill)!!.bitmap)
        fill.put("data", blue)
        assertEquals(Color.BLUE, assets.image(fill)!!.bitmap.getPixel(0, 0))
        fill.put("data", "X".repeat(3_400_001))
        assertEquals(Color.RED, assets.image(fill)!!.bitmap.getPixel(0, 0))
        assertNull(AssetImages().image(JSONObject().put("data", "not an image")))
        val large = image(data = png(2048, 1024) { _, _ -> Color.RED }).getJSONObject("image")
        val sampled = AssetImages().image(large, 128, 128)!!
        assertEquals(2048, sampled.intrinsicWidth)
        assertTrue("decode matches the displayed raster size", sampled.bitmap.width <= 256 && sampled.bitmap.height <= 128)
        assertEquals(Color.RED, sampled.bitmap.getPixel(0, 0))
    }
    @Test fun imageFitCropTileOpacityAndNineSliceModesRenderActualPixels() {
        val bands = png(4, 2) { x, _ -> if (x < 2) Color.RED else Color.BLUE }
        render(image(bands, content = "fit"), size = 8).check {
            assertEquals(0, Color.alpha(it.getPixel(1, 0))); assertEquals(Color.RED, it.getPixel(1, 3)); assertEquals(Color.BLUE, it.getPixel(6, 3))
        }
        render(image(bands), size = 8).check { assertEquals(Color.RED, it.getPixel(0, 0)); assertEquals(Color.BLUE, it.getPixel(7, 7)) }
        render(image(bands, content = "tile"), size = 8).check {
            assertEquals(Color.RED, it.getPixel(0, 0)); assertEquals(Color.BLUE, it.getPixel(2, 0)); assertEquals(Color.RED, it.getPixel(4, 0))
        }
        val translucent = image(png(2, 2) { _, _ -> Color.RED })
        translucent.getJSONObject("image").put("opacity", .5)
        render(translucent).check { assertEquals(128, Color.alpha(it.getPixel(10, 10))) }
        val colors = intArrayOf(Color.RED, Color.GREEN, Color.BLUE, Color.CYAN, Color.MAGENTA, Color.YELLOW, Color.BLACK, Color.DKGRAY, Color.WHITE)
        val patches = png(6, 6) { x, y -> colors[(y / 2) * 3 + x / 2] }
        for (mode in listOf("nine_slice_stretch", "nine_slice_tile")) {
            val fill = image(patches)
            fill.getJSONObject("image").put("resizingMode", mode).put("nineSliceInsets", JSONObject()
                .put("leading", 1.0 / 3).put("trailing", 1.0 / 3).put("top", 1.0 / 3).put("bottom", 1.0 / 3))
            render(fill).check {
                assertEquals(Color.RED, it.getPixel(0, 0)); assertEquals(Color.BLUE, it.getPixel(19, 0))
                assertEquals(Color.BLACK, it.getPixel(0, 19)); assertEquals(Color.WHITE, it.getPixel(19, 19))
                assertEquals(Color.MAGENTA, it.getPixel(10, 10))
                assertEquals("neighboring caps cannot bleed into a stretched center", Color.MAGENTA, it.getPixel(3, 10))
            }
        }
        val repeating = image(png(6, 6) { x, y -> if (x in 2..3 && y in 2..3) { if (x == 2) Color.RED else Color.BLUE } else Color.WHITE })
        repeating.getJSONObject("image").put("resizingMode", "nine_slice_tile").put("nineSliceInsets", JSONObject()
            .put("leading", 1.0 / 3).put("trailing", 1.0 / 3).put("top", 1.0 / 3).put("bottom", 1.0 / 3))
        render(repeating).check {
            assertEquals(Color.RED, it.getPixel(4, 10)); assertEquals(Color.BLUE, it.getPixel(5, 10)); assertEquals(Color.RED, it.getPixel(6, 10))
        }
    }
    @Test fun jpegExifOrientationMatchesTheDisplayedImageDimensionsAndPixels() {
        val bitmap = Bitmap.createBitmap(20, 10, Bitmap.Config.ARGB_8888)
        val colors = intArrayOf(Color.RED, Color.GREEN, Color.BLUE, Color.WHITE)
        for (y in 0 until 10) for (x in 0 until 20) bitmap.setPixel(x, y, colors[(if (y < 5) 0 else 2) + if (x < 10) 0 else 1])
        val jpeg = java.io.ByteArrayOutputStream().apply { assertTrue(bitmap.compress(Bitmap.CompressFormat.JPEG,100,this)) }.toByteArray()
        bitmap.recycle()
        assertTrue(jpeg[0] == 0xff.toByte() && jpeg[1] == 0xd8.toByte())
        run {
            val corners = listOf(listOf(0,1,2,3), listOf(1,0,3,2), listOf(3,2,1,0), listOf(2,3,0,1),
                listOf(0,2,1,3), listOf(2,0,3,1), listOf(3,1,2,0), listOf(1,3,0,2))
            for (orientation in 1..8) {
                // A standard APP1/Exif TIFF directory keeps the decoder test
                // independent of platform ExifInterface's version-specific writer.
                val tiff=java.nio.ByteBuffer.allocate(26).putShort(0x4d4d).putShort(42).putInt(8).putShort(1)
                    .putShort(0x0112).putShort(3).putInt(1).putShort(orientation.toShort()).putShort(0).putInt(0).array()
                val oriented=jpeg.copyOfRange(0,2)+byteArrayOf(0xff.toByte(),0xe1.toByte(),0,34)+
                    byteArrayOf(69,120,105,102,0,0)+tiff+jpeg.copyOfRange(2,jpeg.size)
                val fill = image(Base64.encodeToString(oriented, Base64.NO_WRAP)).getJSONObject("image")
                val asset = AssetImages().image(fill)!!
                val w = if (orientation >= 5) 10 else 20; val h = if (orientation >= 5) 20 else 10
                assertEquals(w, asset.intrinsicWidth); assertEquals(h, asset.intrinsicHeight)
                assertEquals(w, asset.bitmap.width); assertEquals(h, asset.bitmap.height)
                for ((index, point) in listOf(2 to 2, w - 3 to 2, 2 to h - 3, w - 3 to h - 3).withIndex()) {
                    val actual = asset.bitmap.getPixel(point.first, point.second); val expected = colors[corners[orientation - 1][index]]
                    assertEquals("EXIF $orientation corner $index red", Color.red(expected).toDouble(), Color.red(actual).toDouble(), 35.0)
                    assertEquals("EXIF $orientation corner $index green", Color.green(expected).toDouble(), Color.green(actual).toDouble(), 35.0)
                    assertEquals("EXIF $orientation corner $index blue", Color.blue(expected).toDouble(), Color.blue(actual).toDouble(), 35.0)
                }
            }
        }
    }
    @Test fun imageAdjustmentAndAlphaFollowTheNativeParameterRanges() {
        val fill = image(png(2, 2) { _, _ -> Color.rgb(50, 50, 50) })
        fill.getJSONObject("image").put("exposure", 1)
        render(fill).check { assertTrue(Color.red(it.getPixel(10, 10)) in 105..107) }
        fill.getJSONObject("image").put("exposure", 0).put("contrast", 1)
        render(fill).check { assertTrue(Color.red(it.getPixel(10, 10)) in 6..8) }
        fill.getJSONObject("image").put("opacity", -1)
        render(fill).check { assertEquals(0, Color.alpha(it.getPixel(10, 10))) }
        fill.getJSONObject("image").put("opacity", 1).put("contrast", 0).put("shadows", 1)
        render(fill).check { assertTrue(Color.red(it.getPixel(10, 10)) in 69..71) }
        fill.getJSONObject("image").put("shadows", 0).put("highlights", 1)
        render(fill).check { assertTrue(Color.red(it.getPixel(10, 10)) in 39..41) }
        val colored = image(png(2, 2) { _, _ -> Color.rgb(100, 150, 200) })
        colored.getJSONObject("image").put("saturation", -1)
        render(colored).check {
            val color = it.getPixel(10, 10)
            assertTrue(Color.red(color) in 133..135); assertTrue(Color.green(color) in 143..145); assertTrue(Color.blue(color) in 153..155)
        }
        colored.getJSONObject("image").put("saturation", 0).put("tint", 1)
        var tinted = 0
        render(colored).check { tinted = it.getPixel(10, 10); assertNotEquals(Color.rgb(100, 150, 200), tinted) }
        colored.getJSONObject("image").put("tint", 0).put("temperature", 1)
        render(colored).check { assertEquals("native hue adjustment uses tint plus temperature", tinted, it.getPixel(10, 10)) }
    }
    private fun profile(elements: JSONArray, library: JSONObject = JSONObject(), styleLibrary: JSONObject = JSONObject()) = ControllerProfile.parse(JSONObject()
        .put("id", UUID.randomUUID().toString()).put("name", "Asset/style acceptance").put("customization", JSONObject()
            .put("elements", elements).put("assetLibrary", library).put("styleLibrary", styleLibrary)))
    private fun solid(color: Int) = JSONObject().put("kind", "solid").put("color", rgbaJSON(color))
    private fun element(kind: String, fill: Int) = JSONObject().put("id", UUID.randomUUID().toString()).put("kind", kind).put("label", "Control")
        .put("layout", JSONObject().put("centerX", .5).put("centerY", .5).put("shape", "rectangle").put("fillStyle", solid(fill)))
    private fun size(surface: ControllerSurface) {
        surface.measure(View.MeasureSpec.makeMeasureSpec(1000, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(1000, View.MeasureSpec.EXACTLY))
        surface.layout(0, 0, 1000, 1000)
    }
    @Test fun pressedStyleSwitchesCachedImageFillAndTypographyWithoutChangingPhysicalOwnership() {
        val data = png(4, 4) { _, _ -> Color.BLUE }
        val element = element("button", Color.RED)
        element.put("presentation", JSONObject().put("accessibilityName", "Activate fixture"))
        element.getJSONObject("layout").put("styleID", "picture").put("visualStyle", JSONObject().put("normal", JSONObject().put("foregroundColor", rgbaJSON(Color.MAGENTA))))
        val visual = JSONObject().put("normal", JSONObject().put("fillStyle", image(id = "photo-id")).put("content", JSONObject().put("legend", "Idle")))
            .put("pressed", JSONObject().put("fillStyle", solid(Color.GREEN)).put("scale", .5).put("opacity", .6).put("foregroundColor", rgbaJSON(Color.WHITE))
                .put("content", JSONObject().put("legend", "Held").put("fontSize", 20)))
        val styles = JSONObject().put("styles", JSONArray().put(JSONObject().put("id", "picture").put("name", "Picture").put("visualStyle", visual)))
        val profile = profile(JSONArray().put(element), library(data), styles)
        instrumentation.runOnMainSync {
            val surface = ControllerSurface(instrumentation.targetContext)
            surface.show(profile, 1, false, false); size(surface)
            val child = surface.getChildAt(0) as TextView
            assertEquals("Idle", child.text.toString()); assertEquals("Activate fixture", child.contentDescription)
            val original = android.graphics.Rect(child.left, child.top, child.right, child.bottom)
            val events = mutableListOf<Pair<Boolean, Long>>()
            surface.onEdge = { _, down, press -> events.add(down to press) }
            fun touch(action: Int, fraction: Float = .8f) {
                val event = MotionEvent.obtain(0, SystemClock.uptimeMillis(), action, child.left + child.width * fraction, child.top + child.height / 2f, 0)
                surface.dispatchTouchEvent(event); event.recycle()
            }
            touch(MotionEvent.ACTION_DOWN)
            assertEquals("Held", child.text.toString()); assertEquals(.47f, child.scaleX, .0001f); assertEquals(.6f, child.alpha, .0001f)
            assertEquals(Color.MAGENTA, child.currentTextColor)
            assertEquals(original, android.graphics.Rect(child.left, child.top, child.right, child.bottom))
            val frame = Bitmap.createBitmap(child.width, child.height, Bitmap.Config.ARGB_8888)
            child.background.setBounds(0, 0, child.width, child.height)
            child.background.draw(Canvas(frame)); assertEquals(Color.GREEN, frame.getPixel(child.width / 2, child.height / 2)); frame.recycle()
            val presentation = (child as ControlFaceView).appliedPresentation
            touch(MotionEvent.ACTION_MOVE, .9f)
            assertSame("movement reuses the presentation", presentation, child.appliedPresentation)
            assertEquals(1, events.size)
            touch(MotionEvent.ACTION_UP, .9f)
            assertEquals("Idle", child.text.toString()); assertEquals(1f, child.scaleX, 0f)
            assertEquals(listOf(true, false), events.map { it.first }); assertEquals(events[0].second, events[1].second)
        }
    }
    @Test fun joystickIndicatorRespectsControlLayerOrder() {
        val joystick = element("joystick", Color.RED)
        val button = element("button", Color.BLUE)
        for (element in listOf(joystick, button)) element.getJSONObject("layout").put("showsIntegratedLabel", false)
        button.getJSONObject("layout").put("zIndex", 1)
        instrumentation.runOnMainSync {
            val surface = ControllerSurface(instrumentation.targetContext)
            surface.show(profile(JSONArray().put(joystick).put(button)), 1, false, false); size(surface)
            val bitmap = Bitmap.createBitmap(1000, 1000, Bitmap.Config.ARGB_8888)
            surface.draw(Canvas(bitmap)); assertEquals(Color.BLUE, bitmap.getPixel(500, 500)); bitmap.recycle()
        }
    }

    @Test fun visibleSavedImageStylesCaptureNormalAndPressedState() {
        val bands = png(12, 8) { x, y -> if (x < 4) Color.rgb(25, 105, 160) else if (x < 8) Color.rgb(120, 165, 185) else Color.rgb(210, 230, 235) }
        val photo = element("button", Color.RED)
        photo.put("label", "Photo").getJSONObject("layout").put("centerY", .2).put("widthScale", 3).put("heightScale", 1.4).put("styleID", "photo")
        val nine = element("button", Color.RED)
        val nineFill = image(data = png(6, 6) { x, y -> if (x < 2 || y < 2 || x >= 4 || y >= 4) Color.rgb(10, 80, 110) else Color.rgb(195, 220, 225) })
        nineFill.getJSONObject("image").put("resizingMode", "nine_slice_stretch").put("nineSliceInsets", JSONObject().put("top", .33).put("leading", .33).put("bottom", .33).put("trailing", .33))
        nine.put("label", "Nine-slice").getJSONObject("layout").put("centerY", .5).put("widthScale", 3).put("heightScale", 1.4).put("fillStyle", nineFill)
        val tile = element("button", Color.RED)
        tile.put("label", "Tiled image").getJSONObject("layout").put("centerY", .8).put("widthScale", 3).put("heightScale", 1.4).put("fillStyle", image(data = bands, content = "tile"))
        val normal = JSONObject().put("fillStyle", image(id = "photo-id", content = "fit")).put("foregroundColor", rgbaJSON(Color.BLACK)).put("strokeColor", rgbaJSON(Color.rgb(25, 105, 160)))
            .put("content", JSONObject().put("legend", "Photo · ready").put("fontSize", 18))
        val pressed = JSONObject().put("fillStyle", solid(Color.rgb(20, 120, 80))).put("foregroundColor", rgbaJSON(Color.WHITE))
            .put("content", JSONObject().put("legend", "Photo · held").put("fontSize", 20)).put("scale", .9)
        val styles = JSONObject().put("styles", JSONArray().put(JSONObject().put("id", "photo").put("name", "Photo").put("visualStyle", JSONObject().put("normal", normal).put("pressed", pressed))))
        val profile = profile(JSONArray().put(photo).put(nine).put(tile), library(bands), styles)
        profile.source.put("orientationPreference", "portrait")
        val store = MemorySessionStore().apply { saveSnapshot(ProfileSnapshot(listOf(profile), profile.id)) }
        val previous = ClientDependencies.sessionStore
        ClientDependencies.sessionStore = { store }
        fun find(view: View): ControllerSurface? {
            if (view is ControllerSurface) return view
            if (view is ViewGroup) for (index in 0 until view.childCount) find(view.getChildAt(index))?.let { return it }
            return null
        }
        try { ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { it.showSavedKeypad() }
            val deadline = SystemClock.elapsedRealtime() + 10_000
            var laidOut = false
            while (!laidOut && SystemClock.elapsedRealtime() < deadline) {
                scenario.onActivity { activity -> val surface = find(activity.window.decorView); laidOut = activity.connectionState.viewingSaved && surface != null && surface.width > 0 && surface.childCount == 3 }
                if (!laidOut) SystemClock.sleep(20)
            }
            assertTrue(laidOut)
            for (held in listOf(false, true)) {
                if (held) scenario.onActivity { activity ->
                    assertTrue(activity.connectionState.practiceMode); assertFalse(activity.connectionState.paired)
                    val surface = find(activity.window.decorView)!!; val child = surface.getChildAt(0)
                    val event = MotionEvent.obtain(0, SystemClock.uptimeMillis(), MotionEvent.ACTION_DOWN, child.left + child.width / 2f, child.top + child.height / 2f, 0)
                    surface.dispatchTouchEvent(event); event.recycle()
                    assertEquals("Photo · held", (child as TextView).text.toString())
                }
                val drawn = CountDownLatch(1)
                scenario.onActivity { activity -> activity.window.decorView.postOnAnimation { activity.window.decorView.postOnAnimation { drawn.countDown() } } }
                assertTrue(drawn.await(5, TimeUnit.SECONDS))
                val done = CountDownLatch(1); val result = AtomicInteger(-1)
                lateinit var bitmap: Bitmap
                scenario.onActivity { activity ->
                    bitmap = Bitmap.createBitmap(activity.window.decorView.width, activity.window.decorView.height, Bitmap.Config.ARGB_8888)
                    PixelCopy.request(activity.window, bitmap, { result.set(it); done.countDown() }, Handler(Looper.getMainLooper()))
                }
                assertTrue(done.await(5, TimeUnit.SECONDS)); assertEquals(PixelCopy.SUCCESS, result.get())
                File(instrumentation.targetContext.cacheDir, "asset-style-${if (held) "pressed" else "normal"}.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
                bitmap.recycle()
            }
            scenario.onActivity { activity -> find(activity.window.decorView)!!.cancelTouches(); activity.finish() }
        } } finally { ClientDependencies.sessionStore = previous }
    }
}
