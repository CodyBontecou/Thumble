package com.thumble.android

import android.graphics.*
import android.os.SystemClock
import android.util.Base64
import android.view.MotionEvent
import android.view.View
import android.widget.TextView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayOutputStream
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class IconArtworkDeviceTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private fun solid(color: Int) = JSONObject().put("kind", "solid").put("color", rgbaJSON(color))
    private fun layer(id: String, plane: String, color: Int, opacity: Double = 1.0) = JSONObject().put("id", id).put("plane", plane)
        .put("fillStyle", solid(color)).put("opacity", opacity)
    private fun profile(element: JSONObject, layers: JSONArray = JSONArray()) = ControllerProfile.parse(JSONObject().put("id", UUID.randomUUID().toString())
        .put("customization", JSONObject().put("elements", JSONArray().put(element)).put("artworkLayers", layers)))
    private fun button() = JSONObject().put("id", UUID.randomUUID().toString()).put("kind", "button").put("label", "Long legend")
        .put("layout", JSONObject().put("shape", "rectangle").put("centerX", .5).put("centerY", .5).put("fillStyle", solid(Color.BLUE)).put("showsIntegratedLabel", false))
    private fun size(surface: ControllerSurface) {
        surface.measure(View.MeasureSpec.makeMeasureSpec(600, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(600, View.MeasureSpec.EXACTLY)); surface.layout(0, 0, 600, 600)
    }
    @Test fun passiveArtworkPlanesPaintAroundControlsAndNeverInterceptTouch() {
        val element = button()
        val layers = JSONArray().put(layer("under", "underlay", Color.GREEN)).put(layer("over", "overlay", Color.RED, .5).put("zIndex", -10000))
        instrumentation.runOnMainSync {
            val surface = ControllerSurface(instrumentation.targetContext)
            surface.show(profile(element, layers), 1, false, false); size(surface)
            assertEquals("artwork creates no Views or AX targets", 1, surface.childCount)
            val bitmap = Bitmap.createBitmap(600, 600, Bitmap.Config.ARGB_8888)
            surface.draw(Canvas(bitmap))
            val middle = bitmap.getPixel(300, 300); val outside = bitmap.getPixel(10, 10)
            assertEquals(128.0, Color.red(middle).toDouble(), 1.0); assertEquals(127.0, Color.blue(middle).toDouble(), 1.0)
            assertEquals(128.0, Color.red(outside).toDouble(), 1.0); assertEquals(127.0, Color.green(outside).toDouble(), 1.0)
            bitmap.recycle()
            val edges = mutableListOf<Boolean>(); surface.onEdge = { _, down, _ -> edges.add(down) }
            for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
                val event = MotionEvent.obtain(0, SystemClock.uptimeMillis(), action, 300f, 300f, 0)
                surface.dispatchTouchEvent(event); event.recycle()
            }
            assertEquals(listOf(true, false), edges)
        }
    }
    @androidx.test.filters.SdkSuppress(minSdkVersion = 29)
    @Test fun allArtworkBlendModesRenderAndLegacySoftLightMatchesThePlatform() {
        fun render(mode: String, legacy: Boolean): Bitmap {
            val layers = JSONArray().put(layer("blend", "overlay", Color.rgb(210,110,180), .6).put("blendMode", mode)
                .put("frame",JSONObject().put("x",0).put("y",0).put("width",.5).put("height",1)))
            val painter = ArtworkPainter(layers, AssetImages(), 1f, legacy)
            val bitmap = Bitmap.createBitmap(20, 20, Bitmap.Config.ARGB_8888)
            bitmap.eraseColor(Color.argb(128,80,100,60)); painter.resize(20,20); painter.draw(Canvas(bitmap), "overlay", bitmap)
            return bitmap
        }
        val values = mutableSetOf<Int>()
        for (mode in listOf("normal", "multiply", "screen", "overlay", "soft_light")) {
            val bitmap = render(mode, false); values.add(bitmap.getPixel(5,10)); bitmap.recycle()
        }
        assertEquals(5, values.size)
        for (mode in listOf("normal","multiply","screen","overlay","soft_light")) {
            val platform = render(mode, false); val legacy = render(mode, true)
            for (point in listOf(5 to 10,15 to 10)) for (channel in listOf<(Int)->Int>(Color::red,Color::green,Color::blue,Color::alpha)) {
                assertEquals("$mode respects source-over alpha inside and outside its frame",channel(platform.getPixel(point.first,point.second)).toDouble(),channel(legacy.getPixel(point.first,point.second)).toDouble(),2.0)
            }
            platform.recycle(); legacy.recycle()
        }
    }
    @Test fun legacySurfaceSoftwareBlendPreservesControlsAndBackgroundPixels() {
        instrumentation.runOnMainSync {
            val element = button(); element.getJSONObject("layout").put("fillStyle",solid(Color.rgb(96,96,96)))
            val layers = JSONArray().put(layer("under","underlay",Color.rgb(64,64,64)))
                .put(layer("soft","overlay",Color.rgb(192,192,192),.6).put("blendMode","soft_light"))
            val profile = profile(element,layers)
            fun surface(legacy: Boolean): Bitmap {
                val view = ControllerSurface(instrumentation.targetContext, legacy)
                view.show(profile,1,false,false); size(view)
                return Bitmap.createBitmap(600,600,Bitmap.Config.ARGB_8888).also { view.draw(Canvas(it)) }
            }
            val fallback = surface(true)
            assertEquals(114.0,Color.red(fallback.getPixel(300,300)).toDouble(),2.0)
            assertEquals(83.0,Color.red(fallback.getPixel(10,10)).toDouble(),2.0)
            fallback.recycle()
        }
    }
    private fun assetLibrary(): AssetImages {
        val bitmap = Bitmap.createBitmap(4, 2, Bitmap.Config.ARGB_8888)
        for (y in 0..1) for (x in 0..3) bitmap.setPixel(x,y,if (x < 2) Color.RED else Color.BLUE)
        val out = ByteArrayOutputStream(); bitmap.compress(Bitmap.CompressFormat.PNG, 100, out); bitmap.recycle()
        return AssetImages(JSONObject().put("assets", JSONArray().put(JSONObject().put("id", "picture").put("name", "Picture")
            .put("data", Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)))))
    }
    @Test fun imageIconsRespectTemplateAndOriginalModeAndTemplateSymbolsAreVisible() {
        val assets = assetLibrary()
        for (mode in listOf("original", "template")) {
            val spec = ControlIcon.parse(JSONObject().put("source", "asset").put("value", "picture").put("renderingMode", mode))!!
            val bitmap = Bitmap.createBitmap(40, 40, Bitmap.Config.ARGB_8888)
            IconPainter(spec, assets).draw(Canvas(bitmap),20f,20f,20f,Color.GREEN)
            assertEquals(if (mode == "original") Color.RED else Color.GREEN, bitmap.getPixel(12,20))
            assertEquals(if (mode == "original") Color.BLUE else Color.GREEN, bitmap.getPixel(27,20)); bitmap.recycle()
        }
        for (symbol in listOf("arrow.up", "arrow.down", "arrow.left", "arrow.right", "return", "arrow.right.to.line", "command", "terminal", "command.square", "xmark.octagon.fill")) {
            val spec = ControlIcon.parse(JSONObject().put("source", "sf_symbol").put("value", symbol))!!
            val bitmap = Bitmap.createBitmap(40,40,Bitmap.Config.ARGB_8888)
            IconPainter(spec, assets).draw(Canvas(bitmap),20f,20f,24f,Color.GREEN)
            val pixels = IntArray(1600); bitmap.getPixels(pixels,0,40,0,0,40,40)
            assertTrue("$symbol has a portable visible rendering", pixels.count { Color.alpha(it) > 0 } > 20); bitmap.recycle()
        }
    }
    @Test fun centeredIconLegendPolicyChangesWithStateAndKeepsAccessibilityAndPressIdentity() {
        val element = button().put("presentation", JSONObject().put("accessibilityName", "Launch action"))
        element.getJSONObject("layout").put("showsIntegratedLabel", true).put("icon", JSONObject().put("source", "text").put("value", "↑"))
            .put("visualStyle", JSONObject().put("pressed", JSONObject().put("content", JSONObject().put("legend", "GO"))))
        instrumentation.runOnMainSync {
            val surface = ControllerSurface(instrumentation.targetContext)
            surface.show(profile(element),1,false,false); size(surface)
            val view = surface.getChildAt(0) as TextView
            assertEquals("", view.text.toString()); assertEquals("Launch action", view.contentDescription)
            val edges = mutableListOf<Pair<Boolean,Long>>(); surface.onEdge = { _, down, press -> edges.add(down to press) }
            val down = MotionEvent.obtain(0,0,MotionEvent.ACTION_DOWN,300f,300f,0)
            surface.dispatchTouchEvent(down); down.recycle()
            assertEquals("GO", view.text.toString()); assertEquals("Launch action", view.contentDescription)
            val up = MotionEvent.obtain(0,1,MotionEvent.ACTION_UP,300f,300f,0)
            surface.dispatchTouchEvent(up); up.recycle()
            assertEquals("", view.text.toString()); assertEquals(listOf(true,false),edges.map { it.first }); assertEquals(edges[0].second,edges[1].second)
        }
    }
}
