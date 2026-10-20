package com.thumble.android

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import kotlin.math.*

internal enum class ThumbHand { LEFT, RIGHT; val label get()=name.lowercase().replaceFirstChar { it.uppercase() } }
@ConsistentCopyVisibility
internal data class ThumbPoint private constructor(val x: Double,val y: Double) {
    companion object {
        fun of(x: Double,y: Double)=ThumbPoint(clamp(x),clamp(y))
        private fun clamp(v: Double)=if(v.isFinite()) v.coerceIn(0.0,1.0) else .5
    }
}
internal data class ThumbRect(val x: Double,val y: Double,val width: Double,val height: Double) {
    val right get()=x+width;val bottom get()=y+height
    val cx get()=x+width/2;val cy get()=y+height/2
    fun shifted(dx: Double,dy: Double)=copy(x=x+dx,y=y+dy)
    fun contains(r: ThumbRect)=r.x>=x && r.y>=y && r.right<=right && r.bottom<=bottom
    fun intersection(r: ThumbRect)=ThumbRect(max(x,r.x),max(y,r.y),max(0.0,min(right,r.right)-max(x,r.x)),max(0.0,min(bottom,r.bottom)-max(y,r.y)))
    fun intersects(r: ThumbRect)=intersection(r).let { it.width>0 && it.height>0 }
}
internal data class ThumbZone(val hand: ThumbHand,val center: ThumbPoint,val radiusX: Double,val radiusY: Double) {
    fun distance(p: ThumbPoint)=distance(p.x,p.y)
    fun distance(x: Double,y: Double)=hypot((x-center.x)/max(radiusX,.001),(y-center.y)/max(radiusY,.001))
    fun frame(size: SkinCanvas)=ThumbRect((center.x-radiusX)*size.width,(center.y-radiusY)*size.height,radiusX*2*size.width,radiusY*2*size.height)
    companion object {
        fun from(hand: ThumbHand,samples: List<ThumbPoint>): ThumbZone? {
            if(samples.isEmpty()) return null
            val minX=samples.minOf { it.x };val maxX=samples.maxOf { it.x };val minY=samples.minOf { it.y };val maxY=samples.maxOf { it.y }
            return ThumbZone(hand,ThumbPoint.of((minX+maxX)/2,(minY+maxY)/2),max(.12,(maxX-minX)/2+.055).coerceIn(.06,.65),max(.14,(maxY-minY)/2+.055).coerceIn(.06,.65))
        }
    }
}
internal data class ThumbCalibrationKey(val profileID: UUID,val device: String,val display: String,val orientation: LayoutOrientation) {
    init { require(device.length in 1..512 && display.length in 1..512) }
    fun json()=JSONObject().put("profileID",profileID.toString()).put("device",device).put("display",display).put("orientation",orientation.wireValue)
}
internal data class ThumbCalibration(val key: ThumbCalibrationKey,val left: List<ThumbPoint> = emptyList(),val right: List<ThumbPoint> = emptyList(),val updatedAt: Long=0) {
    init { require(left.size<=256 && right.size<=256 && updatedAt>=0) }
    val zones get()=listOfNotNull(ThumbZone.from(ThumbHand.LEFT,left),ThumbZone.from(ThumbHand.RIGHT,right))
    fun recording(hand: ThumbHand,samples: List<ThumbPoint>,now: Long)=if(hand==ThumbHand.LEFT) copy(left=samples.take(256),updatedAt=now) else copy(right=samples.take(256),updatedAt=now)
    fun json(): JSONObject {
        fun points(v: List<ThumbPoint>)=JSONArray().also { a -> v.forEach { a.put(JSONObject().put("x",it.x).put("y",it.y)) } }
        return JSONObject().put("schemaVersion",1).put("key",key.json()).put("left",points(left)).put("right",points(right)).put("updatedAt",updatedAt)
    }
    companion object {
        fun parse(raw: JSONObject): ThumbCalibration {
            require(raw.getInt("schemaVersion")==1)
            val k=raw.getJSONObject("key")
            fun points(name: String): List<ThumbPoint> {
                val a=raw.getJSONArray(name);require(a.length()<=256)
                return (0 until a.length()).map { a.getJSONObject(it).let { p ->
                    val x=p.getDouble("x");val y=p.getDouble("y");require(x.isFinite() && y.isFinite());ThumbPoint.of(x,y)
                } }
            }
            return ThumbCalibration(ThumbCalibrationKey(UUID.fromString(k.getString("profileID")),k.getString("device"),k.getString("display"),LayoutOrientation.parse(k.getString("orientation"))),points("left"),points("right"),raw.getLong("updatedAt"))
        }
    }
}
internal enum class ThumbSuggestion(val title: String,val detail: String) {
    REACH("Move controls into thumb reach","Repositions out-of-zone controls around your calibrated thumb areas."),
    SAFE_AREA("Move controls inside safe areas","Moves edge controls away from system gestures and cutouts."),
    MINIMUM_SIZE("Make controls at least 44 dp","Enlarges small controls while preserving their styling."),
    SEPARATE("Separate overlapping touch targets","Separates actual touch regions, including invisible hit expansion.")
}
internal data class ThumbControlGeometry(val id: String,val label: String,val visual: ThumbRect,val hit: ThumbRect)
internal data class ThumbControlScore(val id: String,val score: Int,val reachable: Boolean,val safe: Boolean,val minimumSize: Boolean,val overlap: Double)
internal data class ThumbReport(val score: Int,val controls: List<ThumbControlScore>,val suggestions: List<ThumbSuggestion>)

/** Matches IOSLocalKeypadUX's reach/size/safe-area/runtime-hit scoring, in Android dp. */
internal object ThumbScorer {
    fun score(controls: List<ThumbControlGeometry>,zones: List<ThumbZone>,size: SkinCanvas,safe: ThumbRect): ThumbReport {
        if(controls.isEmpty()) return ThumbReport(100,emptyList(),emptyList())
        val overlaps=DoubleArray(controls.size)
        for(i in controls.indices) for(j in i+1 until controls.size) {
            val a=controls[i].hit;val b=controls[j].hit;val intersection=a.intersection(b)
            if(intersection.width>.5 && intersection.height>.5) {
                val ratio=intersection.width*intersection.height/max(1.0,min(a.width*a.height,b.width*b.height))
                overlaps[i]=max(overlaps[i],ratio);overlaps[j]=max(overlaps[j],ratio)
            }
        }
        val scores=controls.mapIndexed { i,c ->
            val x=c.hit.cx/max(size.width,1.0);val y=c.hit.cy/max(size.height,1.0)
            val reach=zones.isEmpty() || zones.any { it.distance(x,y)<=1 || it.frame(size).intersects(c.hit) }
            val inside=safe.contains(c.visual);val shortest=min(c.visual.width,c.visual.height);val minimum=shortest>=44
            var score=100.0
            if(!reach) score-=45
            if(!inside) score-=20
            if(!minimum) score-=20*(1-(shortest/44).coerceIn(0.0,1.0))
            score-=min(15.0,overlaps[i]*30)
            ThumbControlScore(c.id,score.roundToInt().coerceIn(0,100),reach,inside,minimum,overlaps[i])
        }
        val suggestions=buildList {
            if(scores.any { !it.reachable }) add(ThumbSuggestion.REACH)
            if(scores.any { !it.safe }) add(ThumbSuggestion.SAFE_AREA)
            if(scores.any { !it.minimumSize }) add(ThumbSuggestion.MINIMUM_SIZE)
            if(scores.any { it.overlap>.01 }) add(ThumbSuggestion.SEPARATE)
        }
        return ThumbReport(scores.map { it.score }.average().roundToInt(),scores,suggestions)
    }
}

/** One trace per required hand; canceled gestures cannot advance or persist. */
internal data class ThumbCapture(val calibration: ThumbCalibration,val hands: List<ThumbHand>,val handIndex: Int=0,val draft: List<ThumbPoint> = emptyList()) {
    val activeHand get()=hands.getOrNull(handIndex)
    val complete get()=activeHand==null
    val visibleZones get()=calibration.zones.filterNot { it.hand==activeHand }+listOfNotNull(activeHand?.let { ThumbZone.from(it,draft) })
    fun update(p: ThumbPoint): ThumbCapture {
        if(complete || draft.size>=256 || draft.lastOrNull()?.let { hypot(it.x-p.x,it.y-p.y)<.008 }==true) return this
        return copy(draft=draft+p)
    }
    fun cancelDraft()=copy(draft=emptyList())
    fun finish(p: ThumbPoint,now: Long): ThumbCapture {
        val hand=activeHand ?: return this
        val next=update(p)
        val samples=if(next.draft.size==1) defaultSamples(next.draft.single()) else next.draft
        if(samples.isEmpty()) return this
        return next.copy(calibration=calibration.recording(hand,samples,now),handIndex=handIndex+1,draft=emptyList())
    }
    fun estimate(now: Long): ThumbCapture {
        val hand=activeHand ?: return this
        val p=ThumbPoint.of(if(hand==ThumbHand.LEFT) .24 else .76,.74)
        // Native includes the final center sample after its 16-point ellipse.
        return copy(draft=defaultSamples(p)).finish(p,now)
    }
    companion object {
        fun hands(layout: JSONObject): List<ThumbHand> {
            val tags=layout.optJSONObject("designMetadata")?.optJSONArray("tags")
            val values=if(tags==null) emptySet() else (0 until tags.length()).map { tags.getString(it).trim().lowercase() }.toSet()
            return when {
                values.any { it in setOf("left-hand","one-handed-left") } -> listOf(ThumbHand.LEFT)
                values.any { it in setOf("right-hand","one-handed-right") } -> listOf(ThumbHand.RIGHT)
                else -> ThumbHand.entries
            }
        }
        fun defaultSamples(p: ThumbPoint)=(0 until 16).map { angle -> ThumbPoint.of(p.x+cos(angle*PI/8)*.16,p.y+sin(angle*PI/8)*.20) }
    }
}

internal object ThumbLayout {
    private val temporaryID=UUID.fromString("00000000-0000-0000-0000-000000000001")
    fun controls(layout: LayoutSnapshot)=ControllerProfile(temporaryID,"Calibration",JSONObject().put("customization",layout.json())).controls(false).filter { it.kind !in setOf("decoration","text") }
    fun geometries(layout: LayoutSnapshot,size: SkinCanvas): List<ThumbControlGeometry> {
        val southpaw=layout.json().optString("layoutMode")=="southpaw"
        return controls(layout).map { c ->
            val f=ControlGeometry.resolve(c,size.width,size.height,southpaw)
            ThumbControlGeometry(c.id.toString(),c.accessibilityName,ThumbRect(f.left,f.top,f.width,f.height),hit(c,f))
        }
    }
    fun hit(c: Control,f: ControlFrame): ThumbRect {
        val insets=c.style.optJSONObject("hitInsets")
        if(insets==null && c.kind=="joystick") {
            val side=if(c.style.optString("joystickVisualStyle")=="thumbstick") max(44.0,min(f.width,f.height)) else min(f.width,f.height)+20
            return ThumbRect(f.centerX-side/2,f.centerY-side/2,side,side)
        }
        fun inset(key: String)=if(insets==null) 10.0 else insets.finite(key,0.0).coerceIn(0.0,96.0)
        return ThumbRect(f.left-inset("leading"),f.top-inset("top"),f.width+inset("leading")+inset("trailing"),f.height+inset("top")+inset("bottom"))
    }
    fun repair(source: LayoutSnapshot,suggestion: ThumbSuggestion,zones: List<ThumbZone>,size: SkinCanvas,safe: ThumbRect): LayoutSnapshot {
        var next=source
        val southpaw=(source.json().optString("layoutMode")=="southpaw")
        val report=ThumbScorer.score(geometries(source,size),zones,size,safe)
        val outOfReach=report.controls.filter { !it.reachable }.map { it.id }.toSet()
        val controls=controls(source).filter { !it.style.optBoolean("isLocationLocked") }.sortedBy { stableID(it) }
        val counts=mutableMapOf<ThumbHand,Int>()
        for(c in controls) {
            val f=ControlGeometry.resolve(c,size.width,size.height,southpaw)
            val values=when(suggestion) {
                ThumbSuggestion.MINIMUM_SIZE -> {
                    val w=min(size.width,max(44.0,f.width));val h=min(size.height,max(44.0,f.height))
                    if(w<=f.width+.001 && h<=f.height+.001) continue
                    position(f.centerX,f.centerY,w,h,size)+mapOf("widthScale" to c.style.finite("widthScale",1.0)*w/max(f.width,.001),"heightScale" to c.style.finite("heightScale",1.0)*h/max(f.height,.001))
                }
                ThumbSuggestion.SAFE_AREA -> {
                    if(safe.contains(ThumbRect(f.left,f.top,f.width,f.height))) continue
                    mapOf("centerX" to min(max(f.centerX,safe.x+f.width/2),safe.right-f.width/2).let { (it/max(size.width,1.0)).coerceIn(0.0,1.0) },
                        "centerY" to min(max(f.centerY,safe.y+f.height/2),safe.bottom-f.height/2).let { (it/max(size.height,1.0)).coerceIn(0.0,1.0) })
                }
                ThumbSuggestion.REACH -> {
                    if(zones.isEmpty() || c.id.toString() !in outOfReach) continue
                    val role=c.source.optString("visualRole")
                    val roleHand=if(c.kind!="button") null else when(role) { "movement" -> ThumbHand.LEFT;"primary_action","secondary_action" -> ThumbHand.RIGHT;else -> null }
                    val p=ThumbPoint.of(f.centerX/max(size.width,1.0),f.centerY/max(size.height,1.0))
                    val zone=zones.firstOrNull { it.hand==roleHand } ?: zones.minBy { it.distance(p) }
                    val index=counts[zone.hand] ?: 0;counts[zone.hand]=index+1
                    val x=(zone.center.x+listOf(-.48,0.0,.48)[index%3]*zone.radiusX).coerceIn(0.0,1.0)*size.width
                    val y=(zone.center.y+(.30-(index/3)*.42)*zone.radiusY).coerceIn(0.0,1.0)*size.height
                    position(x,y,f.width,f.height,size)
                }
                ThumbSuggestion.SEPARATE -> continue
            }
            next=LayoutControlPatch(c.id,values).applying(next)
        }
        if(suggestion in setOf(ThumbSuggestion.REACH,ThumbSuggestion.SEPARATE)) next=separate(next,size)
        return next
    }
    private fun stableID(c: Control)=if(c.isBuiltin) "builtin.${c.id.toString().lowercase()}" else "custom.${c.id.toString().lowercase()}"
    private fun position(x: Double,y: Double,w: Double,h: Double,size: SkinCanvas): Map<String,Double> {
        val hw=min(size.width/2,max(w/2,1.0));val hh=min(size.height/2,max(h/2,1.0))
        return mapOf("centerX" to x.coerceIn(hw,max(hw,size.width-hw))/size.width,"centerY" to y.coerceIn(hh,max(hh,size.height-hh))/size.height)
    }
    private fun separate(source: LayoutSnapshot,size: SkinCanvas): LayoutSnapshot {
        val controls=controls(source).sortedBy { stableID(it) };val southpaw=(source.json().optString("layoutMode")=="southpaw")
        fun frame(c: Control)=ControlGeometry.resolve(c,size.width,size.height,southpaw)
        val obstacles=controls.filter { it.style.optBoolean("isLocationLocked") }.map { hit(it,frame(it)) }.toMutableList()
        var next=source
        for(c in controls.filterNot { it.style.optBoolean("isLocationLocked") }) {
            val f=frame(c);val original=ThumbRect(f.left,f.top,f.width,f.height);val hit=hit(c,f)
            fun movedHit(r: ThumbRect)=hit.shifted(r.cx-original.cx,r.cy-original.cy)
            fun fits(r: ThumbRect)=ThumbRect(0.0,0.0,size.width,size.height).contains(r) && obstacles.all { obstacle ->
                movedHit(r).intersection(obstacle).let { it.width<=.5 || it.height<=.5 }
            }
            val candidate=if(fits(original)) original else {
                val xs=mutableListOf(original.x,0.0,size.width-f.width);val ys=mutableListOf(original.y,0.0,size.height-f.height)
                for(o in obstacles) {
                    xs+=o.x-hit.width+original.x-hit.x;xs+=o.right+original.x-hit.x
                    ys+=o.y-hit.height+original.y-hit.y;ys+=o.bottom+original.y-hit.y
                }
                xs.distinct().filter { it>=0 && it+f.width<=size.width }.flatMap { x ->
                    ys.distinct().filter { it>=0 && it+f.height<=size.height }.map { y -> ThumbRect(x,y,f.width,f.height) }
                }.filter(::fits).sortedWith { a,b ->
                    val d=hypot(a.cx-original.cx,a.cy-original.cy)-hypot(b.cx-original.cx,b.cy-original.cy)
                    if(abs(d)>.001) d.compareTo(0.0) else if(abs(a.y-b.y)>.001) a.y.compareTo(b.y) else a.x.compareTo(b.x)
                }.firstOrNull() ?: original
            }
            obstacles+=movedHit(candidate)
            if(hypot(candidate.cx-f.centerX,candidate.cy-f.centerY)>.01)
                next=LayoutControlPatch(c.id,position(candidate.cx,candidate.cy,f.width,f.height,size)).applying(next)
        }
        return next
    }
}
