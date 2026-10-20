package com.thumble.android

import android.text.Layout
import android.text.TextPaint
import android.util.TypedValue
import android.view.View
import android.widget.TextView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class TypographyDeviceTest {
    private val instrumentation get()=InstrumentationRegistry.getInstrumentation()
    private fun surface(kind: String="button",label: String="MMMM",content: JSONObject=JSONObject(),context: android.content.Context=instrumentation.targetContext): Pair<ControllerSurface,TextView> {
        val element=JSONObject().put("id",UUID.randomUUID().toString()).put("kind",kind).put("label",label)
            .put("layout",JSONObject().put("visualStyle",JSONObject().put("normal",JSONObject().put("content",content))
                .put("pressed",JSONObject().put("content",JSONObject().put("fontSize",21).put("tracking",0)))))
        val profile=ControllerProfile.parse(JSONObject().put("id",UUID.randomUUID().toString()).put("customization",JSONObject().put("elements",JSONArray().put(element))))
        val view=ControllerSurface(context);view.show(profile,1,false,false)
        view.measure(View.MeasureSpec.makeMeasureSpec(800,View.MeasureSpec.EXACTLY),View.MeasureSpec.makeMeasureSpec(800,View.MeasureSpec.EXACTLY));view.layout(0,0,800,800)
        return view to view.getChildAt(0) as TextView
    }
    @Test fun authoredTrackingRemainsAnAbsoluteDistanceAcrossAutoSizedText() {
        instrumentation.runOnMainSync {
            val (_,label)=surface(content=JSONObject().put("tracking",2))
            val density=label.resources.displayMetrics.scaledDensity
            fun extra(size: Float): Float {
                val tracked=TextPaint(label.paint).apply { textSize=size*density }
                val baseline=TextPaint(tracked).apply { letterSpacing=0f }
                return Layout.getDesiredWidth(label.text,tracked)-Layout.getDesiredWidth(label.text.toString(),baseline)
            }
            val small=extra(12f);val large=extra(30f)
            assertTrue("tracking is painted",small>density)
            assertEquals("tracking is authored in points, independent of auto-size",small.toDouble(),large.toDouble(),.6)
        }
    }
    @Test fun authoredFallbackUsesNativeMinimumScaleAndTextControlHeight() {
        instrumentation.runOnMainSync {
            val (_,short)=surface(label="AB",content=JSONObject().put("tracking",1))
            val scale=short.resources.displayMetrics.scaledDensity
            assertEquals((32*.48*scale).toDouble(),short.autoSizeMinTextSize.toDouble(),1.0)
            assertEquals((32*scale).toDouble(),short.autoSizeMaxTextSize.toDouble(),1.0)
            val (_,text)=surface(kind="text",label="Native text",content=JSONObject().put("alignment","leading"))
            val height=text.height/text.resources.displayMetrics.density
            assertEquals((maxOf(10.0,height*.72)*scale),text.autoSizeMaxTextSize.toDouble(),1.0)
            val (_,fixed)=surface(content=JSONObject().put("fontSize",21).put("tracking",1))
            assertEquals(TextView.AUTO_SIZE_TEXT_TYPE_NONE,fixed.autoSizeTextType)
            assertEquals((21*scale).toDouble(),fixed.textSize.toDouble(),.01)
        }
    }
    @Test fun centeredIconsKeepTwoGraphemeLegendsVisible() {
        instrumentation.runOnMainSync {
            for(legend in listOf("e\u0301e\u0301","👨‍👩‍👧‍👦🇵🇷")) {
                val (_,label)=surface(label=legend,content=JSONObject().put("icon",JSONObject().put("source","text").put("value","★").put("placement","center")))
                assertEquals("native String.count treats combined glyphs as characters",legend,label.text.toString())
            }
        }
    }
    @Test fun largeFontScaleUsesPlatformConversionWithoutChangingControlGeometry() {
        instrumentation.runOnMainSync {
            val base=instrumentation.targetContext
            val changed=android.content.res.Configuration(base.resources.configuration).apply { fontScale=1.6f }
            val context=base.createConfigurationContext(changed)
            val (_,ordinary)=surface(label="AB",content=JSONObject().put("tracking",2))
            val (_,large)=surface(label="AB",content=JSONObject().put("tracking",2),context=context)
            val expected=TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP,32f,context.resources.displayMetrics)
            assertEquals(expected.toDouble(),large.autoSizeMaxTextSize.toDouble(),1.0)
            assertEquals(ordinary.width,large.width);assertEquals(ordinary.height,large.height)
            val (_,fixed)=surface(content=JSONObject().put("fontSize",21),context=context)
            assertEquals(TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP,21f,context.resources.displayMetrics).toDouble(),fixed.textSize.toDouble(),.01)
        }
    }

    @Test fun captureTypographyAndPreserveAnEngagedControlAcrossStateStyles() {
        instrumentation.runOnMainSync {
            val context=instrumentation.targetContext
            val root=android.widget.LinearLayout(context).apply { orientation=android.widget.LinearLayout.VERTICAL;setBackgroundColor(android.graphics.Color.WHITE) }
            val cases=listOf(
                Triple("Native short legend","AB",JSONObject()),
                Triple("Native long label fit","Open terminal",JSONObject()),
                Triple("Authored absolute tracking","TRACK",JSONObject().put("fontSize",24).put("tracking",2)),
                Triple("Serif, two lines","Line one\nLine two",JSONObject().put("fontSize",18).put("fontDesign","serif").put("lineLimit",2)),
                Triple("Monospaced","A: 1234",JSONObject().put("fontSize",18).put("fontDesign","monospaced")),
                Triple("Combined characters","e\u0301e\u0301",JSONObject().put("tracking",1))
            )
            cases.forEach { (title,legend,content) ->
                root.addView(TextView(context).apply { text=title;setTextColor(android.graphics.Color.BLACK);textSize=14f },android.widget.LinearLayout.LayoutParams(800,60))
                val element=JSONObject().put("id",UUID.randomUUID().toString()).put("kind","button").put("label",legend)
                    .put("layout",JSONObject().put("widthScale",3).put("heightScale",1.4)
                        .put("visualStyle",JSONObject().put("normal",JSONObject().put("content",content))))
                val profile=ControllerProfile.parse(JSONObject().put("id",UUID.randomUUID().toString()).put("customization",JSONObject().put("elements",JSONArray().put(element))))
                val surface=ControllerSurface(context);surface.show(profile,1,false,false)
                root.addView(surface,android.widget.LinearLayout.LayoutParams(800,230))
            }
            root.measure(View.MeasureSpec.makeMeasureSpec(800,View.MeasureSpec.EXACTLY),View.MeasureSpec.makeMeasureSpec(1740,View.MeasureSpec.EXACTLY));root.layout(0,0,800,1740)
            val bitmap=android.graphics.Bitmap.createBitmap(800,1740,android.graphics.Bitmap.Config.ARGB_8888)
            root.draw(android.graphics.Canvas(bitmap))
            java.io.File(context.getExternalFilesDir(null),"typography-matrix.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it) };bitmap.recycle()

            val (surface,label)=surface(label="Held",content=JSONObject().put("tracking",2))
            val edges=mutableListOf<Pair<Boolean,Long>>();surface.onEdge={ _,down,id -> edges.add(down to id) }
            val x=(label.left+label.right)/2f;val y=(label.top+label.bottom)/2f
            for(action in listOf(android.view.MotionEvent.ACTION_DOWN,android.view.MotionEvent.ACTION_UP)) {
                val event=android.view.MotionEvent.obtain(0,android.os.SystemClock.uptimeMillis(),action,x,y,0)
                assertTrue(surface.dispatchTouchEvent(event));event.recycle()
                surface.measure(View.MeasureSpec.makeMeasureSpec(800,View.MeasureSpec.EXACTLY),View.MeasureSpec.makeMeasureSpec(800,View.MeasureSpec.EXACTLY));surface.layout(0,0,800,800)
                val paint=TextPaint(label.paint)
                val extra=Layout.getDesiredWidth(label.text,paint)-Layout.getDesiredWidth(label.text.toString(),paint)
                if(action==android.view.MotionEvent.ACTION_DOWN) {
                    assertEquals("zero tracking removes the normal state's spacing",0.0,extra.toDouble(),.01)
                    assertEquals(TextView.AUTO_SIZE_TEXT_TYPE_NONE,label.autoSizeTextType)
                } else assertTrue("normal tracking is restored after release",extra>label.resources.displayMetrics.density)
            }
            assertEquals(2,edges.size);assertTrue(edges.first().first);assertFalse(edges.last().first);assertEquals(edges.first().second,edges.last().second)
        }
    }

}
