package com.thumble.android

import org.json.JSONObject
import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class ThumbCalibrationTest {
    private val key=ThumbCalibrationKey(UUID.fromString("00000000-0000-0000-0000-000000000001"),"test-device","400x800@160",LayoutOrientation.PORTRAIT)
    @Test fun nativePointAndZoneNormalizationExample() {
        val points=listOf(ThumbPoint.of(-2.0,.4),ThumbPoint.of(.4,2.0))
        val zone=ThumbZone.from(ThumbHand.LEFT,points)!!
        assertEquals(.2,zone.center.x,.0001);assertEquals(.7,zone.center.y,.0001)
        assertEquals(.255,zone.radiusX,.0001);assertEquals(.355,zone.radiusY,.0001)
        assertEquals(ThumbPoint.of(.5,.5),ThumbPoint.of(Double.NaN,Double.POSITIVE_INFINITY))
        assertNull(ThumbZone.from(ThumbHand.RIGHT,emptyList()))
    }
    @Test fun nativeScorerFixtureFindsAllFourSuggestionsAndExactScores() {
        val zone=ThumbZone(ThumbHand.LEFT,ThumbPoint.of(.25,.72),.18,.22)
        val controls=listOf(
            ThumbControlGeometry("good","Good",ThumbRect(70.0,550.0,50.0,50.0),ThumbRect(60.0,540.0,70.0,70.0)),
            ThumbControlGeometry("bad","Bad",ThumbRect(374.0,4.0,30.0,30.0),ThumbRect(350.0,0.0,70.0,70.0)),
            ThumbControlGeometry("overlap","Overlap",ThumbRect(365.0,20.0,44.0,44.0),ThumbRect(355.0,10.0,64.0,64.0)))
        val report=ThumbScorer.score(controls,listOf(zone),SkinCanvas(400.0,800.0),ThumbRect(20.0,40.0,360.0,720.0))
        assertEquals(listOf(100,14,20),report.controls.map { it.score });assertEquals(45,report.score)
        assertEquals(ThumbSuggestion.entries,report.suggestions)
        assertEquals(100,ThumbScorer.score(emptyList(),emptyList(),SkinCanvas(1.0,1.0),ThumbRect(0.0,0.0,1.0,1.0)).score)
    }
    @Test fun zoneBoundingBoxIntersectionMatchesNativeReachPolicy() {
        val zone=ThumbZone(ThumbHand.LEFT,ThumbPoint.of(.5,.5),.1,.1)
        // Native accepts the zone bounding rectangle intersection, including its corners.
        val c=ThumbControlGeometry("corner","Corner",ThumbRect(59.0,59.0,44.0,44.0),ThumbRect(59.0,59.0,44.0,44.0))
        assertTrue(ThumbScorer.score(listOf(c),listOf(zone),SkinCanvas(100.0,100.0),ThumbRect(0.0,0.0,100.0,100.0)).controls.single().reachable)
    }
    @Test fun capturesAdvanceOneHandPerLiftAndCanceledDraftCannotPersist() {
        val capture=ThumbCapture(ThumbCalibration(key),ThumbHand.entries)
        val p=ThumbPoint.of(.2,.75)
        val started=capture.update(p);assertEquals(1,started.draft.size)
        val canceled=started.cancelDraft();assertTrue(canceled.calibration.left.isEmpty());assertEquals(ThumbHand.LEFT,canceled.activeHand)
        val left=capture.finish(p,100);assertEquals(16,left.calibration.left.size);assertEquals(ThumbHand.RIGHT,left.activeHand)
        val complete=left.estimate(101);assertTrue(complete.complete);assertEquals(17,complete.calibration.right.size)
        assertEquals(2,complete.calibration.zones.size);assertTrue(capture.calibration.left.isEmpty())
    }
    @Test fun tracesAreBoundedAndDeduplicated() {
        var capture=ThumbCapture(ThumbCalibration(key),listOf(ThumbHand.LEFT))
        repeat(1000) { capture=capture.update(ThumbPoint.of((it%2).toDouble(),(it%3)/2.0)) }
        assertEquals(256,capture.draft.size)
        val repeated=capture.update(capture.draft.last());assertEquals(capture,repeated)
        val finished=capture.finish(ThumbPoint.of(.5,.5),1);assertEquals(256,finished.calibration.left.size)
    }
    @Test fun oneHandTagsMatchNativePrecedenceAndCaseNormalization() {
        fun hands(vararg tags: String)=ThumbCapture.hands(JSONObject().put("designMetadata",JSONObject().put("tags",JSONArray(tags.toList()))))
        assertEquals(listOf(ThumbHand.LEFT),hands(" ONE-HANDED-LEFT ","right-hand"))
        assertEquals(listOf(ThumbHand.RIGHT),hands("right-hand"));assertEquals(ThumbHand.entries,hands("unrelated"))
    }
    @Test fun roundTripRetainsDeviceDisplayOrientationAndRejectsOversizedOrNonfiniteRecords() {
        val value=ThumbCalibration(key).recording(ThumbHand.LEFT,ThumbCapture.defaultSamples(ThumbPoint.of(.2,.7)),123)
        assertEquals(value,ThumbCalibration.parse(value.json()))
        assertNotEquals(key,key.copy(orientation=LayoutOrientation.LANDSCAPE));assertNotEquals(key,key.copy(display="different"))
        val raw=value.json().put("left",JSONArray().apply { repeat(257) { put(JSONObject().put("x",.5).put("y",.5)) } })
        assertTrue(runCatching { ThumbCalibration.parse(raw) }.isFailure)
    }
    private fun fixture(): LayoutSnapshot {
        val bytes=javaClass.classLoader!!.getResourceAsStream("controller-templates/v1/arcadeStick.json")!!.bufferedReader().use { it.readText() }
        return LayoutSnapshot.capture(JSONObject(bytes).getJSONObject("profile").getJSONObject("customization")).oriented(LayoutOrientation.PORTRAIT)
    }
    @Test fun sizeRepairPreservesLockedControlsAndSourceAndUnrelatedFields() {
        var source=fixture();val controls=ThumbLayout.controls(source)
        val small=controls.first { it.kind=="button" };val locked=controls.first { it.kind=="joystick" }
        source=LayoutControlPatch(small.id,mapOf("widthScale" to .1,"heightScale" to .1)).applying(source)
        val raw=source.json();raw.getJSONArray("elements").let { elements -> repeat(elements.length()) { i ->
            val e=elements.getJSONObject(i)
            if(e.getString("id").equals(locked.id.toString(),true)) e.getJSONObject("layout").put("isLocationLocked",true).put("centerX",.1)
        } }
        source=LayoutSnapshot.capture(raw.put("futureField","preserved"))
        val before=source.json().toString();val size=SkinCanvas(400.0,800.0)
        val changed=ThumbLayout.repair(source,ThumbSuggestion.MINIMUM_SIZE,emptyList(),size,ThumbRect(0.0,0.0,400.0,800.0))
        assertEquals(before,source.json().toString());assertEquals("preserved",changed.json().getString("futureField"))
        assertEquals(source.json().getJSONArray("elements").length(),changed.json().getJSONArray("elements").length())
        val frame=ThumbLayout.geometries(changed,size).first { it.id==small.id.toString() }.visual
        assertTrue(frame.width>=43.999);assertTrue(frame.height>=43.999)
        assertEquals(ThumbLayout.controls(source).first { it.id==locked.id }.style.toString(),ThumbLayout.controls(changed).first { it.id==locked.id }.style.toString())
    }
    @Test fun explicitInsetsAndThumbstickInitialCaptureHaveSeparateHitBounds() {
        val base=ThumbLayout.controls(fixture()).first { it.kind=="joystick" }
        val frame=ControlFrame(100.0,100.0,80.0,60.0)
        assertEquals(80.0,ThumbLayout.hit(base.copy(style=JSONObject()),frame).width,0.0)
        assertEquals(60.0,ThumbLayout.hit(base.copy(style=JSONObject().put("joystickVisualStyle","thumbstick")),frame).width,0.0)
        val explicit=ThumbLayout.hit(base.copy(style=JSONObject().put("hitInsets",JSONObject().put("leading",4).put("trailing",8))),frame)
        assertEquals(92.0,explicit.width,0.0);assertEquals(56.0,explicit.x,0.0)
    }
    @Test fun separatedHitRegionsAreStableAndReachRepairPreservesIdentities() {
        val source=fixture();val size=SkinCanvas(400.0,800.0);val safe=ThumbRect(0.0,0.0,400.0,800.0)
        val moved=ThumbLayout.repair(source,ThumbSuggestion.REACH,listOf(ThumbZone(ThumbHand.LEFT,ThumbPoint.of(.25,.75),.2,.2)),size,safe)
        assertEquals(ThumbLayout.controls(source).map { it.id },ThumbLayout.controls(moved).map { it.id })
        val separated=ThumbLayout.repair(moved,ThumbSuggestion.SEPARATE,emptyList(),size,safe)
        assertTrue(separated.samePresentation(ThumbLayout.repair(separated,ThumbSuggestion.SEPARATE,emptyList(),size,safe)))
    }
    private fun pairLayout(x: Double=.5,y: Double=.5): LayoutSnapshot {
        val elements=JSONArray()
        for(index in 1..2) elements.put(JSONObject().put("id","00000000-0000-0000-0000-00000000040$index").put("kind","button")
            .put("label","Target $index").put("layout",JSONObject().put("centerX",x).put("centerY",y)))
        return LayoutSnapshot.capture(JSONObject().put("elements",elements).put("deviceCanvas",JSONObject().put("frameID","iphone-17-pro-portrait")))
    }
    @Test fun nativePackingTieBreakUsesTopBeforeLeftAndPreservesSizes() {
        val source=pairLayout();val size=SkinCanvas(400.0,800.0)
        val result=ThumbLayout.repair(source,ThumbSuggestion.SEPARATE,emptyList(),size,ThumbRect(0.0,0.0,400.0,800.0))
        val geometry=ThumbLayout.geometries(result,size)
        assertEquals(200.0,geometry[0].visual.cx,0.0);assertEquals(400.0,geometry[0].visual.cy,0.0)
        assertEquals(200.0,geometry[1].visual.cx,0.0);assertEquals(300.0,geometry[1].visual.cy,0.0)
        assertEquals(80.0,geometry[1].visual.width,0.0)
        assertEquals(0.0,ThumbScorer.score(geometry,emptyList(),size,ThumbRect(0.0,0.0,400.0,800.0)).controls.maxOf { it.overlap },0.0)
    }
    @Test fun safeAreaRepairUsesVisualFramesAndKeepsNongeometryFields() {
        val source=pairLayout(.99,.01);val size=SkinCanvas(400.0,800.0);val safe=ThumbRect(20.0,20.0,360.0,760.0)
        val result=ThumbLayout.repair(source,ThumbSuggestion.SAFE_AREA,emptyList(),size,safe)
        for(control in ThumbLayout.geometries(result,size)) {
            assertTrue(safe.contains(control.visual));assertEquals(340.0,control.visual.cx,.0001);assertEquals(60.0,control.visual.cy,.0001)
        }
        assertEquals(ThumbLayout.controls(source).map { it.source.getString("label") },ThumbLayout.controls(result).map { it.source.getString("label") })
    }

}
