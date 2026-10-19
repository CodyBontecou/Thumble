package com.thumble.android

import android.graphics.*
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.PixelCopy
import android.os.SystemClock
import android.os.Handler
import android.os.Looper
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

@RunWith(AndroidJUnit4::class)
class EffectsDeviceTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private fun solid(c: Int) = JSONObject().put("kind","solid").put("color",rgbaJSON(c))
    private fun render(p: JSONObject, fill: Int = Color.WHITE): Bitmap {
        val bitmap = Bitmap.createBitmap(140,140,Bitmap.Config.ARGB_8888)
        val drawable = ControlDrawable("rectangle",JSONObject(),solid(fill),1f,AssetImages(),p)
        drawable.setBounds(40,40,100,100); drawable.draw(Canvas(bitmap))
        return bitmap
    }
    private fun Bitmap.check(block: (Bitmap)->Unit) { try { block(this) } finally { recycle() } }
    @Test fun outerShadowGlowAndStackedShadowAlphaSurviveOutsideTheVisualFrame() {
        render(JSONObject().put("shadowColor",rgbaJSON(Color.RED)).put("shadowRadius",4).put("shadowX",10)).check {
            val shadow = it.getPixel(105,70)
            assertTrue("shadow extends beyond the face",Color.alpha(shadow)>20); assertTrue(Color.red(shadow)>200)
            assertEquals(Color.WHITE,it.getPixel(70,70))
        }
        render(JSONObject().put("glowColor",rgbaJSON(Color.BLUE)).put("glowRadius",6),Color.TRANSPARENT).check {
            val glow = it.getPixel(37,70)
            assertTrue(Color.alpha(glow)>0); assertTrue(Color.blue(glow)>200)
        }
        val shadows = JSONArray().put(JSONObject().put("color",rgbaJSON(Color.RED)).put("radius",0).put("x",10))
            .put(JSONObject().put("color",rgbaJSON(Color.BLUE)).put("radius",0).put("x",10))
        render(JSONObject().put("shadows",shadows)).check {
            assertTrue("second shadow includes the first shadow's alpha",Color.blue(it.getPixel(115,70))>200)
            assertTrue(Color.alpha(it.getPixel(115,70))>200)
        }
        // Array shadows have a 96pt budget in the shared model, unlike scalar effects.
        for ((authored, expected) in listOf(80 to 80, 1000 to 96)) {
            val bitmap = Bitmap.createBitmap(240,140,Bitmap.Config.ARGB_8888)
            val p = JSONObject().put("shadows",JSONArray().put(JSONObject()
                .put("color",rgbaJSON(Color.RED)).put("radius",0).put("x",authored)))
            val drawable = ControlDrawable("rectangle",JSONObject(),solid(Color.WHITE),1f,AssetImages(),p)
            drawable.setBounds(40,40,100,100); drawable.draw(Canvas(bitmap))
            bitmap.check {
                assertEquals("authored array offset survives normalization",Color.RED,it.getPixel(95+expected,70))
                assertEquals("array offset stays within the native budget",0,Color.alpha(it.getPixel(101+expected,70)))
            }
        }
    }
    @Test fun innerEffectsRespectShapeMaskDirectionAndNativeStateMarkGeometry() {
        render(JSONObject().put("innerShadowColor",rgbaJSON(Color.BLACK)).put("innerShadowRadius",4).put("innerShadowX",4)).check {
            assertEquals(0,Color.alpha(it.getPixel(35,70)))
            assertTrue(Color.red(it.getPixel(42,70))<Color.red(it.getPixel(70,70)))
        }
        render(JSONObject().put("highlightColor",rgbaJSON(Color.RED)).put("highlightOpacity",1).put("highlightRadius",0).put("highlightX",20)).check {
            assertEquals(Color.WHITE,it.getPixel(45,70)); assertEquals(Color.RED,it.getPixel(80,70)); assertEquals(0,Color.alpha(it.getPixel(105,70)))
        }
        render(JSONObject().put("bevelWidth",4).put("bevelHighlightColor",rgbaJSON(Color.RED)).put("bevelShadowColor",rgbaJSON(Color.BLUE))).check {
            assertTrue(Color.red(it.getPixel(41,41))>Color.blue(it.getPixel(41,41)))
            assertTrue(Color.blue(it.getPixel(98,98))>Color.red(it.getPixel(98,98)))
        }
        render(JSONObject().put("indexColor",rgbaJSON(Color.GREEN)).put("indexWidth",3)).check {
            assertEquals(Color.GREEN,it.getPixel(70,43)); assertEquals(Color.WHITE,it.getPixel(50,43)); assertEquals(Color.WHITE,it.getPixel(70,70))
        }
    }
    @Test fun gaussianApproximationPreservesColoredTransparencyWithoutBlackFringes() {
        val source = Bitmap.createBitmap(31,31,Bitmap.Config.ARGB_8888)
        for (y in 12..18) for (x in 12..18) source.setPixel(x,y,0x80ff0000.toInt())
        val blur = blurBitmap(source,3f)
        val center = blur.getPixel(15,15); val edge = blur.getPixel(10,15)
        assertTrue(Color.alpha(center) in 1..127); assertTrue(Color.alpha(edge)>0)
        assertTrue(Color.red(center)>250); assertTrue(Color.red(edge)>250); assertEquals(0,Color.green(edge)); assertEquals(0,Color.blue(edge))
        blur.recycle(); source.recycle()
    }
    private fun profile(blur: Boolean): ControllerProfile {
        val normal = JSONObject().put("blurRadius",if (blur) 2 else 0).put("fillStyle",solid(Color.RED)).put("shadowColor",rgbaJSON(Color.TRANSPARENT))
        val pressed = JSONObject().put("blurRadius",if (blur) 5 else 0).put("fillStyle",solid(Color.GREEN)).put("scale",1)
        val style = JSONObject().put("centerX",.5).put("centerY",.5).put("shape","rectangle").put("showsIntegratedLabel",false)
            .put("visualStyle",JSONObject().put("normal",normal).put("pressed",pressed))
        val element = JSONObject().put("id",UUID.randomUUID().toString()).put("label","Effects").put("kind","button").put("layout",style)
        return ControllerProfile.parse(JSONObject().put("id",UUID.randomUUID().toString()).put("customization",JSONObject().put("elements",JSONArray().put(element))))
    }
    @Test fun fullFaceBlurAndCachedStateChangesKeepLogicalBoundsAndPhysicalOwnership() {
        instrumentation.runOnMainSync {
            val surface = ControllerSurface(instrumentation.targetContext)
            surface.show(profile(true),1,false,false)
            surface.measure(View.MeasureSpec.makeMeasureSpec(600,View.MeasureSpec.EXACTLY),View.MeasureSpec.makeMeasureSpec(600,View.MeasureSpec.EXACTLY)); surface.layout(0,0,600,600)
            val child = surface.getChildAt(0)
            val bounds = Rect(child.left,child.top,child.right,child.bottom)
            val edges = mutableListOf<Pair<Boolean,Long>>(); surface.onEdge = { _,down,press -> edges.add(down to press) }
            val bitmap = Bitmap.createBitmap(600,600,Bitmap.Config.ARGB_8888)
            surface.draw(Canvas(bitmap)); assertTrue(Color.red(bitmap.getPixel(300,300))>240); assertTrue(Color.green(bitmap.getPixel(300,300))<20)
            assertTrue("blur extends beyond the unmodified logical frame",Color.green(bitmap.getPixel(child.left-3,300))<Color.green(bitmap.getPixel(20,20)))
            val down = MotionEvent.obtain(0,0,MotionEvent.ACTION_DOWN,300f,300f,0); surface.dispatchTouchEvent(down); down.recycle()
            surface.draw(Canvas(bitmap)); assertTrue(Color.green(bitmap.getPixel(300,300))>240); assertTrue(Color.red(bitmap.getPixel(300,300))<20)
            assertEquals(bounds,Rect(child.left,child.top,child.right,child.bottom))
            val move = MotionEvent.obtain(0,1,MotionEvent.ACTION_MOVE,child.right-2f,300f,0); surface.dispatchTouchEvent(move); move.recycle()
            surface.draw(Canvas(bitmap)); assertEquals(1,edges.size)
            val up = MotionEvent.obtain(0,2,MotionEvent.ACTION_UP,child.right-2f,300f,0); surface.dispatchTouchEvent(up); up.recycle()
            assertEquals(listOf(true,false),edges.map { it.first }); assertEquals(edges[0].second,edges[1].second)
            bitmap.recycle()
        }
    }
    @Test fun visibleEffectsPracticeCapturesNormalAndFourSimultaneousPressedFaces() {
        val elements = JSONArray()
        val names = listOf("Raised","Inset","Glow","Soft")
        for ((index,name) in names.withIndex()) {
            val normal = JSONObject().put("fillStyle",solid(if (index < 2) 0xffe8eef4.toInt() else if (index == 2) 0xff215991.toInt() else 0xff36a086.toInt()))
                .put("foregroundColor",rgbaJSON(if (index < 2) 0xff22405c.toInt() else Color.WHITE)).put("content",JSONObject().put("fontSize",18))
            val pressed = JSONObject().put("indexColor",rgbaJSON(0xff57c4e5.toInt())).put("indexWidth",3)
            if (index == 0) {
                normal.put("shadows",JSONArray().put(JSONObject().put("color",rgbaJSON(0xccffffff.toInt())).put("radius",5).put("x",-4).put("y",-4))
                    .put(JSONObject().put("color",rgbaJSON(0x55405c78)).put("radius",8).put("x",5).put("y",5)))
                pressed.put("shadows",JSONArray()).put("shadowColor",rgbaJSON(Color.TRANSPARENT)).put("innerShadowColor",rgbaJSON(0x88405c78.toInt())).put("innerShadowRadius",5).put("innerShadowX",2).put("innerShadowY",2)
            }
            if (index == 1) {
                normal.put("innerShadowColor",rgbaJSON(0x88405c78.toInt())).put("innerShadowRadius",7).put("innerShadowX",4).put("innerShadowY",4)
                    .put("bevelHighlightColor",rgbaJSON(Color.WHITE)).put("bevelShadowColor",rgbaJSON(0x55405c78)).put("bevelWidth",1.5)
                pressed.put("innerShadowRadius",3).put("innerShadowX",1).put("innerShadowY",1)
            }
            if (index == 2) {
                normal.put("glowColor",rgbaJSON(0xaa57c4e5.toInt())).put("glowRadius",6).put("highlightColor",rgbaJSON(Color.WHITE))
                    .put("highlightOpacity",.2).put("highlightRadius",4).put("highlightX",-3).put("highlightY",-3)
                pressed.put("glowRadius",12)
            }
            if (index == 3) { normal.put("blurRadius",1); pressed.put("blurRadius",3) }
            val style = JSONObject().put("centerX",.25+(index%2)*.5).put("centerY",.3+(index/2)*.4).put("widthScale",1.5).put("heightScale",1.5)
                .put("cornerRadius",16).put("shape","rounded_rectangle").put("visualStyle",JSONObject().put("normal",normal).put("pressed",pressed))
            elements.put(JSONObject().put("id",UUID.randomUUID().toString()).put("kind","button").put("label",name).put("layout",style))
        }
        val p = ControllerProfile.parse(JSONObject().put("id",UUID.randomUUID().toString()).put("name","Effects acceptance").put("orientationPreference","portrait")
            .put("customization",JSONObject().put("elements",elements)))
        val store = MemorySessionStore().apply { saveSnapshot(ProfileSnapshot(listOf(p),p.id)) }
        val previous = ClientDependencies.sessionStore; ClientDependencies.sessionStore = { store }
        fun find(view: View): ControllerSurface? {
            if (view is ControllerSurface) return view
            if (view is ViewGroup) for (i in 0 until view.childCount) find(view.getChildAt(i))?.let { return it }
            return null
        }
        try { ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { it.showSavedKeypad() }
            val deadline = SystemClock.elapsedRealtime()+10_000
            var ready = false
            while (!ready && SystemClock.elapsedRealtime()<deadline) {
                scenario.onActivity { val surface = find(it.window.decorView); ready = it.connectionState.practiceMode && surface != null && surface.childCount==4 && surface.width>0 }
                if (!ready) SystemClock.sleep(20)
            }
            assertTrue(ready)
            fun touch(action: Int,count: Int) = scenario.onActivity { activity ->
                val surface = find(activity.window.decorView)!!
                val props = Array(count) { index -> MotionEvent.PointerProperties().apply { id=index+1; toolType=MotionEvent.TOOL_TYPE_FINGER } }
                val coords = Array(count) { index -> MotionEvent.PointerCoords().apply { val child=surface.getChildAt(index); x=child.left+child.width/2f; y=child.top+child.height/2f; pressure=1f; size=1f } }
                val event=MotionEvent.obtain(0,SystemClock.uptimeMillis(),action,count,props,coords,0,0,1f,1f,0,0,android.view.InputDevice.SOURCE_TOUCHSCREEN,0)
                surface.dispatchTouchEvent(event);event.recycle()
            }
            for (held in listOf(false,true)) {
                if (held) {
                    touch(MotionEvent.ACTION_DOWN,1)
                    for (count in 2..4) touch(MotionEvent.ACTION_POINTER_DOWN or ((count-1) shl MotionEvent.ACTION_POINTER_INDEX_SHIFT),count)
                    scenario.onActivity { activity ->
                        assertFalse(activity.connectionState.paired)
                        val surface=find(activity.window.decorView)!!
                        for (i in 0..3) assertTrue(surface.getChildAt(i).isPressed)
                    }
                }
                val drawn=CountDownLatch(1)
                scenario.onActivity { activity -> activity.window.decorView.postOnAnimation { activity.window.decorView.postOnAnimation { drawn.countDown() } } }
                assertTrue(drawn.await(5,TimeUnit.SECONDS))
                val copied=CountDownLatch(1);val result=AtomicInteger(-1);lateinit var bitmap: Bitmap
                scenario.onActivity { activity ->
                    bitmap=Bitmap.createBitmap(activity.window.decorView.width,activity.window.decorView.height,Bitmap.Config.ARGB_8888)
                    PixelCopy.request(activity.window,bitmap,{ result.set(it);copied.countDown() },Handler(Looper.getMainLooper()))
                }
                assertTrue(copied.await(5,TimeUnit.SECONDS));assertEquals(PixelCopy.SUCCESS,result.get())
                File(instrumentation.targetContext.cacheDir,"effects-${if (held) "pressed" else "normal"}.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG,100,it) };bitmap.recycle()
            }
            touch(MotionEvent.ACTION_CANCEL,4)
            scenario.onActivity { it.finish() }
        } } finally { ClientDependencies.sessionStore=previous }
    }
}
