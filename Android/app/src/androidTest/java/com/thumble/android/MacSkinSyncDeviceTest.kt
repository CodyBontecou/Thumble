package com.thumble.android

import android.graphics.Bitmap
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import android.view.View
import android.view.ViewGroup
import android.view.MotionEvent
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/** Actual receiver acceptance; no mock socket. Pairing data never enters receipts. */
@RunWith(AndroidJUnit4::class)
class MacSkinSyncDeviceTest {
    @Test fun physicalPhoneSynchronizesNativeMacLibraryAndAuthoritativeSelections() {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val qr=InstrumentationRegistry.getArguments().getString("macSkinPairingQR")
        assumeTrue("Requires private real Mac receiver",qr!=null)
        val context=instrumentation.targetContext
        val library=SkinLibrary(File(context.filesDir,"skins"))
        val initial=instrumentation.context.assets.open("solar-sumi-1.0.0-edbecde5b708.pocketpad").use { it.readBytes() }
        val upload=instrumentation.context.assets.open("foldline-relay-1.0.0-d04c121e9b0a.pocketpad").use { it.readBytes() }
        val first=SkinPackageCodec.decode(initial);val second=SkinPackageCodec.decode(upload)
        val backups=listOf(first.reference,second.reference).associateWith { runCatching { library.archiveFor(it) }.getOrNull() }
        val output=File(context.getExternalFilesDir(null),"mac-skin-sync").apply { mkdirs() }
        val previous=ClientDependencies.sessionStore
        val store=MemorySessionStore();ClientDependencies.sessionStore={store}
        val automation=instrumentation.uiAutomation
        val originalFlags=automation.serviceInfo.flags
        automation.serviceInfo=automation.serviceInfo.apply { flags=flags or android.accessibilityservice.AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS }
        fun await(label:String,test:()->Boolean) {
            val end=SystemClock.elapsedRealtime()+30_000
            while(!test() && SystemClock.elapsedRealtime()<end) SystemClock.sleep(25)
            assertTrue(label,test())
        }
        fun node(text:String):AccessibilityNodeInfo? {
            fun find(n:AccessibilityNodeInfo):AccessibilityNodeInfo? {
                if(n.text?.toString()==text || n.contentDescription?.toString()==text) return n
                repeat(n.childCount) { n.getChild(it)?.let { c -> find(c)?.let { return it } } };return null
            }
            automation.rootInActiveWindow?.let(::find)?.let { return it }
            return automation.windows.asSequence().filter { it.isFocused || it.isActive }.mapNotNull { it.root?.let(::find) }.firstOrNull()
        }
        fun click(text:String) {
            await("Enabled action $text") {
                var value=node(text) ?: return@await false
                while(!value.isClickable && value.parent!=null)value=value.parent
                value.isEnabled
            }
            var n=node(text)!!;while(!n.isClickable && n.parent!=null)n=n.parent
            assertTrue("Enabled $text",n.isEnabled);assertTrue(n.performAction(AccessibilityNodeInfo.ACTION_CLICK))
        }
        fun phase(value:String) { File(output,"phase-history.txt").appendText(value+"\n");File(output,"phase.txt").writeText(value) }
        fun capture(value:String) {
            if(value!="import-review") await("Rendered keypad for $value") {
                node("Return")!=null && node("Loading keypad appearance…")==null && node("Preparing skin…")==null
            }
            instrumentation.waitForIdleSync()
            val bitmap=automation.takeScreenshot()!!
            File(output,"$value.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG,100,it) };bitmap.recycle()
        }
        try {
            backups.keys.forEach { if(backups[it]!=null)library.remove(it) }
            ActivityScenario.launch(MainActivity::class.java).use { scenario ->
                var session:ControllerSession?=null
                scenario.onActivity { session=ViewModelProvider(it)[ControllerSession::class.java];session!!.client.connect(PairingTarget.parse(qr!!)) }
                fun state()=session!!.state
                fun reference()=state().snapshot.selected?.source?.optJSONObject("skinReference")?.let { SkinReference.parse(it) }
                await("Authenticated skin snapshot") { state().paired && reference()==first.reference && session!!.skinSyncInFlight==0 && runCatching { library.archiveFor(first.reference).contentEquals(initial) }.getOrDefault(false) }
                assertTrue("Skin packages capability", "skin_packages" in state().capabilities)
                assertTrue("Skin selection capability", "gamepad_profile_skin_selection" in state().capabilities)
                val profileID=state().snapshot.selectedID
                val profileName=state().snapshot.selected!!.name
                await("Native controller displayed") { node(profileName)!=null && node("Loading keypad appearance…")==null }
                capture("initial-from-mac")
                click(profileName);click("Detach skin")
                await("Mac acknowledged detach") { state().paired && reference()==null && state().pendingSkinChanges==0 }
                capture("phone-detached");phase("detached")
                scenario.onActivity { session!!.prepareSkinImport { upload.inputStream() } }
                await("Import review") { node("Import skin")!=null }
                capture("import-review");click("Import")
                await("Phone archive installed") { runCatching { library.archiveFor(second.reference).contentEquals(upload) }.getOrDefault(false) && node("Import skin")==null }
                click(profileName);click("Apply ${second.name} · ${second.reference.version}")
                await("Mac acknowledged uploaded skin selection") { state().paired && reference()==second.reference && state().pendingSkinChanges==0 && !session!!.skinBusy }
                capture("phone-applied")
                fun surface(view:View):ControllerSurface? {
                    if(view is ControllerSurface)return view
                    if(view is ViewGroup)repeat(view.childCount) { surface(view.getChildAt(it))?.let { return it } }
                    return null
                }
                var held:View?=null
                await("Rendered return control ready") {
                    var ready=false;scenario.onActivity { a ->
                        val keypad=surface(a.window.decorView)
                        ready=keypad!=null && keypad.isEnabled && (0 until keypad.childCount).any { keypad.getChildAt(it).contentDescription?.toString()=="Return" }
                    };ready
                }
                scenario.onActivity { a ->
                    val keypad=surface(a.window.decorView)!!
                    held=(0 until keypad.childCount).map { keypad.getChildAt(it) }.first { it.contentDescription?.toString()=="Return" }
                    val down=MotionEvent.obtain(0,SystemClock.uptimeMillis(),MotionEvent.ACTION_DOWN,held!!.left+held!!.width/2f,held!!.top+held!!.height/2f,0)
                    keypad.dispatchTouchEvent(down);down.recycle();assertTrue(held!!.isPressed)
                }
                phase("applied")
                await("CLI change arrived on the physical phone") { state().paired && reference()==first.reference && session!!.skinSyncInFlight==0 }
                await("CLI replacement releases the held physical capture") { !held!!.isPressed }
                capture("cli-applied");phase("cli-applied")
                session!!.client.disconnect();await("Disconnected") { !state().paired }
                phase("disconnected")
                // Host harness restarts the actual receiver after this phase.
                await("Restart signal") { File(output,"continue.txt").exists() }
                session!!.client.reconnect()
                await("Trusted reconnect and package replay") { state().paired && reference()==first.reference && state().pendingSkinChanges==0 && session!!.skinSyncInFlight==0 }
                assertEquals(profileID,state().snapshot.selectedID)
                assertArrayEquals(initial,library.archiveFor(first.reference));assertArrayEquals(upload,library.archiveFor(second.reference))
                capture("reconnected")
                File(output,"result.json").writeText(JSONObject().put("physicalDevice",!android.os.Build.FINGERPRINT.contains("generic"))
                    .put("model",android.os.Build.MODEL).put("sdk",android.os.Build.VERSION.SDK_INT)
                    .put("initialArchiveSHA256",packageHash(initial)).put("uploadedArchiveSHA256",packageHash(upload))
                    .put("macToPhonePackageReplay",true).put("phoneImportApplyDetachAcknowledged",true)
                    .put("cliChangeDelivered",true).put("cliReplacementReleasesHeldCapture",true).put("restartTrustedReconnect",true).put("pendingSkinChanges",0)
                    .put("profileIdentityPreserved",true).put("systemDocumentPickerVerified",false).toString(2))
                session!!.client.disconnect();await("Final disconnect") { !state().paired };phase("done")
            }
        } finally {
            ClientDependencies.sessionStore=previous
            backups.forEach { (ref,bytes) -> if(bytes==null)runCatching { library.remove(ref) } else library.install(bytes,SkinInstallPolicy.ALLOW_DOWNGRADE) }
            automation.serviceInfo=automation.serviceInfo.apply { flags=originalFlags }
        }
    }
}
