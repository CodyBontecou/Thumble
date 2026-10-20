package com.thumble.android

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class LayoutEditJournalTest {
    private val id = UUID.fromString("00000000-0000-0000-0000-000000000301")
    private val control = "00000000-0000-0000-0000-000000000302"
    private fun layout(label: String = "Original", orientation: LayoutOrientation = LayoutOrientation.LANDSCAPE) = JSONObject()
        .put("deviceCanvas", JSONObject().put("frameID", "iphone-17-pro-${orientation.wireValue}"))
        .put("colorSchemePreference", "system").put("elements", JSONArray().put(JSONObject()
            .put("id", control).put("kind", "button").put("label", label).put("layout", JSONObject().put("centerX", 0.5))))
    private fun profile() = ControllerProfile.parse(JSONObject().put("id", id.toString()).put("name", "Work")
        .put("customization", layout()).put("futureProfile", "keep").put("updatedAt", 10))
    private fun edit(label: String = "Offline", orientation: LayoutOrientation = LayoutOrientation.LANDSCAPE,
        now: Long = 42, server: String? = "mac") = PendingLayoutEdit.create(id, orientation, layout(label, orientation), now, server)
    private fun snapshot(profile: ControllerProfile = profile()) = ProfileSnapshot(listOf(profile), id, id)

    @Test fun oneGestureIsOneUndoAndCancelRestoresEntry() {
        val entry = LayoutSnapshot.capture(layout())
        val session = LayoutEditSession(entry)
        session.preview(LayoutSnapshot.capture(layout("Intermediate")))
        assertFalse(session.canUndo); assertFalse(session.hasChanges)
        assertTrue(session.commit(LayoutSnapshot.capture(layout("Moved"))))
        assertFalse(session.commit(LayoutSnapshot.capture(layout("Moved").put("updatedAt", 999))))
        assertTrue(session.commit(LayoutSnapshot.capture(layout("Resized"))))
        assertTrue(session.undo()!!.samePresentation(LayoutSnapshot.capture(layout("Moved"))))
        assertTrue(session.canUndo)
        assertTrue(session.cancel().samePresentation(entry))
        assertFalse(session.hasChanges); assertFalse(session.canUndo); assertNull(session.undo())
    }
    @Test fun snapshotsAndUndoEntriesDoNotAliasMutableJSON() {
        val raw = layout()
        val saved = LayoutSnapshot.capture(raw)
        raw.getJSONArray("elements").getJSONObject(0).put("label", "Mutated source")
        saved.json().getJSONArray("elements").getJSONObject(0).put("label", "Mutated result")
        assertEquals("Original", saved.json().getJSONArray("elements").getJSONObject(0).getString("label"))
    }
    @Test fun presentationIgnoresOnlyRootTimestampAndDictionaryOrder() {
        val other = "00000000-0000-0000-0000-000000000303"
        val a = layout().put("updatedAt", 10).put("labelOverrides", JSONArray().put(control).put("A").put(other).put("B"))
        val b = layout().put("updatedAt", 20).put("labelOverrides", JSONObject().put(other, "B").put(control, "A"))
        assertTrue(LayoutSnapshot.capture(a).samePresentation(LayoutSnapshot.capture(b)))
        b.getJSONArray("elements").getJSONObject(0).put("futureInput", "changed")
        assertFalse(LayoutSnapshot.capture(a).samePresentation(LayoutSnapshot.capture(b)))
    }
    @Test fun appliesOrientationWhileKeepingPreviousLayoutAndMacMetadata() {
        val original = profile()
        val portrait = edit("Portrait move", LayoutOrientation.PORTRAIT)
        val result = LayoutEditJournal.applying(original, portrait).source
        assertEquals("Work", result.getString("name")); assertEquals("keep", result.getString("futureProfile"))
        assertEquals(42, result.getLong("updatedAt"))
        assertTrue(LayoutSnapshot.capture(result.getJSONObject("landscapeCustomization")).samePresentation(LayoutSnapshot.capture(layout())))
        assertTrue(LayoutSnapshot.capture(result.getJSONObject("portraitCustomization")).samePresentation(portrait.customization))
        assertEquals(LayoutOrientation.PORTRAIT, LayoutOrientation.of(result.getJSONObject("customization")))
        assertFalse(original.source.has("portraitCustomization")); assertFalse(original.source.has("landscapeCustomization"))
    }
    @Test fun explicitPreviousVariantIsNeverOverwrittenByPrimaryFallback() {
        val original = ControllerProfile.parse(profile().source.put("landscapeCustomization", layout("Saved landscape")))
        val result = LayoutEditJournal.applying(original, edit(orientation = LayoutOrientation.PORTRAIT))
        assertEquals("Saved landscape", result.layout(true).getJSONArray("elements").getJSONObject(0).getString("label"))
    }
    @Test fun newEditsCorrectCanvasOrientationBeforeSaving() {
        val value = PendingLayoutEdit.create(id, LayoutOrientation.PORTRAIT, layout(), 42, " mac ")
        assertEquals(LayoutOrientation.PORTRAIT, value.customization.orientation)
        assertEquals("mac", value.serverID)
    }
    @Test fun lastTimestampWinsPerMacProfileAndOrientation() {
        val landscape = edit(now = 2)
        val portrait = edit(orientation = LayoutOrientation.PORTRAIT, now = 3)
        val otherMac = edit(now = 4, server = "other")
        val values = listOf(landscape, portrait, otherMac)
        assertEquals(values, LayoutEditJournal.recording(values, edit("Old", now = 1)))
        assertEquals(listOf(portrait, otherMac, edit("New", now = 5)), LayoutEditJournal.recording(values, edit("New", now = 5)))
        assertEquals(values, LayoutEditJournal.decode(JSONArray(LayoutEditJournal.encode(values).toString())))
    }
    @Test fun pendingLayoutWinsUntilAuthoritativeEchoWithoutLosingProfileMetadata() {
        val pending = edit()
        val renamed = ControllerProfile.parse(profile().source.put("name", "Renamed on Mac"))
        val merged = LayoutEditJournal.reconcile(snapshot(renamed), listOf(pending), "mac", true)
        assertEquals("Renamed on Mac", merged.snapshot.selected!!.name)
        assertEquals(listOf(pending), merged.remaining); assertEquals(listOf(pending), merged.uploads)
        assertTrue(LayoutSnapshot.resolved(merged.snapshot.selected!!, pending.orientation).samePresentation(pending.customization))
        assertEquals(listOf(pending), LayoutEditJournal.reconcile(merged.snapshot, merged.remaining, "mac", false).remaining)
        assertTrue(LayoutEditJournal.reconcile(merged.snapshot, merged.remaining, "mac", true).remaining.isEmpty())
    }
    @Test fun untrustedAndOtherMacEditsCannotAffectIncomingAuthority() {
        for (server in listOf(null, "other")) {
            val pending = edit(server = server)
            val result = LayoutEditJournal.reconcile(snapshot(), listOf(pending), "mac", true)
            assertEquals(listOf(pending), result.remaining); assertTrue(result.uploads.isEmpty())
            assertTrue(LayoutSnapshot.resolved(result.snapshot.selected!!, LayoutOrientation.LANDSCAPE).samePresentation(LayoutSnapshot.capture(layout())))
        }
    }
    @Test fun twoDeletedOrientationsRecoverAsOneExplicitProfile() {
        val a = edit("Landscape", now = 10)
        val b = edit("Portrait", LayoutOrientation.PORTRAIT, now = 20)
        val result = LayoutEditJournal.reconcile(ProfileSnapshot(), listOf(a, b), "mac", true)
        assertEquals(listOf(id), result.recoveredProfileIDs); assertEquals(1, result.snapshot.profiles.size)
        assertEquals("Recovered Android Layout", result.snapshot.profiles.single().name)
        assertNull(result.snapshot.selectedID); assertNull(result.snapshot.defaultID)
        assertEquals(listOf(a, b), result.remaining)
        for (value in listOf(a, b)) assertTrue(LayoutSnapshot.resolved(result.snapshot.profiles.single(), value.orientation).samePresentation(value.customization))
    }
    @Test fun scalarAcknowledgementCannotClearAnotherOrientation() {
        val a = edit()
        val b = edit("Portrait", LayoutOrientation.PORTRAIT)
        val optimistic = LayoutEditJournal.applying(LayoutEditJournal.applying(profile(), a), b)
        val result = LayoutEditJournal.reconcile(snapshot(optimistic), listOf(a, b), "mac", true, setOf(a.key))
        assertEquals(listOf(b), result.remaining)
    }
    @Test fun malformedOrDuplicateRecordsNeverLoadAsEmptySuccess() {
        val raw = edit().json()
        for (stamp in listOf(-1, 1.5)) {
            val bad = JSONObject(raw.toString()).put("updatedAt", stamp)
            assertThrows(IllegalArgumentException::class.java) { LayoutEditJournal.decode(JSONArray().put(bad)) }
        }
        for ((field, value) in listOf("orientation" to "diagonal", "profileID" to "1-1-1-1-1", "serverID" to " mac ")) {
            val bad = JSONObject(raw.toString()).put(field, value)
            assertThrows(IllegalArgumentException::class.java) { LayoutEditJournal.decode(JSONArray().put(bad)) }
        }
        assertThrows(IllegalArgumentException::class.java) { LayoutEditJournal.decode(JSONArray().put(raw).put(raw)) }
        val duplicateMap = layout().put("labelOverrides", JSONArray().put(control).put("A").put(control).put("B"))
        assertThrows(IllegalArgumentException::class.java) { LayoutSnapshot.capture(duplicateMap) }
    }
    @Test fun everyExistingSavePreservesTheLayoutJournalAndForgetClearsIt() {
        val store = MemorySessionStore()
        val pending = edit()
        store.saveEditingState(snapshot(), emptyList(), emptyList(), listOf(pending))
        store.saveSnapshot(snapshot()); assertEquals(listOf(pending), store.loadPendingLayoutEdits())
        store.saveSkinState(snapshot(), emptyList()); assertEquals(listOf(pending), store.loadPendingLayoutEdits())
        store.saveProfileState(snapshot(), emptyList(), emptyList()); assertEquals(listOf(pending), store.loadPendingLayoutEdits())
        store.forgetMac(); assertTrue(store.loadPendingLayoutEdits().isEmpty())
    }
    @Test fun allNativeTemplateSnapshotsCanEnterTheEditSessionWithoutChangingTheirPresentation() {
        val manifest = JSONObject(javaClass.classLoader!!.getResource("controller-templates/v1/manifest.json")!!.readText())
        val templates = manifest.getJSONArray("fixtures")
        repeat(templates.length()) { index ->
            val name = templates.getJSONObject(index).getString("file")
            val source = JSONObject(javaClass.classLoader!!.getResource("controller-templates/v1/$name")!!.readText()).getJSONObject("profile")
            val original = LayoutSnapshot.capture(source.getJSONObject("customization"))
            val session = LayoutEditSession(original)
            assertFalse(name, session.commit(original.stamped(99)))
            assertTrue(name, session.cancel().samePresentation(original))
        }
    }
    @Test fun earlierOrientationCannotEraseALaterAcknowledgedGlobalAppearance() {
        val dark = PendingLayoutEdit.create(id, LayoutOrientation.LANDSCAPE, layout("Offline").put("colorSchemePreference", "dark"), 10, "mac")
        val light = PendingLayoutEdit.create(id, LayoutOrientation.PORTRAIT, layout("Portrait", LayoutOrientation.PORTRAIT).put("colorSchemePreference", "light"), 20, "mac")
        val remote = LayoutEditJournal.applying(profile(), light)
        val result = LayoutEditJournal.reconcile(snapshot(remote), listOf(dark, light), "mac", true)
        assertEquals(listOf(dark, light), result.remaining)
        assertEquals("light", result.snapshot.selected!!.source.getJSONObject("customization").getString("colorSchemePreference"))
    }
    @Test fun reconciliationMatchesSixNativeSwiftOracleCases() {
        val oracle = JSONObject(javaClass.classLoader!!.getResource("android-layout-edits/v1.json")!!.readText())
        assertEquals(1, oracle.getInt("schemaVersion"))
        val cases = oracle.getJSONArray("cases")
        assertEquals(6, cases.length())
        repeat(cases.length()) { index ->
            val case = cases.getJSONObject(index)
            val name = case.getString("name")
            fun profiles(key: String): List<ControllerProfile> = case.getJSONArray(key).let { array ->
                (0 until array.length()).map { ControllerProfile.parse(array.getJSONObject(it)) }
            }
            fun strings(key: String) = case.getJSONArray(key).let { array -> (0 until array.length()).map { array.getString(it) }.sorted() }
            fun keys(values: List<PendingLayoutEdit>) = values.map { "${it.serverID ?: "untrusted"}:${it.profileID.toString().uppercase()}:${it.orientation.wireValue}" }.sorted()
            val incoming = profiles("incomingProfiles")
            val result = LayoutEditJournal.reconcile(ProfileSnapshot(incoming, incoming.firstOrNull()?.id, incoming.firstOrNull()?.id),
                LayoutEditJournal.decode(case.getJSONArray("pendingEdits")), if (case.isNull("serverID")) null else case.getString("serverID"), true)
            assertEquals(name, strings("expectedRemainingKeys"), keys(result.remaining))
            assertEquals(name, strings("expectedUploadKeys"), keys(result.uploads))
            val expected = profiles("expectedProfiles")
            assertEquals(name, expected.map { it.id }, result.snapshot.profiles.map { it.id })
            for (native in expected) {
                val android = result.snapshot.profiles.single { it.id == native.id }
                assertEquals(name, native.name.replace("Recovered iPhone Layout", "Recovered Android Layout"), android.name)
                assertTrue("$name primary", LayoutSnapshot.capture(native.source.getJSONObject("customization"))
                    .samePresentation(LayoutSnapshot.capture(android.source.getJSONObject("customization"))))
                for (orientation in LayoutOrientation.entries) assertTrue("$name ${orientation.wireValue}",
                    LayoutSnapshot.resolved(native, orientation).samePresentation(LayoutSnapshot.resolved(android, orientation)))
            }
        }
    }
}
