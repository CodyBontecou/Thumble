package com.thumble.android

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class LayoutControlEditsTest {
    private val custom=UUID.fromString("00000000-0000-0000-0000-000000000302")
    private val builtin=UUID.fromString("00000000-0000-0000-0000-000000000101")
    private fun layout(id: UUID=custom,locked: Boolean=false): LayoutSnapshot = LayoutSnapshot.capture(JSONObject()
        .put("deviceCanvas",JSONObject().put("frameID","iphone-17-pro-portrait"))
        .put("futureField","preserved").put("assetLibrary",JSONObject().put("canonical","keep"))
        .put("elements",JSONArray().put(JSONObject().put("id",id.toString()).put("kind","button").put("label","A")
            .put("layout",JSONObject().put("centerX",.5).put("centerY",.5).put("isLocationLocked",locked).put("futureStyle",42)))))
    private fun control(value: LayoutSnapshot)=ControllerProfile.parse(JSONObject().put("id",custom.toString()).put("customization",value.json())).controls(false).single()
    @Test fun moveClampsVisualBoundsAndNeverCopiesProjectedAppearance() {
        val raw=layout();val c=control(raw)
        val moved=LayoutControlEdits.move(c,ControlFrame(100.0,200.0,60.0,80.0),1000.0,-1000.0,200.0,400.0)!!.applying(raw)
        val style=control(moved).style
        assertEquals(.85,style.getDouble("centerX"),.00001);assertEquals(.1,style.getDouble("centerY"),.00001)
        assertEquals(42,style.getInt("futureStyle"));assertEquals("preserved",moved.json().getString("futureField"))
        assertEquals(raw.json().getJSONObject("assetLibrary").toString(),moved.json().getJSONObject("assetLibrary").toString())
        assertEquals(.5,control(raw).style.getDouble("centerX"),.00001)
        assertNull(LayoutControlEdits.move(c,ControlFrame(100.0,200.0,60.0,80.0),0.0,0.0,200.0,400.0))
    }
    @Test fun builtinPatchesOverrideDictionaryAndDeleteHidesWithoutRemovingIdentity() {
        val raw=layout(builtin).json().put("buttonCustomizations",JSONObject().put(builtin.toString(),JSONObject().put("widthScale",2).put("futureOverride",12)))
        val input=LayoutSnapshot.capture(raw)
        val result=LayoutControlPatch(builtin,mapOf("rotationDegrees" to 15.0)).applying(input)
        assertEquals(2.0,control(result).style.getDouble("widthScale"),.00001)
        assertEquals(12,control(result).style.getInt("futureOverride"))
        // Swift setButtonCustomization updates both the override and declared element.
        assertEquals(15.0,result.json().getJSONArray("elements").getJSONObject(0).getJSONObject("layout").getDouble("rotationDegrees"),0.0)
        val deleted=LayoutControlPatch(builtin,delete=true).applying(result)
        assertEquals(1,deleted.json().getJSONArray("elements").length())
        assertTrue(deleted.json().swiftMap("buttonCustomizations").values.single().let { (it as JSONObject).getBoolean("isHidden") })
        assertTrue(deleted.json().getJSONArray("elements").getJSONObject(0).getJSONObject("layout").getBoolean("isHidden"))
    }
    @Test fun lockedControlsOnlyAllowDeletionAndCustomDeletionCannotResurrectLegacyMirror() {
        val raw=layout(locked=true);val c=control(raw)
        assertNull(LayoutControlEdits.rotate(c,15.0));assertNull(LayoutControlEdits.scale(c,.1))
        assertNull(LayoutControlEdits.move(c,ControlFrame(100.0,100.0,60.0,60.0),4.0,0.0,200.0,300.0))
        assertTrue(raw.samePresentation(LayoutControlPatch(custom,mapOf("centerX" to .7)).applying(raw)))
        val mirror=raw.json().put("customButtons",JSONArray().put(raw.json().getJSONArray("elements").getJSONObject(0)))
        val result=LayoutControlPatch(custom,delete=true).applying(LayoutSnapshot.capture(mirror)).json()
        assertEquals(0,result.getJSONArray("elements").length());assertEquals(0,result.getJSONArray("customButtons").length())
    }
    @Test fun customGeometryUpdatesItsExistingAppearanceMirrorWithoutChangingOtherMetadata() {
        val raw=layout().json().put("customButtons",JSONArray().put(JSONObject().put("id",custom.toString())
            .put("controlKind","button").put("label","Mirror label").put("layout",control(layout()).style)))
        val entry=LayoutSnapshot.capture(raw)
        val changed=LayoutControlPatch(custom,mapOf("centerX" to .65,"rotationDegrees" to 15.0)).applying(entry).json()
        val mirror=changed.getJSONArray("customButtons").getJSONObject(0)
        assertEquals(.65,mirror.getJSONObject("layout").getDouble("centerX"),0.0)
        assertEquals(15.0,mirror.getJSONObject("layout").getDouble("rotationDegrees"),0.0)
        assertEquals("Mirror label",mirror.getString("label"))
        assertEquals(.5,entry.json().getJSONArray("customButtons").getJSONObject(0).getJSONObject("layout").getDouble("centerX"),0.0)
    }
    @Test fun customDeletionPrunesIdentityReferencesAndEmptyGroupsButPreservesOtherMetadata() {
        val other=UUID.fromString("00000000-0000-0000-0000-000000000303")
        fun identity(id: UUID)=JSONObject().put("kind","custom").put("id",id.toString())
        val raw=layout().json()
        raw.getJSONArray("elements").put(JSONObject().put("id",other.toString()).put("kind","button").put("label","Keep").put("layout",JSONObject()))
        raw.put("labelOverrides",JSONArray().put(custom.toString()).put("Deleted").put(other.toString()).put("Kept"))
        raw.put("designMetadata",JSONObject().put("sourceTemplateID","test-origin").put("notes","Keep notes")
            .put("layerOrder",JSONArray().put(identity(custom)).put(identity(other)))
            .put("groups",JSONArray().put(JSONObject().put("id",UUID.randomUUID().toString()).put("name","Empty after deletion").put("children",JSONArray().put(identity(custom))))
                .put(JSONObject().put("id",UUID.randomUUID().toString()).put("name","Keep group").put("children",JSONArray().put(identity(custom)).put(identity(other))))))
        val entry=LayoutSnapshot.capture(raw)
        val result=LayoutControlPatch(custom,delete=true).applying(entry).json()
        assertEquals(1,result.getJSONArray("elements").length())
        assertEquals(setOf(other.toString().uppercase()),result.swiftMap("labelOverrides").keys)
        val metadata=result.getJSONObject("designMetadata")
        assertEquals(1,metadata.getJSONArray("layerOrder").length())
        assertEquals(1,metadata.getJSONArray("groups").length())
        assertEquals(1,metadata.getJSONArray("groups").getJSONObject(0).getJSONArray("children").length())
        assertEquals("test-origin",metadata.getString("sourceTemplateID"));assertEquals("Keep notes",metadata.getString("notes"))
        assertEquals(2,entry.json().getJSONObject("designMetadata").getJSONArray("groups").length())
    }
    @Test fun deletingTheLastGroupedControlRemovesNowDefaultDesignMetadata() {
        val identity=JSONObject().put("kind","custom").put("id",custom.toString())
        val metadata=JSONObject().put("schemaVersion",1).put("layerOrder",JSONArray()
            .put(JSONObject().put("kind","system").put("system","top_bar_activation")).put(identity))
            .put("groups",JSONArray().put(JSONObject().put("id",UUID.randomUUID().toString()).put("name","Last group")
                .put("children",JSONArray().put(identity))))
        val result=LayoutControlPatch(custom,delete=true).applying(LayoutSnapshot.capture(layout().json().put("designMetadata",metadata))).json()
        assertFalse("Swift omits design metadata when all remaining values are defaults",result.has("designMetadata"))
    }
    @Test fun cornerResizeKeepsOppositeCornerAndNativeLimits() {
        val raw=layout();val c=control(raw);val f=ControlFrame(100.0,150.0,60.0,80.0)
        val result=LayoutControlEdits.resize(c,f,LayoutResizeCorner.TOP_LEFT,20.0,30.0,300.0,400.0)!!.values
        assertEquals(40.0/60,result.getValue("widthScale"),.00001);assertEquals(50.0/80,result.getValue("heightScale"),.00001)
        assertEquals(110.0/300,result.getValue("centerX"),.00001);assertEquals(165.0/400,result.getValue("centerY"),.00001)
        val tiny=LayoutControlEdits.resize(c,f,LayoutResizeCorner.BOTTOM_RIGHT,-999.0,-999.0,300.0,400.0)!!.values
        assertEquals(1.0/60,tiny.getValue("widthScale"),.00001);assertEquals(1.0/80,tiny.getValue("heightScale"),.00001)
        assertNull(LayoutControlEdits.resize(c,f,LayoutResizeCorner.TOP_LEFT,Double.NaN,1.0,300.0,400.0))
    }
    @Test fun rotationUsesNativePositiveHalfTurnAndOneGestureIsOneHistoryEntry() {
        assertEquals(180.0,LayoutControlEdits.rotation(-180.0),0.0);assertEquals(-165.0,LayoutControlEdits.rotation(195.0),0.0)
        val entry=layout();val history=LayoutEditSession(entry);val c=control(entry)
        val preview=LayoutControlEdits.rotate(c,5.0)!!.applying(entry);history.preview(preview)
        assertFalse(history.canUndo)
        val final=LayoutControlEdits.rotate(c,15.0)!!.applying(entry);history.commit(final)
        assertTrue(history.undoSnapshot!!.samePresentation(entry));assertTrue(history.undo()!!.samePresentation(entry));assertFalse(history.canUndo)
        assertNull(LayoutControlEdits.rotate(c,0.0))
    }
}
