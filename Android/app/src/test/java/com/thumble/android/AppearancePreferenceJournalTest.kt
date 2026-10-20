package com.thumble.android

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class AppearancePreferenceJournalTest {
    private val id = UUID.fromString("00000000-0000-0000-0000-000000000201")
    private fun profile(preference: String = "system", name: String = "Keypad") = ControllerProfile.parse(JSONObject()
        .put("id", id.toString()).put("name", name).put("futureProfile", "preserved")
        .put("updatedAt", 10).put("customization", JSONObject().put("elements", JSONArray())
            .put("colorSchemePreference", preference).put("futureLayout", "preserved")))
    private fun snapshot(profile: ControllerProfile = profile()) = ProfileSnapshot(listOf(profile), id, id)

    @Test fun choicesResolveSystemAndForcedModes() {
        assertFalse(AppearancePreference.SYSTEM.isDark(false)); assertTrue(AppearancePreference.SYSTEM.isDark(true))
        assertFalse(AppearancePreference.LIGHT.isDark(true)); assertTrue(AppearancePreference.DARK.isDark(false))
        assertEquals(AppearancePreference.SYSTEM, AppearancePreference.forProfile(profile("future-value")))
    }
    @Test fun reconnectKeepsLocalChoiceAndNewRemoteMetadataUntilAcknowledged() {
        val edit = PendingAppearancePreference.create(profile(), AppearancePreference.DARK, 100, "mac")
        val incoming = profile(name = "Renamed on Mac")
        val result = AppearancePreferenceJournal.reconcile(snapshot(incoming), listOf(edit), "mac", true)
        val source = result.snapshot.selected!!.source
        assertEquals("Renamed on Mac", source.getString("name"))
        assertEquals("preserved", source.getString("futureProfile"))
        assertEquals("preserved", source.getJSONObject("customization").getString("futureLayout"))
        assertEquals("dark", source.getJSONObject("customization").getString("colorSchemePreference"))
        assertEquals(100L, source.getLong("updatedAt"))
        assertEquals(listOf(edit), result.remaining); assertEquals(listOf(edit), result.uploads)
        assertEquals("system", incoming.source.getJSONObject("customization").getString("colorSchemePreference"))
        val acknowledged = AppearancePreferenceJournal.reconcile(result.snapshot, result.remaining, "mac", true)
        assertTrue(acknowledged.remaining.isEmpty()); assertTrue(acknowledged.uploads.isEmpty())
        assertEquals(id, acknowledged.snapshot.defaultID)
    }
    @Test fun unrelatedServerAndUntrustedChoicesCannotOverwriteOrAcknowledge() {
        for (server in listOf(null, "other-mac")) {
            val edit = PendingAppearancePreference.create(profile(), AppearancePreference.DARK, 100, server)
            val result = AppearancePreferenceJournal.reconcile(snapshot(), listOf(edit), "mac", true)
            assertEquals(AppearancePreference.SYSTEM, AppearancePreference.forProfile(result.snapshot.selected!!))
            assertEquals(listOf(edit), result.remaining); assertTrue(result.uploads.isEmpty())
        }
    }
    @Test fun optimisticSnapshotIsNotAnAcknowledgement() {
        val edit = PendingAppearancePreference.create(profile(), AppearancePreference.DARK, 100, "mac")
        val optimistic = AppearancePreferenceJournal.applying(profile(), edit)
        val result = AppearancePreferenceJournal.reconcile(snapshot(optimistic), listOf(edit), "mac", false)
        assertEquals(listOf(edit), result.remaining); assertEquals(listOf(edit), result.uploads)
    }
    @Test fun deletedProfileRecoversWithoutLosingPrivateLayoutMetadata() {
        val edit = PendingAppearancePreference.create(profile(), AppearancePreference.LIGHT, 100, "mac")
        val result = AppearancePreferenceJournal.reconcile(ProfileSnapshot(), listOf(edit), "mac", true)
        assertEquals(listOf(id), result.recoveredProfileIDs)
        val restored = result.snapshot.profiles.single()
        assertEquals("Recovered Android Layout", restored.name)
        assertEquals(AppearancePreference.LIGHT, AppearancePreference.forProfile(restored))
        assertEquals("preserved", restored.source.getString("futureProfile"))
        assertEquals(listOf(edit), result.remaining)
    }
    @Test fun serializedRecoveryIsImmutableAndRoundTrips() {
        val original = profile()
        val edit = PendingAppearancePreference.create(original, AppearancePreference.DARK, 100, " mac ")
        original.source.put("name", "Mutated afterwards")
        assertEquals("Keypad", edit.recoveredProfile().name)
        val encoded = AppearancePreferenceJournal.encode(listOf(edit))
        assertEquals(listOf(edit), AppearancePreferenceJournal.decode(JSONArray(encoded.toString())))
        assertEquals("mac", edit.serverID)
    }
    @Test fun lastChoicePerServerAndProfileWins() {
        val dark = PendingAppearancePreference.create(profile(), AppearancePreference.DARK, 100, "mac")
        val light = PendingAppearancePreference.create(profile(), AppearancePreference.LIGHT, 101, "mac")
        val other = PendingAppearancePreference.create(profile(), AppearancePreference.SYSTEM, 99, "other")
        assertEquals(listOf(other, light), AppearancePreferenceJournal.recording(listOf(dark, other), light))
    }
    @Test fun savingSkinsOrSnapshotsCannotDropPendingAppearance() {
        val store = MemorySessionStore()
        val edit = PendingAppearancePreference.create(profile(), AppearancePreference.DARK, 100, "mac")
        store.saveProfileState(snapshot(), emptyList(), listOf(edit))
        store.saveSkinState(snapshot(profile("dark")), emptyList())
        assertEquals(listOf(edit), store.loadPendingAppearancePreferences())
        store.saveSnapshot(snapshot(profile("light")))
        assertEquals(listOf(edit), store.loadPendingAppearancePreferences())
        store.forgetMac()
        assertTrue(store.loadPendingAppearancePreferences().isEmpty())
    }
    @Test fun invalidRemoteEnumCannotAcknowledgeSystemChoice() {
        val edit = PendingAppearancePreference.create(profile(), AppearancePreference.SYSTEM, 100, "mac")
        val result = AppearancePreferenceJournal.reconcile(snapshot(profile("future-value")), listOf(edit), "mac", true)
        assertEquals(listOf(edit), result.remaining)
        assertEquals("system", result.snapshot.selected!!.source.getJSONObject("customization").getString("colorSchemePreference"))
    }
    @Test fun scalarAcknowledgementCannotClearAnotherProfilesOptimisticChoice() {
        val otherID=UUID.randomUUID()
        val other=ControllerProfile.parse(JSONObject(profile("dark").source.toString()).put("id",otherID.toString()))
        val first=PendingAppearancePreference.create(profile(),AppearancePreference.DARK,100,"mac")
        val second=PendingAppearancePreference.create(other,AppearancePreference.DARK,101,"mac")
        val incoming=ProfileSnapshot(listOf(profile("dark"),other),id,id)
        val result=AppearancePreferenceJournal.reconcile(incoming,listOf(first,second),"mac",true,setOf(id))
        assertEquals(listOf(second),result.remaining)
    }
    @Test fun invalidJournalNeverBecomesAnEmptySuccessfulLoad() {
        val edit = PendingAppearancePreference.create(profile(), AppearancePreference.DARK, 100, "mac")
        val valid = edit.json()
        val mutations = listOf(valid.toString().replace("\"updatedAt\":100", "\"updatedAt\":-1"),
            valid.toString().replace("\"updatedAt\":100", "\"updatedAt\":1.5"),
            valid.toString().replace("\"preference\":\"dark\"", "\"preference\":\"unknown\""))
        for (value in mutations) assertThrows(IllegalArgumentException::class.java) { AppearancePreferenceJournal.decode(JSONArray().put(JSONObject(value))) }
        assertThrows(IllegalArgumentException::class.java) { AppearancePreferenceJournal.decode(JSONArray().put(valid).put(valid)) }
    }
}
