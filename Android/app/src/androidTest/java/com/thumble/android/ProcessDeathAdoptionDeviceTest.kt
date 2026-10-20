package com.thumble.android

import android.content.Intent
import android.graphics.Rect
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

/** Second instrumentation process: no objects from the killed process survive. */
@RunWith(AndroidJUnit4::class)
class ProcessDeathAdoptionDeviceTest {
    private val instrumentation get()=InstrumentationRegistry.getInstrumentation()
    private fun await(label: String, predicate: ()->Boolean) {
        val deadline=SystemClock.elapsedRealtime()+35_000
        while(SystemClock.elapsedRealtime()<deadline) { if(predicate()) return;SystemClock.sleep(30) };fail(label)
    }
    private fun node(label: String): AccessibilityNodeInfo? {
        fun walk(n: AccessibilityNodeInfo): AccessibilityNodeInfo? {
            if(!n.refresh()) return null
            if(n.isVisibleToUser && (n.text?.toString()==label || n.contentDescription?.toString()==label)) return n
            repeat(n.childCount) { n.getChild(it)?.let { walk(it)?.let { return it } } };return null
        }
        val ui=instrumentation.uiAutomation
        return (listOfNotNull(ui.rootInActiveWindow)+ui.windows.filter { it.isActive || it.isFocused }.mapNotNull { it.root }).firstNotNullOfOrNull(::walk)
    }
    private fun click(label: String) {
        var previous: Rect?=null;var since=0L;var target: Rect?=null
        await("stable $label") {
            node(label)?.takeIf { it.isEnabled }?.let { n ->
                val rect=Rect();n.getBoundsInScreen(rect)
                if(rect!=previous) { previous=Rect(rect);since=SystemClock.elapsedRealtime() }
                if(!rect.isEmpty && SystemClock.elapsedRealtime()-since>250) { target=rect;true } else false
            } ?: false
        }
        val rect=target!!;val start=SystemClock.uptimeMillis()
        for(action in listOf(MotionEvent.ACTION_DOWN,MotionEvent.ACTION_UP)) {
            val event=MotionEvent.obtain(start,SystemClock.uptimeMillis(),action,rect.exactCenterX(),rect.exactCenterY(),0)
            event.source=InputDevice.SOURCE_TOUCHSCREEN;assertTrue(instrumentation.uiAutomation.injectInputEvent(event,true));event.recycle()
        }
    }
    @Test fun relaunchReloadsInterruptedBuildAndUIRetryConfirmsExactlyOneCopy() {
        val args=InstrumentationRegistry.getArguments();val rawRunID=args.getString("processDeathRunID")
        org.junit.Assume.assumeTrue("Requires external process-death or reboot driver",rawRunID!=null)
        val runID=UUID.fromString(rawRunID).toString()
        val mode=args.getString("wifiRecoveryMode");require(mode in setOf("partial","committed"))
        val context=instrumentation.targetContext;val external=context.getExternalFilesDir(null)!!
        val prefix="death-$mode"
        val checkpoint=JSONObject(File(external,"$prefix-checkpoint.json").readText())
        val expected=checkpoint.getJSONObject("metadata")
        assertEquals(runID,checkpoint.getString("runID"))
        val reboot=args.getString("rebootRecovery")=="true"
        if(reboot) {
            // Linux may reuse a PID across boots; boot identity is the stronger
            // assertion for this path. The USB driver records both boot IDs.
            val proof=JSONObject(File(external,"$prefix-reboot.json").readText())
            assertEquals(runID,proof.getString("runID"))
            assertNotEquals(proof.getString("beforeBootID"),proof.getString("afterBootID"))
        } else assertNotEquals(checkpoint.getInt("pid"),android.os.Process.myPid())
        val directory=File(context.noBackupFilesDir,"process-adoption-$runID-pending")
        val store=PendingSharedBuildStore(directory.toPath());val beforeRecovery=store.list().single()
        assertEquals(PendingBuildState.ADOPTING,beforeRecovery.state)
        val bytes=store.load(beforeRecovery.id).rawData()
        assertEquals(expected.getString("rawSHA256"),packageHash(bytes));assertEquals(expected.getString("recordID"),beforeRecovery.id.toString())
        val sessionDirectory="process-adoption-$runID-session";val sessionStore=AndroidSessionStore(context,sessionDirectory)
        val trusted=sessionStore.loadMac()!!;assertEquals(expected.getString("intendedServerID"),trusted.serverID)
        val previousStore=ClientDependencies.sessionStore;val previousBuilds=ClientDependencies.sharedBuildSession
        ClientDependencies.sessionStore={sessionStore};ClientDependencies.sharedBuildSession={SharedBuildSession(directory.toPath())}
        var activity: MainActivity?=null
        fun owner(): ControllerSession {
            var result: ControllerSession?=null
            instrumentation.runOnMainSync { result=ViewModelProvider(activity!!)[ControllerSession::class.java] };return result!!
        }
        fun screenshot(name: String) {
            instrumentation.waitForIdleSync();SystemClock.sleep(350)
            instrumentation.uiAutomation.takeScreenshot()?.let { b ->
                File(external,"$prefix-$name.png").outputStream().use { b.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it) };b.recycle()
            }
        }
        val startup=JSONArray();val started=SystemClock.elapsedRealtime();var previousStartup=""
        fun captureStartup() {
            val current=owner();val state=current.state
            val network=context.getSystemService(android.net.ConnectivityManager::class.java)
            val capabilities=network.getNetworkCapabilities(network.activeNetwork)
            val event=JSONObject().put("paired",state.paired).put("connecting",state.connecting)
                .put("canReconnect",state.canReconnect).put("needsCode",state.needsCode)
                .put("status",state.status).put("error",state.error)
                .put("pendingStates",JSONArray(current.sharedBuilds.records.map { it.state.name }))
                .put("lifecycle",activity!!.lifecycle.currentState.name)
                .put("windowFocused",activity!!.hasWindowFocus())
                .put("wifi",capabilities?.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI)==true)
                .put("validated",capabilities?.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_VALIDATED)==true)
                .put("localNetworkPermission",context.checkSelfPermission("android.permission.ACCESS_LOCAL_NETWORK"))
            val signature=event.toString()
            if(signature!=previousStartup && startup.length()<256) {
                previousStartup=signature;event.put("elapsedMs",SystemClock.elapsedRealtime()-started);startup.put(event)
                File(external,"$prefix-startup-timeline.json").writeText(startup.toString())
            }
        }
        try {
            activity=instrumentation.startActivitySync(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
            try {
                await("trusted reconnect and interrupted pending recovery") { captureStartup();owner().let { it.state.paired && it.sharedBuilds.records.singleOrNull()?.state==PendingBuildState.FAILED } }
            } catch(failure: AssertionError) {
                val current=owner();val state=current.state
                File(external,"$prefix-startup-diagnostic.json").writeText(JSONObject()
                    .put("paired",state.paired).put("connecting",state.connecting).put("canReconnect",state.canReconnect)
                    .put("needsCode",state.needsCode).put("status",state.status).put("error",state.error)
                    .put("pendingStates",JSONArray(current.sharedBuilds.records.map { it.state.name }))
                    .put("pendingError",current.sharedBuilds.error).put("savedURLs",JSONArray(sessionStore.loadMac()?.urls.orEmpty()))
                    .put("localNetworkPermission",context.checkSelfPermission("android.permission.ACCESS_LOCAL_NETWORK")).toString())
                screenshot("startup-failed")
                throw failure
            }
            val controller=owner();val recovered=controller.sharedBuilds.records.single()
            assertEquals(beforeRecovery.copy(state=PendingBuildState.FAILED,errorCode="disconnected"),recovered)
            assertArrayEquals(bytes,PendingSharedBuildStore(directory.toPath()).load(recovered.id).rawData())
            assertNull(controller.sharedBuilds.review);assertNull(controller.state.sharedBuildPreview)
            click(controller.state.snapshot.selected!!.name);click("Shared builds")
            await("recovered build visible") { node("Adopt shared build ${recovered.profiles.first().name} on Mac")!=null }
            screenshot("retained")
            click("Adopt shared build ${recovered.profiles.first().name} on Mac");click("Add to Mac")
            await("UI retry terminal result") { controller.state.artifactAdoption?.let { it.phase==ArtifactAdoptionPhase.FAILED || it.phase==ArtifactAdoptionPhase.SUCCEEDED && controller.sharedBuilds.records.isEmpty() }==true }
            val success=controller.state.artifactAdoption!!
            assertEquals("retry error ${success.errorCode}",ArtifactAdoptionPhase.SUCCEEDED,success.phase)
            assertEquals(expected.toString(),success.metadata.json().toString())
            val before=JSONObject(File(external,"$prefix-before.json").readText())
            assertEquals(before.getInt("profileCount")+1,controller.state.snapshot.profiles.size)
            assertEquals(before.getString("defaultID"),controller.state.snapshot.defaultID.toString())
            assertEquals(1,success.destinationProfileIDs.size);assertTrue(directory.listFiles().orEmpty().isEmpty())
            File(external,"$prefix-artifact.json").writeBytes(bytes)
            File(external,"$prefix-result.json").writeText(JSONObject().put("metadata",success.metadata.json())
                .put("destinationProfileIDs",JSONArray(success.destinationProfileIDs.map { it.toString() })).put("pid",android.os.Process.myPid())
                .put("previousPID",checkpoint.getInt("pid")).put("rebootRecovery",reboot).put("diskStateBeforeRecovery",beforeRecovery.state.name)
                .put("recoveredState",recovered.state.name).put("bytesRetained",true).put("trustedCredentialsReloaded",true)
                .put("pendingRemovedAfterConfirmation",true).toString())
            screenshot("confirmed")
        } finally {
            activity?.let { main -> instrumentation.runOnMainSync { main.finish() };instrumentation.waitForIdleSync() }
            ClientDependencies.sessionStore=previousStore;ClientDependencies.sharedBuildSession=previousBuilds
            sessionStore.forgetMac();File(context.noBackupFilesDir,sessionDirectory).deleteRecursively();directory.deleteRecursively()
        }
    }
}
