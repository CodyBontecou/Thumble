package com.thumble.android

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicReference

@RunWith(AndroidJUnit4::class)
class OnboardingDeviceTest {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private fun await(label: String,test: ()->Boolean) {
        val deadline=android.os.SystemClock.elapsedRealtime()+5000
        while(!test() && android.os.SystemClock.elapsedRealtime()<deadline) android.os.SystemClock.sleep(10)
        assertTrue(label,test())
    }
    @Test fun freshInstallCompletionSurvivesStoreRecreationAndForget() {
        val namespace="onboarding-test-${UUID.randomUUID()}"
        try {
            val store=AndroidSessionStore(context,namespace)
            assertFalse(store.loadOnboardingCompleted())
            store.saveOnboardingCompleted()
            assertTrue(AndroidSessionStore(context,namespace).loadOnboardingCompleted())
            store.forgetMac()
            assertTrue(AndroidSessionStore(context,namespace).loadOnboardingCompleted())
        } finally { File(context.noBackupFilesDir,namespace).deleteRecursively() }
    }
    @Test fun upgradeWithSavedProfilesMigratesOnceWithoutReplacingProfilesOrPreferences() {
        val namespace="onboarding-test-${UUID.randomUUID()}"
        try {
            val fixture=JSONObject(InstrumentationRegistry.getInstrumentation().context.assets.open("state/minimal-profile.json").bufferedReader().use { it.readText() })
            val store=AndroidSessionStore(context,namespace)
            store.saveSnapshot(ProfileSnapshot().applying(JSONObject().put("gamepadProfiles",JSONArray().put(fixture))))
            store.savePreferences(ClientPreferences(hapticIntensity=.5,showBindingGlyphs=false))
            val profiles=File(context.noBackupFilesDir,"$namespace/profiles.json").readBytes()
            assertTrue(store.loadOnboardingCompleted())
            assertArrayEquals(profiles,File(context.noBackupFilesDir,"$namespace/profiles.json").readBytes())
            assertEquals(ClientPreferences(hapticIntensity=.5,showBindingGlyphs=false),store.loadPreferences())
            store.forgetMac()
            assertTrue(AndroidSessionStore(context,namespace).loadOnboardingCompleted())
        } finally { File(context.noBackupFilesDir,namespace).deleteRecursively() }
    }
    @Test fun completionFailureRemainsRecoverableAndNeverRetiresInputGeneration() {
        var completed=false;var fail=true
        val memory=MemorySessionStore()
        val store=object: SessionStore by memory {
            override fun loadOnboardingCompleted()=completed
            override fun saveOnboardingCompleted() { if(fail) error("fixture disk full");completed=true }
        }
        val state=AtomicReference(ClientState());val client=ControllerClient(store) { state.set(it) }
        try {
            await("guide state loaded") { state.get().onboardingLoaded }
            assertFalse(state.get().onboardingCompleted)
            val revision=state.get().surfaceRevision
            client.completeOnboarding()
            await("failed save reported") { state.get().error?.contains("setup progress")==true }
            assertFalse(state.get().onboardingCompleted);assertEquals(revision,state.get().surfaceRevision)
            fail=false;client.completeOnboarding()
            await("retry completes") { state.get().onboardingCompleted }
            assertEquals(revision,state.get().surfaceRevision);assertNull(state.get().error)
            client.forgetMac()
            await("forget completes") { state.get().status=="Mac forgotten" }
            assertTrue(state.get().onboardingLoaded);assertTrue(state.get().onboardingCompleted)
        } finally { client.dispose() }
    }
    @Test fun corruptCompletionStateIsPreservedUntilExplicitCompletion() {
        val namespace="onboarding-test-${UUID.randomUUID()}"
        val file=File(context.noBackupFilesDir,"$namespace/onboarding.json")
        val store=AndroidSessionStore(context,namespace)
        file.writeText("corrupt")
        val state=AtomicReference(ClientState());val client=ControllerClient(store) { state.set(it) }
        try {
            await("load failure shown") { state.get().onboardingLoaded }
            assertFalse(state.get().onboardingCompleted)
            assertEquals("corrupt",file.readText())
            client.completeOnboarding()
            await("explicit completion replaces invalid state") { state.get().onboardingCompleted }
            assertTrue(AndroidSessionStore(context,namespace).loadOnboardingCompleted())
        } finally { client.dispose();File(context.noBackupFilesDir,namespace).deleteRecursively() }
    }
}
