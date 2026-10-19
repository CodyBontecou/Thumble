package com.thumble.android

import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID
import java.util.concurrent.atomic.AtomicReference
import java.io.File

/** Fake actuator proves native routing without vibrating a phone during automation. */
@RunWith(AndroidJUnit4::class)
class KeypadHapticsDeviceTest {
    private fun await(condition: ()->Boolean) {
        val deadline=SystemClock.elapsedRealtime()+10_000
        while (!condition() && SystemClock.elapsedRealtime()<deadline) SystemClock.sleep(20)
        assertTrue(condition())
    }
    @Test fun preferencePersistsAcrossStoreReloadAndForgettingTheMac() {
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val namespace="haptic-settings-test-${UUID.randomUUID()}"
        val store=AndroidSessionStore(context,namespace)
        try {
            store.savePreferences(ClientPreferences(practiceMode=true,hapticIntensity=.25))
            val reloaded=AndroidSessionStore(context,namespace)
            assertEquals(ClientPreferences(true,.25),reloaded.loadPreferences())
            reloaded.forgetMac()
            assertEquals(ClientPreferences(true,.25),AndroidSessionStore(context,namespace).loadPreferences())
        } finally { store.forgetMac();File(context.noBackupFilesDir,namespace).deleteRecursively() }
    }
    @Test fun clientLoadsPersistsAndReportsFailedPreferenceWritesWithoutChangingTheSavedValue() {
        val memory=MemorySessionStore().apply { savePreferences(ClientPreferences(hapticIntensity=.25)) }
        var fail=false
        val store=object: SessionStore by memory {
            override fun savePreferences(preferences: ClientPreferences) {
                if (fail) throw java.io.IOException("fixture disk failure")
                memory.savePreferences(preferences)
            }
        }
        val state=AtomicReference(ClientState())
        val client=ControllerClient(store) { state.set(it) }
        try {
            await { state.get().hapticIntensity == .25 }
            client.setHapticIntensity(.5)
            await { state.get().hapticIntensity == .5 }
            assertEquals(.5,memory.loadPreferences().hapticIntensity,0.0)
            fail=true;client.setHapticIntensity(.75)
            await { state.get().preferencesError != null }
            assertEquals(.5,state.get().hapticIntensity,0.0);assertEquals(.5,memory.loadPreferences().hapticIntensity,0.0)
            fail=false;client.setHapticIntensity(0.0)
            await { state.get().hapticIntensity == 0.0 && state.get().preferencesError == null }
            client.forgetMac()
            await { state.get().status == "Mac forgotten" }
            assertEquals(0.0,state.get().hapticIntensity,0.0)
        } finally { client.dispose() }
    }
    private class Output: KeypadHapticOutput {
        val events=mutableListOf<String>()
        val feedback=mutableListOf<KeypadHaptic>()
        override fun play(feedback: KeypadHaptic,intensity: Double) { events.add("haptic");this.feedback.add(feedback) }
        override fun cancel() { events.add("cancel") }
    }
    private fun profile(): ControllerProfile {
        val elements=JSONArray()
        for ((index,kind) in listOf("button","trackpad").withIndex()) elements.put(JSONObject()
            .put("id",UUID.randomUUID().toString()).put("label",kind).put("kind",kind)
            .put("layout",JSONObject().put("centerX",.25+index*.5).put("centerY",.5)
                .put("visualStyle",JSONObject().put("hapticFeedback",JSONObject().put("style","heavy").put("pattern","double")))))
        return ControllerProfile.parse(JSONObject().put("id",UUID.randomUUID().toString()).put("customization",JSONObject().put("elements",elements)))
    }
    private fun surface(output: Output): ControllerSurface = ControllerSurface(InstrumentationRegistry.getInstrumentation().targetContext,hapticOutput=output).apply {
        show(profile(),1,false,false)
        measure(View.MeasureSpec.makeMeasureSpec(900,View.MeasureSpec.EXACTLY),View.MeasureSpec.makeMeasureSpec(600,View.MeasureSpec.EXACTLY));layout(0,0,900,600)
        onEdge={ _,down,_ -> output.events.add(if (down) "down" else "up") }
        onPointer={ _,_,_,_,down -> output.events.add(if (down == true) "down" else "up") }
    }
    private fun touch(surface: ControllerSurface,index: Int,action: Int) {
        val child=surface.getChildAt(index)
        val event=MotionEvent.obtain(0,SystemClock.uptimeMillis(),action,child.left+child.width/2f,child.top+child.height/2f,0)
        surface.dispatchTouchEvent(event);event.recycle()
    }
    @Test fun buttonAndTrackpadFeedbackFollowTheirAuthoritativeInputCallbacks() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val output=Output();val surface=surface(output)
            touch(surface,0,MotionEvent.ACTION_DOWN);touch(surface,0,MotionEvent.ACTION_UP)
            assertEquals(listOf("down","haptic","up"),output.events)
            output.events.clear()
            touch(surface,1,MotionEvent.ACTION_DOWN);touch(surface,1,MotionEvent.ACTION_UP)
            assertEquals(listOf("down","up","haptic"),output.events)
            output.events.clear()
            assertTrue(surface.getChildAt(0).performClick())
            assertEquals(listOf("down","up","haptic"),output.events)
            output.events.clear()
            assertTrue(surface.getChildAt(1).performAccessibilityAction(R.id.control_right_click,null))
            assertEquals(listOf("down","up","haptic"),output.events)
            assertTrue(output.feedback.all { it.style == "heavy" && it.pattern == "double" })
        }
    }
    @Test fun zeroIntensityFocusLossAndSurfaceReplacementRetireFeedbackWithoutDroppingInputRelease() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val output=Output();val surface=surface(output)
            touch(surface,0,MotionEvent.ACTION_DOWN)
            surface.onWindowFocusChanged(false)
            assertEquals(listOf("down","haptic","up","cancel"),output.events)
            output.events.clear()
            surface.hapticIntensity=0.0
            touch(surface,0,MotionEvent.ACTION_DOWN);touch(surface,0,MotionEvent.ACTION_UP)
            assertEquals(listOf("cancel","down","up"),output.events)
            surface.hapticIntensity=1.0;output.events.clear()
            touch(surface,0,MotionEvent.ACTION_DOWN)
            surface.show(profile(),2,false,false)
            assertEquals(listOf("down","haptic","up","cancel"),output.events)
        }
    }
}
