package com.thumble.android

import android.content.Intent
import android.net.Uri
import android.graphics.Rect
import android.os.SystemClock
import android.view.MotionEvent
import android.view.InputDevice
import android.view.accessibility.AccessibilityNodeInfo
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Before
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class SkinImportIntentDeviceTest {
    private val instrumentation get()=InstrumentationRegistry.getInstrumentation()
    private val context get()=instrumentation.targetContext
    private lateinit var library: SkinLibrary
    private lateinit var original: ControllerProfile
    private lateinit var memory: MemorySessionStore
    private var previousStore: ((android.content.Context)->SessionStore)?=null
    private var previousFlags=0
    private lateinit var solar: SkinPackage
    private lateinit var foldline: SkinPackage
    private lateinit var backups: Map<SkinReference,ByteArray?>
    private fun archive(name: String)=instrumentation.context.assets.open(name).use { it.readBytes() }
    @Before fun setup() {
        val info=instrumentation.uiAutomation.serviceInfo;previousFlags=info.flags
        info.flags=info.flags or android.accessibilityservice.AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
        instrumentation.uiAutomation.serviceInfo=info
        finishActivities()
        library=SkinLibrary(File(context.filesDir,"skins"))
        solar=SkinPackageCodec.decode(archive("solar-sumi-1.0.0-edbecde5b708.pocketpad"))
        foldline=SkinPackageCodec.decode(archive("foldline-relay-1.0.0-d04c121e9b0a.pocketpad"))
        backups=listOf(solar.reference,foldline.reference).associateWith { runCatching { library.archiveFor(it) }.getOrNull() }
        backups.keys.forEach { runCatching { library.remove(it) } }
        original=ControllerProfile.parse(JSONObject(instrumentation.context.assets.open("controller-templates/v1/arcadeStick.json").bufferedReader().use { it.readText() }).getJSONObject("profile").put("orientationPreference","portrait"))
        memory=MemorySessionStore().apply { saveSnapshot(ProfileSnapshot(listOf(original),original.id,original.id)) }
        previousStore=ClientDependencies.sessionStore;ClientDependencies.sessionStore={memory}
    }
    @After fun cleanup() {
        finishActivities()
        if(::backups.isInitialized) backups.forEach { (ref,data) -> if(data!=null) library.install(data,SkinInstallPolicy.ALLOW_DOWNGRADE) else runCatching { library.remove(ref) } }
        previousStore?.let { ClientDependencies.sessionStore=it }
        val info=instrumentation.uiAutomation.serviceInfo;info.flags=previousFlags;instrumentation.uiAutomation.serviceInfo=info
    }
    private fun finishActivities() {
        instrumentation.runOnMainSync {
            Stage.values().flatMap { ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(it) }.distinct()
                .filterIsInstance<MainActivity>().forEach { it.finish() }
        }
        instrumentation.waitForIdleSync()
    }
    private fun activity(): MainActivity? {
        var value: MainActivity?=null
        instrumentation.runOnMainSync { value=ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).filterIsInstance<MainActivity>().firstOrNull() }
        return value
    }
    private fun session(): ControllerSession? {
        var value: ControllerSession?=null
        instrumentation.runOnMainSync { activityOnMain()?.let { value=ViewModelProvider(it)[ControllerSession::class.java] } }
        return value
    }
    private fun activityOnMain()=ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).filterIsInstance<MainActivity>().firstOrNull()
    private fun await(label: String,condition: ()->Boolean) {
        val end=SystemClock.elapsedRealtime()+25_000
        while(SystemClock.elapsedRealtime()<end) { if(condition()) return;SystemClock.sleep(35) }
        screenshot("failed-"+label.replace(Regex("[^a-zA-Z0-9]+"),"-").take(60));fail(label)
    }
    private fun node(label: String): AccessibilityNodeInfo? {
        fun walk(n: AccessibilityNodeInfo): AccessibilityNodeInfo? {
            if(!n.refresh()) return null
            if(n.isVisibleToUser && (n.text?.toString()==label || n.contentDescription?.toString()==label)) return n
            repeat(n.childCount) { n.getChild(it)?.let { child -> walk(child)?.let { return it } } };return null
        }
        val automation=instrumentation.uiAutomation
        val roots=listOfNotNull(automation.rootInActiveWindow)+automation.windows.filter { it.isActive || it.isFocused }.mapNotNull { it.root }
        return roots.firstNotNullOfOrNull { walk(it) }
    }
    private fun click(label: String) {
        var previous: Rect?=null;var since=0L;var tap: Rect?=null
        await("stable $label") {
            val n=node(label)
            if(n==null || !n.isEnabled) { previous=null;false } else {
                val bounds=Rect();n.getBoundsInScreen(bounds)
                if(bounds!=previous) { previous=Rect(bounds);since=SystemClock.elapsedRealtime() }
                if(!bounds.isEmpty && SystemClock.elapsedRealtime()-since>=250) { tap=Rect(bounds);true } else false
            }
        }
        val bounds=tap!!;val start=SystemClock.uptimeMillis()
        for(action in listOf(MotionEvent.ACTION_DOWN,MotionEvent.ACTION_UP)) {
            val e=MotionEvent.obtain(start,SystemClock.uptimeMillis(),action,bounds.exactCenterX(),bounds.exactCenterY(),0)
            e.source=InputDevice.SOURCE_TOUCHSCREEN;assertTrue(instrumentation.uiAutomation.injectInputEvent(e,true));e.recycle()
        }
    }
    private fun screenshot(name: String) {
        instrumentation.uiAutomation.takeScreenshot()?.let { bitmap ->
            File(context.getExternalFilesDir(null),"skin-inbound-$name.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it) };bitmap.recycle()
        }
    }
    private fun shell(command: String)=instrumentation.uiAutomation.executeShellCommand(command).use { fd -> java.io.FileInputStream(fd.fileDescriptor).use { it.readBytes().toString(Charsets.UTF_8) } }
    private fun source(fixture: String,nonce: String)=Uri.Builder().scheme("content").authority("com.thumble.android.test.skin-source").appendPath(fixture).appendQueryParameter("nonce",nonce).build()
    private fun send(fixture: String="solar",mode: String="send",nonce: String=UUID.randomUUID().toString()): Uri {
        require(fixture in setOf("solar","foldline","slow-solar","invalid") && mode in setOf("send","view","denied","clip"))
        // The sender finishes before drawing; -W can wait forever for its first frame on API 26.
        shell("am start -n com.thumble.android.test/com.thumble.android.testfixtures.SkinSenderActivity --es fixture $fixture --es mode $mode --es nonce $nonce")
        return source(fixture,nonce)
    }
    private fun opens(uri: Uri): Int = context.contentResolver.query(uri,arrayOf("openCount"),null,null,null)!!.use { assertTrue(it.moveToFirst());it.getInt(0) }
    private fun review(pkg: SkinPackage) = session()?.let { !it.skinBusy && it.reviewedSkin?.reference==pkg.reference }==true && node("Import skin")!=null
    private fun assertNoInput() {
        val state=session()!!.state
        assertFalse(state.paired);assertEquals(0L,state.webSocketFrames);assertEquals(0L,state.udpFrames)
    }
    @Test fun coldShareReviewsWithoutInstallingSurvivesRecreationAndDoesNotReplayAfterCancel() {
        val nonce=UUID.randomUUID().toString();val uri=send(nonce=nonce)
        await("cold external review") { review(solar) };assertEquals(1,opens(uri));assertSame(original,memory.loadSnapshot().selected)
        assertTrue(library.installed().none { it.reference==solar.reference });assertNoInput()
        // This fixture has different canvas artwork; its compatibility message appears
        // only after projection resolves. The passive preview hides its AX subtree.
        await("review preview rendered") { node("Some artwork does not match this keypad; compatible control materials are shown.")!=null }
        screenshot("cold-review")
        val client=System.identityHashCode(session()!!.client)
        val previousActivity=activity()!!
        instrumentation.runOnMainSync { previousActivity.recreate() }
        await("review survives recreation") { activity()?.let { it!==previousActivity && review(solar) }==true }
        assertEquals(client,System.identityHashCode(session()!!.client));assertEquals(1,opens(uri))
        click("Cancel");await("cancel clears review") { session()?.reviewedSkin==null && session()?.recoverableSkinImportURI==null }
        instrumentation.runOnMainSync { activityOnMain()!!.recreate() }
        await("recreated library") { node("Skins")!=null && session()!=null }
        assertNull(session()!!.reviewedSkin);assertEquals(1,opens(uri));assertSame(original,memory.loadSnapshot().selected)
        val owner=System.identityHashCode(activity()!!)
        send(nonce=nonce);await("explicit reshare reviews again") { review(solar) }
        assertEquals(owner,System.identityHashCode(activity()!!));assertEquals(2,opens(uri))
        click("Import");await("import for later completes") { session()?.let { !it.skinBusy && it.reviewedSkin==null && it.installedSkins.any { skin -> skin.reference==solar.reference } }==true }
        assertArrayEquals(solar.archiveBytes(),library.archiveFor(solar.reference));assertSame(original,memory.loadSnapshot().selected)
        assertTrue(memory.loadPendingSkinSelections().isEmpty());assertNoInput();screenshot("imported-for-later")
    }
    @Test fun warmViewReusesControllerAndInstallAndApplyPreservesProfileIdentityAndControls() {
        shell("am start -W -n com.thumble.android/.MainActivity -a android.intent.action.MAIN -c android.intent.category.LAUNCHER")
        await("launcher activity") { session()?.state?.snapshot?.selected!=null }
        instrumentation.runOnMainSync { activityOnMain()!!.showSavedKeypad() }
        await("saved keypad") { session()?.state?.viewingSaved==true }
        val owner=System.identityHashCode(activity()!!);val client=System.identityHashCode(session()!!.client)
        click(original.name);click("Settings");await("settings modal") { node("Keypad settings")!=null }
        val uri=send("foldline","view");await("external View review") { review(foldline) }
        assertNull("incoming review dismisses settings",node("Keypad settings"))
        assertEquals(owner,System.identityHashCode(activity()!!));assertEquals(client,System.identityHashCode(session()!!.client));assertEquals(1,opens(uri))
        click("Install & Apply")
        await("combined install and apply") { session()?.let { !it.skinBusy && it.reviewedSkin==null && it.state.snapshot.selected?.source?.optJSONObject("skinReference")?.optString("identifier")==foldline.reference.identifier }==true }
        val changed=memory.loadSnapshot().selected!!
        assertEquals(original.id,changed.id);assertEquals(original.id,memory.loadSnapshot().defaultID)
        assertEquals(original.controls(false).map { it.id },changed.controls(false).map { it.id })
        for(key in listOf("name","orientationPreference","launchTarget","keyBindings","outputBindings")) assertEquals(original.source.opt(key)?.toString(),changed.source.opt(key)?.toString())
        assertEquals(foldline.reference,memory.loadPendingSkinSelections().single().reference)
        assertArrayEquals(foldline.archiveBytes(),library.archiveFor(foldline.reference));assertNoInput();screenshot("installed-and-applied")
    }
    @Test fun newSharesCoalesceWhileLoadingAndTheRetainedControllerDoesNotReopenTheFirstUri() {
        val slow=send("slow-solar")
        await("provider read blocked") { session()?.skinBusy==true && opens(slow)==1 }
        val client=System.identityHashCode(session()!!.client)
        instrumentation.runOnMainSync { activityOnMain()!!.recreate() }
        await("loading survives recreation") { session()?.skinBusy==true && node("Skins")!=null }
        assertEquals(client,System.identityHashCode(session()!!.client));assertEquals(1,opens(slow))
        val skipped=send("foldline")
        await("first queued share delivered") { session()?.recoverableSkinImportURI==skipped.toString() }
        val latest=send("foldline","clip")
        await("newest URI retained") { session()?.recoverableSkinImportURI==latest.toString() }
        assertEquals(0,opens(skipped));assertEquals(0,opens(latest))
        context.contentResolver.query(slow,arrayOf("release"),null,null,null)!!.close()
        await("latest file reviewed after busy work") { review(foldline) }
        assertEquals(1,opens(slow));assertEquals(0,opens(skipped));assertEquals(1,opens(latest))
        assertTrue(library.installed().none { it.reference in setOf(solar.reference,foldline.reference) })
        assertSame(original,memory.loadSnapshot().selected);assertNoInput();screenshot("queued-latest-review")
        click("Cancel")
    }
    @Test fun deniedPermissionAndMalformedArchivesShowErrorsWithoutChangingProfilesOrInstalling() {
        send(mode="denied")
        await("denied URI error") { session()?.skinError?.contains("expired")==true && node("Skin library")!=null }
        assertNull(session()!!.reviewedSkin);assertSame(original,memory.loadSnapshot().selected);click("OK")
        val bad=send("invalid","view")
        await("invalid archive error") { session()?.skinError?.contains("not a supported")==true && node("Skin library")!=null }
        assertEquals(1,opens(bad));assertNull(session()!!.reviewedSkin)
        assertTrue(library.installed().none { it.reference in setOf(solar.reference,foldline.reference) })
        assertSame(original,memory.loadSnapshot().selected);assertNoInput();screenshot("invalid-file-error");click("OK")
    }
    @Test fun parserRejectsUnsafeUrisConflictingAttachmentsAndUnrelatedIntents() {
        val good=Uri.parse("content://example.provider/document/skin")
        for(mime in SkinImportIntents.mimeTypes) assertEquals(good,SkinImportIntents.uri(Intent(Intent.ACTION_VIEW).setDataAndType(good,mime)))
        assertNull(SkinImportIntents.uri(Intent(Intent.ACTION_MAIN)))
        for(value in listOf("file:///data/data/com.thumble.android/files/private","https://example.com/skin.pocketpad","content:/missing-authority"))
            assertTrue(runCatching { SkinImportIntents.uri(Intent(Intent.ACTION_VIEW).setDataAndType(Uri.parse(value),SkinImportIntents.MIME)) }.isFailure)
        val conflict=Intent(Intent.ACTION_SEND).setType(SkinImportIntents.MIME).putExtra(Intent.EXTRA_STREAM,good)
        conflict.clipData=android.content.ClipData.newRawUri("Other",Uri.parse("content://different.provider/file"))
        assertTrue(runCatching { SkinImportIntents.uri(conflict) }.isFailure)
        assertTrue(runCatching { SkinImportIntents.uri(Intent(Intent.ACTION_SEND_MULTIPLE).setType(SkinImportIntents.MIME)) }.isFailure)
        assertTrue(runCatching { SkinImportIntents.uri(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT,"https://example.com")) }.isFailure)
    }
}
