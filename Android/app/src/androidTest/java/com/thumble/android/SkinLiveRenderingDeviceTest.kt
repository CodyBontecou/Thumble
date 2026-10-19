package com.thumble.android

import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import androidx.test.core.app.ActivityScenario
import androidx.lifecycle.ViewModelProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class SkinLiveRenderingDeviceTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private fun find(view: View): ControllerSurface? {
        if (view is ControllerSurface) return view
        if (view is ViewGroup) repeat(view.childCount) { find(view.getChildAt(it))?.let { found -> return found } }
        return null
    }
    private fun draw(view: View) = Bitmap.createBitmap(view.width,view.height,Bitmap.Config.ARGB_8888).also { view.draw(Canvas(it)) }
    private fun digest(bitmap: Bitmap): String {
        val pixels=IntArray(bitmap.width*bitmap.height);bitmap.getPixels(pixels,0,bitmap.width,0,0,bitmap.width,bitmap.height)
        val hash=java.security.MessageDigest.getInstance("SHA-256")
        pixels.forEach { hash.update(byteArrayOf((it shr 24).toByte(),(it shr 16).toByte(),(it shr 8).toByte(),it.toByte())) }
        return hash.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
    }
    @Test fun savedProfileLoadsInstalledSkinInRealActivityAndRetainsTouchAcrossUnchangedProjection() {
        val context=instrumentation.targetContext
        val library=SkinLibrary(File(context.filesDir,"skins"))
        val bytes=instrumentation.context.assets.open("solar-sumi-1.0.0-edbecde5b708.pocketpad").use { it.readBytes() }
        val pkg=SkinPackageCodec.decode(bytes)
        val previous=runCatching { library.archiveFor(pkg.reference) }.getOrNull()
        library.install(bytes,SkinInstallPolicy.REPLACE_SAME_VERSION)
        val oracle=instrumentation.context.assets.open("skin-resolution/v1/native-profile-oracle.json").use { JSONObject(it.bufferedReader().readText()) }
        val local=oracle.getJSONObject("profiles").getJSONObject("arcadeStick")
        val profile=ControllerProfile.parse(JSONObject().put("id",UUID.randomUUID().toString()).put("name","Installed Solar Sumi")
            .put("orientationPreference","portrait").put("customization",JSONObject(local.toString()))
            .put("skinBaselineCustomization",JSONObject(local.toString()))
            .put("skinReference",JSONObject().put("identifier",pkg.reference.identifier).put("version",pkg.reference.version)))
        val before=profile.source.toString()
        val store=MemorySessionStore().apply { saveSnapshot(ProfileSnapshot(listOf(profile),profile.id)) }
        val oldStore=ClientDependencies.sessionStore;ClientDependencies.sessionStore={store}
        try {
            val repository=SkinRenderRepository.fromDirectory(File(context.filesDir,"skins"))
            val projection=repository.resolve(profile,false,false)
            // This canonical template labels its buttons as custom; the unchanged
            // package requires more specific roles. Semantic styling remains active,
            // while template-aligned artwork must be gated exactly as on iOS.
            assertNotNull(projection.warning);assertEquals("incompatible",projection.compatibility!!.status)
            assertTrue(projection.compatibility.issues.any { it.code=="missing-role" })
            ActivityScenario.launch(MainActivity::class.java).use { scenario ->
                scenario.onActivity { it.showSavedKeypad() }
                var matched=false;var normalHash="";var rawHash=""
                val deadline=SystemClock.elapsedRealtime()+15_000
                while (!matched && SystemClock.elapsedRealtime()<deadline) {
                    scenario.onActivity { activity ->
                        val surface=find(activity.window.decorView)
                        if(surface!=null && surface.width>0 && surface.height>0 && surface.childCount>0) {
                            fun reference(p: ControllerProfile): Bitmap {
                                val v=ControllerSurface(context);v.show(p,activity.connectionState.surfaceRevision,false,false)
                                v.measure(View.MeasureSpec.makeMeasureSpec(surface.width,View.MeasureSpec.EXACTLY),View.MeasureSpec.makeMeasureSpec(surface.height,View.MeasureSpec.EXACTLY))
                                v.layout(0,0,surface.width,surface.height)
                                return draw(v)
                            }
                            val expected=reference(projection.profile!!);val raw=reference(profile);val actual=draw(surface)
                            normalHash=digest(actual);rawHash=digest(raw)
                            matched=normalHash==digest(expected) && normalHash!=rawHash
                            expected.recycle();raw.recycle();actual.recycle()
                        }
                    }
                    if(!matched) SystemClock.sleep(50)
                }
                assertTrue("Real activity must display the installed skin rather than its raw saved layout",matched)
                scenario.onActivity { activity ->
                    assertTrue(activity.connectionState.practiceMode);assertFalse(activity.connectionState.paired)
                    val surface=find(activity.window.decorView)!!
                    val i=projection.profile!!.controls(false).indexOfFirst { it.kind=="button" }
                    assertTrue(i>=0);val child=surface.getChildAt(i)
                    val x=child.left+child.width/2f;val y=child.top+child.height/2f
                    fun touch(action: Int) { val event=MotionEvent.obtain(0,SystemClock.uptimeMillis(),action,x,y,0);surface.dispatchTouchEvent(event);event.recycle() }
                    touch(MotionEvent.ACTION_DOWN);assertTrue(child.isPressed)
                    ViewModelProvider(activity)[ControllerSession::class.java].client.setHapticIntensity(.25)
                }
                var recomposed=false
                val updateDeadline=SystemClock.elapsedRealtime()+5_000
                while(!recomposed && SystemClock.elapsedRealtime()<updateDeadline) {
                    scenario.onActivity { activity -> recomposed=activity.connectionState.hapticIntensity==.25 }
                    if(!recomposed) SystemClock.sleep(20)
                }
                assertTrue(recomposed)
                instrumentation.waitForIdleSync()
                scenario.onActivity { activity ->
                    val surface=find(activity.window.decorView)!!
                    val i=projection.profile!!.controls(false).indexOfFirst { it.kind=="button" }
                    val child=surface.getChildAt(i)
                    assertTrue("An ordinary settings recomposition must preserve the held touch",child.isPressed)
                    val event=MotionEvent.obtain(0,SystemClock.uptimeMillis(),MotionEvent.ACTION_UP,child.left+child.width/2f,child.top+child.height/2f,0)
                    surface.dispatchTouchEvent(event);event.recycle();assertFalse(child.isPressed)
                    val capture=draw(surface)
                    File(context.getExternalFilesDir(null),"skin-live-portrait.png").outputStream().use { capture.compress(Bitmap.CompressFormat.PNG,100,it) };capture.recycle()
                    surface.cancelTouches()
                }
                fun awaitAppearance(expectedHash: String) {
                    var ready=false;val limit=SystemClock.elapsedRealtime()+10_000
                    while(!ready && SystemClock.elapsedRealtime()<limit) {
                        scenario.onActivity { activity ->
                            val surface=find(activity.window.decorView)
                            if(surface!=null && surface.width>0 && surface.height>0 && surface.childCount>0) {
                                val bitmap=draw(surface);ready=digest(bitmap)==expectedHash;bitmap.recycle()
                            }
                        }
                        if(!ready) SystemClock.sleep(30)
                    }
                    assertTrue("Library change must update the real activity",ready)
                }
                library.remove(pkg.reference)
                scenario.onActivity { ViewModelProvider(it)[ControllerSession::class.java].skinLibraryChanged() }
                awaitAppearance(rawHash)
                library.install(bytes)
                scenario.onActivity { ViewModelProvider(it)[ControllerSession::class.java].skinLibraryChanged() }
                awaitAppearance(normalHash)
                assertEquals(before,profile.source.toString())
                assertEquals(before,store.loadSnapshot().selected!!.source.toString())
                File(context.getExternalFilesDir(null),"skin-live-result.json").writeText(JSONObject()
                    .put("sdk",android.os.Build.VERSION.SDK_INT).put("archiveSHA256",pkg.archiveSHA256)
                    .put("activityMatchesInstalledProjection",true).put("rawAppearanceDiffers",true)
                    .put("normalPixelSHA256",normalHash).put("rawPixelSHA256",rawHash)
                    .put("unchangedProjectionRetainsHold",true).put("savedProfileUnchanged",true)
                    .put("libraryRemovalAndReinstallRefreshActivity",true).put("offlinePractice",true).put("liveMacInputTested",false).toString(2))
            }
        } finally {
            ClientDependencies.sessionStore=oldStore
            if(previous==null) library.remove(pkg.reference) else library.install(previous,SkinInstallPolicy.REPLACE_SAME_VERSION)
        }
    }
}
