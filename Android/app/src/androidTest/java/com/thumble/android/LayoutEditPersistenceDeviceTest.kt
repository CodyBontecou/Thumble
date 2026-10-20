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

@RunWith(AndroidJUnit4::class)
class LayoutEditPersistenceDeviceTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private fun profile() = ControllerProfile.parse(JSONObject(instrumentation.context.assets
        .open("controller-templates/v1/productivityStarter.json").bufferedReader().use { it.readText() }).getJSONObject("profile"))
    private fun withStore(body: (AndroidSessionStore, File, ControllerProfile) -> Unit) {
        val context = instrumentation.targetContext
        val namespace = "layout-journal-${UUID.randomUUID()}"
        val store = AndroidSessionStore(context, namespace)
        val directory = File(context.noBackupFilesDir, namespace)
        try { body(store, directory, profile()) }
        finally {
            directory.setWritable(true, true)
            File(directory, "profiles.json").setWritable(true, true)
            store.forgetMac(); directory.deleteRecursively()
        }
    }
    private fun snapshot(profile: ControllerProfile) = ProfileSnapshot(listOf(profile), profile.id, profile.id)
    private fun edits(profile: ControllerProfile) = LayoutOrientation.entries.mapIndexed { index, orientation ->
        PendingLayoutEdit.create(profile.id, orientation, profile.source.getJSONObject("customization"), 10L + index, "mac")
    }
    @Test fun realAtomicStoreRetainsAllJournalsAcrossReloadAndOlderSaveMethods() = withStore { store, directory, profile ->
        val pending = edits(profile)
        val appearance = listOf(PendingAppearancePreference.create(profile, AppearancePreference.DARK, 20, "mac"))
        val skins = listOf(PendingSkinSelection(profile.id, null, 21, "mac"))
        store.saveEditingState(snapshot(profile), skins, appearance, pending)
        val reloaded = AndroidSessionStore(instrumentation.targetContext, directory.name)
        assertEquals(pending, reloaded.loadPendingLayoutEdits())
        reloaded.saveSnapshot(snapshot(profile))
        reloaded.saveSkinState(snapshot(profile), skins)
        reloaded.saveProfileState(snapshot(profile), skins, appearance)
        assertEquals(pending, reloaded.loadPendingLayoutEdits())
        assertEquals(appearance, reloaded.loadPendingAppearancePreferences())
        assertEquals(skins, reloaded.loadPendingSkinSelections())
        reloaded.forgetMac()
        assertTrue(reloaded.loadPendingLayoutEdits().isEmpty())
        assertTrue(reloaded.loadPendingAppearancePreferences().isEmpty())
        assertTrue(reloaded.loadPendingSkinSelections().isEmpty())
    }
    @Test fun realWriteFailurePreservesThePreviousSnapshotAndJournal() = withStore { store, directory, profile ->
        val pending = edits(profile)
        store.saveEditingState(snapshot(profile), emptyList(), emptyList(), pending)
        val file = File(directory, "profiles.json")
        val before = file.readBytes()
        assertTrue(file.setWritable(false, false)); assertTrue(directory.setWritable(false, false))
        try {
            val changed = ControllerProfile.parse(JSONObject(profile.source.toString()).put("name", "Must not persist"))
            assertThrows(Exception::class.java) { store.saveEditingState(snapshot(changed), emptyList(), emptyList(), emptyList()) }
        } finally { directory.setWritable(true, true); file.setWritable(true, true) }
        assertArrayEquals(before, file.readBytes())
        assertEquals(profile.name, store.loadSnapshot().selected!!.name)
        assertEquals(pending, store.loadPendingLayoutEdits())
    }
    @Test fun malformedAndDuplicateJSONJournalsBlockSavesWithoutDestroyingBytes() = withStore { store, directory, profile ->
        val pending = edits(profile)
        store.saveEditingState(snapshot(profile), emptyList(), emptyList(), pending)
        val file = File(directory, "profiles.json")
        val original = file.readText()
        val malformed = JSONObject(original).put("androidPendingLayoutEdits", JSONArray().put(pending.first().json().put("updatedAt", 1.5))).toString()
        val duplicate = original.dropLast(1) + ",\"androidPendingLayoutEdits\":[]}"
        for (bad in listOf(malformed, duplicate)) {
            file.writeText(bad)
            val bytes = file.readBytes()
            assertThrows(Exception::class.java) { store.loadPendingLayoutEdits() }
            assertThrows(Exception::class.java) { store.saveSnapshot(snapshot(profile)) }
            assertArrayEquals(bytes, file.readBytes())
        }
    }
}
