package com.thumble.android

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ProfileAppearanceBankTest {
    private fun fixture() = javaClass.classLoader!!.getResourceAsStream("profile-resources/v1/fixture.json")!!
        .use { JSONObject(it.bufferedReader().readText()) }
    private fun profile() = fixture().getJSONObject("expandedProfile")
    private fun bank(profile: JSONObject) = ProfileAppearanceBank(profile.getJSONObject("appearanceBank"))
    private fun layout(profile: JSONObject) = profile.getJSONObject("customization")
    private fun element(layout: JSONObject) = layout.getJSONArray("elements").getJSONObject(0)
    private fun style(layout: JSONObject) = element(layout).getJSONObject("layout")
    private fun change(layout: JSONObject, edit: (JSONObject) -> Unit) {
        edit(style(layout))
        val pairs = layout.getJSONArray("buttonCustomizations")
        pairs.put(1, AppearanceJSON.objectCopy(style(layout)))
    }
    private fun assertJSON(expected: Any?, actual: Any?) = assertTrue("Expected $expected\nActual $actual", AppearanceJSON.same(expected, actual))
    private fun variant(profile: JSONObject, scheme: String, action: String = "base"): JSONObject =
        AppearanceJSON.objects(profile.getJSONObject("appearanceBank").getJSONArray("variants"))
            .first { it.getString("colorScheme") == scheme && it.getString("actionSet") == action }.getJSONObject("appearance")
    private fun variantStyle(profile: JSONObject, scheme: String, action: String = "base") =
        variant(profile, scheme, action).getJSONObject("controls").getJSONObject(element(layout(profile)).getString("id").lowercase())

    @Test fun allEightNativeStatesRenderWithoutPackageLookupAndLeaveBindingsGeometryAndSourceUntouched() {
        val raw = fixture().getJSONObject("pooledProfile")
        val source = ControllerProfile.parse(raw); val before = raw.toString()
        val repository = SkinRenderRepository { error("Owned paint must never load a package") }
        for (scheme in ProfileAppearanceBank.schemes) for (action in ProfileAppearanceBank.actions) {
            val projection = repository.resolve(source, true, scheme == "dark", action)
            assertNull(projection.warning); assertNull(projection.compatibility)
            val output = projection.profile!!.layout(true)
            assertEquals("$scheme/$action", style(output).getJSONObject("icon").getString("value"))
            assertJSON(element(layout(raw)).getJSONObject("defaultOutput"), element(output).getJSONObject("defaultOutput"))
            assertEquals(style(layout(raw)).getDouble("centerX"), style(output).getDouble("centerX"), 0.0)
            assertEquals(style(layout(raw)).getDouble("widthScale"), style(output).getDouble("widthScale"), 0.0)
            assertEquals(source.id, projection.profile.id)
            assertSame(projection, repository.resolve(source, true, scheme == "dark", action))
            assertFalse(projection.matches(source, true, scheme == "dark", if (action == "base") "left-trigger" else "base"))
            assertEquals("Zml4dHVyZS1pbWFnZQ==", output.getJSONObject("assetLibrary").getJSONArray("assets").getJSONObject(0).getString("data"))
        }
        assertEquals(before, raw.toString())
    }

    @Test fun explicitPreferenceOverridesSystemAndPortraitDoesNotAcquireLandscapeBank() {
        val raw = profile(); layout(raw).put("colorSchemePreference", "dark")
        val source = ControllerProfile.parse(raw)
        val repo = SkinRenderRepository { error("No package") }
        assertEquals("dark/base", style(repo.resolve(source, true, false).profile!!.layout(true)).getJSONObject("icon").getString("value"))
        assertSame(source, repo.resolve(source, false, false).profile)
    }

    @Test fun nestedEditsPreserveOtherStatePaintAndPointingProperties() {
        val p = profile(); val current = layout(p)
        val target = variantStyle(p, "dark")
        target.getJSONObject("visualStyle").getJSONObject("pressed").put("strokeWidth", 7)
            .put("content", JSONObject().put("fontSize", 24).put("pointing", JSONObject().put("joystickRingColor", JSONObject().put("red", .9))))
        change(current) { it.getJSONObject("visualStyle").getJSONObject("pressed")
            .put("content", JSONObject().put("legend", "Edited").put("pointing", JSONObject().put("trackpadFrameStrokeWidth", 4))) }
        val merged = style(bank(p).resolve(current, "dark")).getJSONObject("visualStyle").getJSONObject("pressed")
        assertEquals(7, merged.getInt("strokeWidth"))
        val content = merged.getJSONObject("content")
        assertEquals("Edited", content.getString("legend")); assertEquals(24, content.getInt("fontSize"))
        assertEquals(4, content.getJSONObject("pointing").getInt("trackpadFrameStrokeWidth"))
        assertEquals(.9, content.getJSONObject("pointing").getJSONObject("joystickRingColor").getDouble("red"), 0.0)
        assertJSON(target.getJSONObject("visualStyle").getJSONObject("pressed").getJSONObject("fillStyle"), merged.getJSONObject("fillStyle"))
    }

    @Test fun newReusableStyleDropsInheritedInlinePaintAndDirectIconReplacesContentIcons() {
        val p = profile(); val current = layout(p)
        change(current) { it.put("styleID", "new-style").put("icon", JSONObject().put("source", "text").put("value", "Mine")) }
        val merged = style(bank(p).resolve(current, "dark"))
        assertEquals("new-style", merged.getString("styleID"))
        val visual = merged.getJSONObject("visualStyle")
        for (name in listOf("normal", "pressed", "active", "disabled")) {
            assertFalse(visual.getJSONObject(name).has("fillStyle"))
            assertEquals("Mine", visual.getJSONObject(name).getJSONObject("content").getJSONObject("icon").getString("value"))
        }
    }

    @Test fun directFillEditWinsInlinePaintButMovingGlobalFillToSchemeStorageIsBookkeeping() {
        val p = profile(); val current = layout(p)
        val global = AppearanceJSON.objectCopy(style(current).getJSONObject("fillStyle"))
        val darkFill = JSONObject().put("kind", "solid").put("color", JSONObject().put("red", .7).put("green", .1).put("blue", .2).put("alpha", 1))
        variantStyle(p, "dark").getJSONObject("visualStyle").getJSONObject("normal").put("fillStyle", darkFill)
        change(current) { it.remove("fillStyle"); it.put("lightFillStyle", global).put("darkFillStyle", global) }
        assertJSON(darkFill, style(bank(p).resolve(current, "dark")).getJSONObject("visualStyle").getJSONObject("normal").getJSONObject("fillStyle"))
        change(current) { it.put("darkFillStyle", JSONObject().put("kind", "solid").put("color", JSONObject().put("red", .3))) }
        assertEquals(.3, style(bank(p).resolve(current, "dark")).getJSONObject("visualStyle").getJSONObject("normal")
            .getJSONObject("fillStyle").getJSONObject("color").getDouble("red"), 0.0)
    }

    @Test fun surfaceCollectionsMergeByIdentityAndApplyNativeArtworkOrder() {
        val p = profile(); val current = layout(p)
        fun artwork(id: String, opacity: Double = 1.0) = JSONObject().put("id", id).put("opacity", opacity)
        variant(p, "light").put("artworkLayers", JSONArray().put(artwork("a")).put(artwork("b")))
        variant(p, "dark").put("artworkLayers", JSONArray().put(artwork("a", .5)).put(artwork("dark-only")).put(artwork("b", .6)))
        current.put("artworkLayers", JSONArray().put(artwork("b").put("rotationDegrees", 15)).put(artwork("a")))
        val output = bank(p).resolve(current, "dark").getJSONArray("artworkLayers")
        assertEquals(listOf("a", "b", "dark-only"), AppearanceJSON.objects(output).map { it.getString("id") })
        assertEquals(.6, output.getJSONObject(1).getDouble("opacity"), 0.0)
        assertEquals(15, output.getJSONObject(1).getInt("rotationDegrees"))
        current.put("artworkLayers", JSONArray())
        assertEquals(0, bank(p).resolve(current, "dark").getJSONArray("artworkLayers").length())
    }

    @Test fun geometryDeletionOpaqueMetadataAndHapticEditsArePreserved() {
        val p = profile(); val current = layout(p)
        current.put("futureMetadata", JSONObject().put("important", true))
        change(current) { it.put("centerX", .82).put("isHidden", true).put("hapticFeedback", JSONObject().put("intensity", .12)) }
        val output = bank(p).resolve(current, "dark", "both-triggers")
        assertEquals(.82, style(output).getDouble("centerX"), 0.0)
        assertTrue(style(output).getBoolean("isHidden")); assertTrue(output.getJSONObject("futureMetadata").getBoolean("important"))
        assertEquals(.12, style(output).getJSONObject("hapticFeedback").getDouble("intensity"), 0.0)
        assertJSON(style(output), output.getJSONArray("buttonCustomizations").getJSONObject(1))
        current.put("elements", JSONArray()).put("buttonCustomizations", JSONArray())
        assertEquals(0, bank(p).resolve(current, "dark").getJSONArray("elements").length())
    }

    @Test fun corruptBanksAndMissingResourcesReportRecoveryWithoutPackageFallbackOrSourceMutation() {
        for (mutate in listOf<(JSONObject) -> Unit>(
            { it.put("schemaVersion", 99) },
            { it.getJSONArray("variants").remove(0) },
            { it.getJSONArray("variants").put(0, it.getJSONArray("variants").getJSONObject(1)) },
            { it.getJSONArray("variants").getJSONObject(0).getJSONObject("appearance").put("elements", JSONArray()) },
            { it.getJSONArray("variants").getJSONObject(0).getJSONObject("appearance").getJSONObject("controls").put("bad-id", JSONObject()) },
            { it.getJSONArray("variants").getJSONObject(0).getJSONObject("appearance").getJSONObject("topBar").put("centerX", .2) },
            { it.getJSONArray("variants").getJSONObject(0).getJSONObject("appearance").put("assetLibrary", JSONObject().put("assets", JSONArray()))
                .getJSONObject("topBar").put("icon", JSONObject().put("source", "asset").put("value", "missing")) }
        )) {
            val p = profile(); mutate(p.getJSONObject("appearanceBank")); val before = p.toString()
            assertThrows(IllegalArgumentException::class.java) { bank(p) }
            val source = ControllerProfile.parse(p)
            val result = SkinRenderRepository { error("No package fallback") }.resolve(source, true, false)
            assertNotNull(result.warning); assertSame(source, result.profile); assertEquals(before, p.toString())
        }
        val pooled = fixture().getJSONObject("pooledProfile").put("appearanceResources", JSONObject())
        val source = ControllerProfile.parse(pooled)
        assertSame(source, SkinRenderRepository { error("No package") }.resolve(source, true, true).profile)
    }

    @Test fun phoneMoveDeleteUndoCancelAndOfflineJournalKeepCanonicalPaintAndCompactResources() {
        val raw = fixture().getJSONObject("pooledProfile")
        val source = ControllerProfile.parse(raw); val before = raw.toString()
        val orientation = LayoutOrientation.LANDSCAPE
        val entry = LayoutSnapshot.resolved(source, orientation)
        val history = LayoutEditSession(entry)
        val id = java.util.UUID.fromString(element(entry.json()).getString("id"))
        val moved = LayoutControlPatch(id, mapOf("centerX" to .73, "rotationDegrees" to 27.0)).applying(entry)
        history.commit(moved)
        val edit = PendingLayoutEdit.create(source.id, orientation, moved.json(), 300, "trusted-mac")
        val persisted = LayoutEditJournal.encode(listOf(edit))
        val reloaded = LayoutEditJournal.decode(JSONArray(persisted.toString()))
        val optimistic = LayoutEditJournal.applying(source, reloaded.single())
        val repo = SkinRenderRepository { error("No installed package") }
        val dark = repo.resolve(optimistic, true, true, "both-triggers").profile!!.layout(true)
        assertEquals(.73, style(dark).getDouble("centerX"), 0.0)
        assertEquals("dark/both-triggers", style(dark).getJSONObject("icon").getString("value"))
        val canonical = reloaded.single().customization.json()
        assertEquals("light/base", style(canonical).getJSONObject("icon").getString("value"))
        assertTrue(style(canonical).getJSONObject("fillStyle").getJSONObject("image").get("data") is JSONObject)
        assertFalse(persisted.toString().contains("Zml4dHVyZS1pbWFnZQ=="))
        assertJSON(raw.getJSONObject("appearanceResources"), optimistic.source.getJSONObject("appearanceResources"))
        val reconciliation = LayoutEditJournal.reconcile(ProfileSnapshot(listOf(source), source.id, source.id), reloaded, "trusted-mac", false)
        assertEquals(1, reconciliation.uploads.size); assertEquals(1, reconciliation.remaining.size)
        assertEquals(.73, style(reconciliation.snapshot.selected!!.layout(true)).getDouble("centerX"), 0.0)
        val wrongHost = LayoutEditJournal.reconcile(ProfileSnapshot(listOf(source), source.id, source.id), reloaded, "other-mac", false)
        assertEquals(0, wrongHost.uploads.size); assertSame(source, wrongHost.snapshot.selected)
        val deleted = LayoutControlPatch(id, delete = true).applying(moved)
        history.commit(deleted)
        val hidden = LayoutEditJournal.applying(source, PendingLayoutEdit.create(source.id, orientation, deleted.json(), 301, "trusted-mac"))
        assertTrue(repo.resolve(hidden, true, true).profile!!.controls(true).isEmpty())
        assertTrue(history.undo()!!.samePresentation(moved))
        assertTrue(history.cancel().samePresentation(entry))
        assertEquals(before, raw.toString())
    }

    @Test fun appearanceCopiesShareImmutableImageStringsButCannotMutateSavedContainers() {
        val raw = fixture().getJSONObject("pooledProfile"); val before = raw.toString()
        val table = ProfileResourceTable.fromProfile(raw)!!
        val expanded = table.expanding(raw)
        val canonicalData = style(layout(expanded)).getJSONObject("fillStyle").getJSONObject("image").getString("data")
        val bankData = variantStyle(expanded, "dark").getJSONObject("fillStyle").getJSONObject("image").getString("data")
        assertSame(canonicalData, bankData)
        val output = bank(expanded).resolve(layout(expanded), "dark")
        assertSame(canonicalData, style(output).getJSONObject("fillStyle").getJSONObject("image").getString("data"))
        style(output).put("shadowStrength", .1)
        assertEquals(.75, style(layout(expanded)).getDouble("shadowStrength"), 0.0)
        assertEquals(before, raw.toString())
    }
}
