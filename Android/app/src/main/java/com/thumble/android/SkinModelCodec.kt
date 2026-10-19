package com.thumble.android

import org.json.JSONArray
import org.json.JSONObject
import java.util.Base64
import java.util.UUID
import kotlin.math.abs
import kotlin.math.roundToInt

/** Strict native appearance-model decoding followed by the native normalization phases. */
internal object SkinModelCodec {
    private val roles=listOf("movement","primary_action","secondary_action","utility","menu","custom","joystick","trigger","trackpad","decoration","system")
    private val kinds=listOf("button","joystick","trigger","trackpad","text","decoration")
    private val accents=listOf("monochrome","blue","green","purple","pink","amber")
    private val shapes=listOf("rounded_rectangle","rectangle","capsule","circle","ellipse","polygon","star")
    private val haptics=listOf("none","light","medium","heavy","soft","rigid")
    private val contentFields=listOf("icon","legend","fontSize","fontWeight","fontDesign","tracking","lineLimit","alignment","labelPadding","labelPlacement","trackpadFrameVisible","trackpadCursorVisible","trackpadIndicatorsVisible","joystickRingVisible","joystickKnobRatio","joystickKnobStrokeWidth")
    private val pointingColors=listOf("trackpadFrameColor","trackpadCursorColor","trackpadIndicatorColor","trackpadSecondaryIndicatorColor","joystickRingColor","joystickKnobFillColor","joystickKnobStrokeColor")
    private val pointingWidths=listOf("trackpadFrameStrokeWidth","joystickRingStrokeWidth")
    private val stateColors=listOf("foregroundColor","strokeColor","shadowColor","glowColor","innerShadowColor","highlightColor","bevelHighlightColor","bevelShadowColor","indexColor")
    private val stateRanges=mapOf("strokeWidth" to (0.0 to 12.0),"shadowRadius" to (0.0 to 48.0),"shadowX" to (-64.0 to 64.0),"shadowY" to (-64.0 to 64.0),
        "glowRadius" to (0.0 to 64.0),"innerShadowRadius" to (0.0 to 64.0),"innerShadowX" to (-64.0 to 64.0),"innerShadowY" to (-64.0 to 64.0),
        "highlightRadius" to (0.0 to 64.0),"highlightX" to (-64.0 to 64.0),"highlightY" to (-64.0 to 64.0),"highlightOpacity" to (0.0 to 1.0),
        "bevelWidth" to (0.0 to 24.0),"indexWidth" to (0.0 to 12.0),"opacity" to (0.0 to 1.0),"scale" to (.5 to 1.5),"blurRadius" to (0.0 to 24.0))
    private val amber=mapOf(0xFFF6DE to 0xF5F5F5,0xFFF4CF to 0xF5F5F5,0xFFF1C1 to 0xF5F5F5,0xFFDC73 to 0xD4D4D4,0xFFC543 to 0xD4D4D4,
        0xFFA600 to 0xA3A3A3,0xFFAE00 to 0xA3A3A3,0xFF9300 to 0x737373,0xAA4D00 to 0x525252,0x561900 to 0x262626,0x2A1700 to 0x1A1A1A,
        0x361900 to 0x1F1F1F,0x502800 to 0x292929,0x5B3000 to 0x2E2E2E,0x703E00 to 0x454545,0xED9A00 to 0x878787,0xFFF3D5 to 0xEDEDED,
        0xFDE68A to 0xE5E7EB,0xD97706 to 0x9CA3AF,0x78350F to 0x374151,0xFCD34D to 0xF3F4F6,0xF59E0B to 0xD1D5DB,0x451A03 to 0x111827,
        0xFACC15 to 0xD1D5DB,0xF97316 to 0x9CA3AF,0xEAB308 to 0xD1D5DB)
    private fun bad(): Nothing = throw SkinPackageException("invalid-skin-model")
    private fun value(o: JSONObject,k: String): Any? = o.opt(k).takeUnless { it===JSONObject.NULL }
    private fun required(o: JSONObject,k: String) = value(o,k) ?: bad()
    private fun obj(v: Any?) = v as? JSONObject ?: bad()
    private fun arr(v: Any?) = v as? JSONArray ?: bad()
    private fun text(v: Any?) = (v as? String)?.takeIf(SkinText::isWellFormed) ?: bad()
    private fun number(v: Any?): Double = (v as? Number)?.toDouble()?.takeIf { it.isFinite() } ?: bad()
    private fun integer(v: Any?): Long {
        if(v is Byte || v is Short || v is Int || v is Long) return (v as Number).toLong()
        val n=number(v)
        if(n < -9223372036854775808.0 || n >= 9223372036854775808.0 || n!=n.toLong().toDouble()) bad()
        return n.toLong()
    }
    private fun boolean(v: Any?) = v as? Boolean ?: bad()
    private fun enum(v: Any?,allowed: List<String>) = text(v).also { if(it !in allowed) bad() }
    private fun array(values: Collection<Any>) = JSONArray().also { a -> values.forEach { a.put(it) } }
    private fun objects(a: JSONArray) = (0 until a.length()).map { obj(a.get(it)) }
    private fun put(o: JSONObject,k: String,v: Any?) { if(v!=null) o.put(k,v) }
    private fun trim(v: String) = SkinText.trim(v)
    private fun prefix(v: String,count: Int) = SkinText.prefix(v,count)
    private fun optionalObject(o: JSONObject,k: String,decode: (JSONObject)->JSONObject?): JSONObject? = value(o,k)?.let { decode(obj(it)) }
    private fun optionalEnum(o: JSONObject,k: String,allowed: List<String>): String? = value(o,k)?.let { enum(it,allowed) }
    private fun optionalNumber(o: JSONObject,k: String,low: Double,high: Double): Double? = value(o,k)?.let { number(it).coerceIn(low,high) }
    private fun requiredNumber(o: JSONObject,k: String,low: Double,high: Double) = number(required(o,k)).coerceIn(low,high)

    fun color(raw: JSONObject): JSONObject {
        val result=JSONObject()
        for(k in listOf("red","green","blue","alpha")) result.put(k,requiredNumber(raw,k,0.0,1.0))
        val key=(result.getDouble("red").times(255).roundToInt() shl 16) or (result.getDouble("green").times(255).roundToInt() shl 8) or result.getDouble("blue").times(255).roundToInt()
        amber[key]?.let { rgb -> result.put("red",((rgb shr 16) and 255)/255.0).put("green",((rgb shr 8) and 255)/255.0).put("blue",(rgb and 255)/255.0) }
        return result
    }
    fun icon(raw: JSONObject): JSONObject? {
        val source=enum(required(raw,"source"),listOf("sf_symbol","text","asset"));val label=trim(text(required(raw,"value")))
        val placement=enum(required(raw,"placement"),listOf("leading","trailing","top","bottom","center","background"))
        val scale=requiredNumber(raw,"scale",.2,3.0)
        val tint=optionalObject(raw,"tintColor",::color)
        val mode=enum(required(raw,"renderingMode"),listOf("template","multicolor","original"))
        if(label.isEmpty()) return null
        return JSONObject().put("source",source).put("value",prefix(label,80)).put("placement",placement).put("scale",scale).put("renderingMode",mode).also { put(it,"tintColor",tint) }
    }
    fun haptic(raw: JSONObject): JSONObject {
        val style=enum(required(raw,"style"),haptics);val pattern=enum(required(raw,"pattern"),listOf("single","double","pulse","buzz"))
        val intensity=requiredNumber(raw,"intensity",0.0,1.0);val sharpness=requiredNumber(raw,"sharpness",0.0,1.0);val duration=requiredNumber(raw,"duration",.02,.30)
        return JSONObject().put("style",style).put("pattern",if(style=="none") "single" else pattern).put("intensity",if(style=="none") 0.0 else intensity)
            .put("sharpness",if(style=="none") 0.0 else sharpness).put("duration",duration)
    }
    private fun shadow(raw: JSONObject): JSONObject {
        val c=color(obj(required(raw,"color")))
        val opacity=value(raw,"opacity")?.let { number(it).coerceIn(0.0,1.0) } ?: 1.0
        c.put("alpha",c.getDouble("alpha")*opacity)
        return JSONObject().put("color",color(c)).also { result ->
            for(k in listOf("radius","x","y")) result.put(k,value(raw,k)?.let { number(it).coerceIn(if(k=="radius") 0.0 else -96.0,96.0) } ?: 0.0)
        }
    }
    fun fill(raw: JSONObject): JSONObject {
        val kind=enum(required(raw,"kind"),listOf("solid","gradient","tile","image"))
        val payload=obj(required(raw,if(kind=="solid") "color" else kind))
        return JSONObject().put("kind",kind).put(if(kind=="solid") "color" else kind,when(kind) {
            "solid" -> color(payload);"gradient" -> gradient(payload);"tile" -> tile(payload);else -> image(payload)
        })
    }
    private fun gradient(raw: JSONObject): JSONObject {
        val type=enum(required(raw,"type"),listOf("linear","radial"));val angle=number(required(raw,"angleDegrees"))%360
        var stops=objects(arr(required(raw,"stops"))).map { stop -> JSONObject().put("offset",requiredNumber(stop,"offset",0.0,1.0)).put("color",color(obj(required(stop,"color")))) }.sortedBy { it.getDouble("offset") }
        if(stops.isEmpty()) {
            fun c(v: Double)=JSONObject().put("red",v).put("green",v).put("blue",v).put("alpha",1)
            stops=listOf(JSONObject().put("offset",0).put("color",c(.07)),JSONObject().put("offset",1).put("color",c(.07+(1-.07)*.42)))
        } else if(stops.size==1) stops=listOf(JSONObject().put("offset",0).put("color",stops[0].getJSONObject("color")),JSONObject().put("offset",1).put("color",stops[0].getJSONObject("color")))
        return JSONObject().put("type",type).put("angleDegrees",if(angle<0) angle+360 else angle).put("stops",array(stops))
    }
    private fun tile(raw: JSONObject): JSONObject = JSONObject().also { result ->
        result.put("pattern",enum(required(raw,"pattern"),listOf("dots","grid","checker","diagonal")))
        for(k in listOf("foregroundColor","backgroundColor")) result.put(k,color(obj(required(raw,k))))
        for((k,range) in mapOf("scale" to (.25 to 4.0),"spacingX" to (0.0 to 2.0),"spacingY" to (0.0 to 2.0),"opacity" to (0.0 to 1.0))) result.put(k,requiredNumber(raw,k,range.first,range.second))
        result.put("alignment",enum(required(raw,"alignment"),listOf("topLeading","top","topTrailing","leading","center","trailing","bottomLeading","bottom","bottomTrailing")))
    }
    // Foundation's non-URL Base64 behavior, verified by native oracle cases.
    // Reference: swift-foundation/Sources/FoundationEssentials/Data/Data+Base64.swift
    internal fun foundationData(encoded: String): ByteArray {
        if(encoded.isEmpty()) return byteArrayOf()
        val last=encoded.indexOfLast { it!='=' }
        if(last<0) return if(encoded.length>=4) byteArrayOf(0) else bad()
        val length=((last+4)/4)*4
        if(length>encoded.length) bad()
        val prefix=encoded.substring(0,length-4)
        if('=' in prefix) bad()
        val tail=encoded.substring(length-4,length)
        if(tail[0]=='=' || tail[1]=='=') bad()
        try {
            val head=Base64.getDecoder().decode(prefix)
            val quartet=Base64.getDecoder().decode(tail.replace('=','A'))
            val result=ByteArray(head.size+1+(if(tail[2]!='=') 1 else 0)+(if(tail[3]!='=') 1 else 0))
            head.copyInto(result);var offset=head.size;result[offset++]=quartet[0]
            if(tail[2]!='=') result[offset++]=quartet[1]
            if(tail[3]!='=') result[offset]=quartet[2]
            return result
        } catch(_: IllegalArgumentException) { bad() }
    }
    private fun image(raw: JSONObject): JSONObject = JSONObject().also { result ->
        value(raw,"assetID")?.let { normalizedStyleID(text(it)).takeIf(String::isNotEmpty)?.let { id -> result.put("assetID",id) } }
        value(raw,"data")?.let {
            val encoded=text(it)
            val data=foundationData(encoded)
            if(data.size<=2_500_000) result.put("data",Base64.getEncoder().encodeToString(data))
        }
        value(raw,"fileName")?.let { result.put("fileName",text(it)) }
        result.put("contentMode",enum(required(raw,"contentMode"),listOf("fill","fit","tile")))
        result.put("opacity",requiredNumber(raw,"opacity",0.0,1.0))
        for(k in listOf("exposure","contrast","saturation","temperature","tint","highlights","shadows")) result.put(k,requiredNumber(raw,k,-1.0,1.0))
        var mode=optionalEnum(raw,"resizingMode",listOf("scale","tile","nine_slice_stretch","nine_slice_tile"))
        val insets=optionalObject(raw,"nineSliceInsets") { o ->
            JSONObject().also { r -> for(k in listOf("top","leading","bottom","trailing")) r.put(k,requiredNumber(o,k,0.0,.49)) }
                .takeIf { it.getDouble("top")+it.getDouble("bottom")<.98 && it.getDouble("leading")+it.getDouble("trailing")<.98 }
        }
        if(mode in listOf("nine_slice_stretch","nine_slice_tile") && insets==null) mode="scale"
        put(result,"resizingMode",mode);put(result,"nineSliceInsets",insets)
    }
    private fun pointing(raw: JSONObject): JSONObject = JSONObject().also { result ->
        for(k in pointingColors) put(result,k,optionalObject(raw,k,::color))
        for(k in pointingWidths) put(result,k,optionalNumber(raw,k,0.0,12.0))
    }
    private fun contentEmpty(o: JSONObject): Boolean = contentFields.none { value(o,it)!=null } &&
        (o.optJSONObject("pointing")?.let { p -> (pointingColors+pointingWidths).none { value(p,it)!=null } } ?: true)
    fun content(raw: JSONObject): JSONObject = JSONObject().also { result ->
        put(result,"pointing",optionalObject(raw,"pointing",::pointing));put(result,"icon",optionalObject(raw,"icon",::icon))
        value(raw,"legend")?.let { v ->
            val cleaned=buildString { text(v).codePoints().forEach { scalar -> if(!SkinText.isControl(scalar)) appendCodePoint(scalar) } }
            result.put("legend",prefix(cleaned,64))
        }
        for((k,range) in mapOf("fontSize" to (8.0 to 72.0),"tracking" to (-4.0 to 12.0),"labelPadding" to (0.0 to 32.0),"joystickKnobRatio" to (.2 to .9),"joystickKnobStrokeWidth" to (0.0 to 12.0))) put(result,k,optionalNumber(raw,k,range.first,range.second))
        value(raw,"lineLimit")?.let { result.put("lineLimit",integer(it).coerceIn(1,4)) }
        for((k,values) in mapOf("fontWeight" to listOf("regular","medium","semibold","bold"),"fontDesign" to listOf("system","rounded","serif","monospaced"),"alignment" to listOf("leading","center","trailing"),"labelPlacement" to listOf("center","top","bottom","leading","trailing"))) put(result,k,optionalEnum(raw,k,values))
        for(k in listOf("trackpadFrameVisible","trackpadCursorVisible","trackpadIndicatorsVisible","joystickRingVisible")) value(raw,k)?.let { result.put(k,boolean(it)) }
    }
    private fun stateEmpty(o: JSONObject): Boolean = o.keys().asSequence().all { it=="content" && contentEmpty(o.getJSONObject(it)) }
    fun state(raw: JSONObject): JSONObject = JSONObject().also { result ->
        value(raw,"content")?.let { v -> val c=obj(v);val normalized=content(c);if(!contentEmpty(c)) result.put("content",normalized) }
        put(result,"fillStyle",optionalObject(raw,"fillStyle",::fill))
        for(k in stateColors) put(result,k,optionalObject(raw,k,::color))
        for((k,range) in stateRanges) put(result,k,optionalNumber(raw,k,range.first,range.second))
        value(raw,"shadows")?.let { v -> val all=objects(arr(v)).map(::shadow);result.put("shadows",array(all.take(8))) }
    }
    fun visual(raw: JSONObject): JSONObject? {
        val result=JSONObject().put("normal",state(obj(required(raw,"normal"))))
        for(k in listOf("pressed","active","disabled")) put(result,k,optionalObject(raw,k,::state))
        put(result,"icon",optionalObject(raw,"icon",::icon));put(result,"hapticStyle",optionalEnum(raw,"hapticStyle",haptics));put(result,"hapticFeedback",optionalObject(raw,"hapticFeedback",::haptic))
        val empty=listOf("normal","pressed","active","disabled").all { result.optJSONObject(it)?.let(::stateEmpty) ?: true } && listOf("icon","hapticStyle","hapticFeedback").none { value(result,it)!=null }
        return result.takeUnless { empty }
    }
    fun control(raw: JSONObject): JSONObject = JSONObject().also { result ->
        value(raw,"styleID")?.let { normalizedStyleID(text(it)).takeIf(String::isNotEmpty)?.let { id -> result.put("styleID",id) } }
        put(result,"shape",optionalEnum(raw,"shape",shapes));put(result,"accentStyle",optionalEnum(raw,"accentStyle",accents))
        put(result,"visualStyle",optionalObject(raw,"visualStyle",::visual));put(result,"icon",optionalObject(raw,"icon",::icon));put(result,"hapticFeedback",optionalObject(raw,"hapticFeedback",::haptic))
        value(raw,"cornerRadius")?.let { result.put("cornerRadius",number(it).coerceAtLeast(0.0)) }
        put(result,"cornerRadii",optionalObject(raw,"cornerRadii") { o -> JSONObject().also { r -> for(k in listOf("topLeading","topTrailing","bottomTrailing","bottomLeading")) r.put(k,number(required(o,k)).coerceAtLeast(0.0)) } })
        put(result,"shadowStrength",optionalNumber(raw,"shadowStrength",0.0,2.0));put(result,"joystickKnobColor",optionalObject(raw,"joystickKnobColor",::color))
        put(result,"joystickVisualStyle",optionalEnum(raw,"joystickVisualStyle",listOf("pad","thumbstick")))
    }
    fun styles(raw: JSONObject): JSONObject {
        val decoded=objects(arr(required(raw,"styles"))).map { token ->
            val id=normalizedStyleID(text(required(token,"id")));val name=trim(text(required(token,"name")))
            val applies=value(token,"appliesTo")?.let { a -> (0 until arr(a).length()).map { enum(arr(a).get(it),kinds) } } ?: kinds
            val visual=visual(obj(required(token,"visualStyle")))
            if(id.isEmpty() || name.isEmpty() || visual==null) null else JSONObject().put("id",id).put("name",prefix(name,48))
                .put("appliesTo",array(if(applies.isEmpty()) kinds else applies.distinct().sorted())).put("visualStyle",visual)
        }
        val seen=mutableSetOf<String>()
        return JSONObject().put("styles",array(decoded.filterNotNull().filter { seen.add(it.getString("id")) }))
    }
    fun artwork(raw: JSONObject): JSONObject? {
        val id=normalizedStyleID(text(required(raw,"id")))
        val result=JSONObject().put("id",id).put("plane",enum(required(raw,"plane"),listOf("underlay","overlay")))
        val frame=value(raw,"frame")?.let { o -> obj(o).let { f ->
            val w=requiredNumber(f,"width",0.0,1.0);val h=requiredNumber(f,"height",0.0,1.0)
            JSONObject().put("x",requiredNumber(f,"x",0.0,1-w)).put("y",requiredNumber(f,"y",0.0,1-h)).put("width",w).put("height",h)
        } } ?: JSONObject().put("x",0).put("y",0).put("width",1).put("height",1)
        result.put("frame",frame);put(result,"fillStyle",optionalObject(raw,"fillStyle",::fill))
        result.put("opacity",requiredNumber(raw,"opacity",0.0,1.0)).put("rotationDegrees",number(required(raw,"rotationDegrees"))%360)
            .put("blendMode",enum(required(raw,"blendMode"),listOf("normal","multiply","screen","overlay","soft_light")))
            .put("zIndex",integer(required(raw,"zIndex")).coerceIn(-10_000,10_000)).put("isHidden",boolean(required(raw,"isHidden")))
        return result.takeIf { id.isNotEmpty() }
    }
    fun appearance(raw: JSONObject): JSONObject {
        val result=JSONObject();put(result,"backgroundFillStyle",optionalObject(raw,"backgroundFillStyle",::fill));put(result,"accentStyle",optionalEnum(raw,"accentStyle",accents))
        value(raw,"showsButtonLabels")?.let { result.put("showsButtonLabels",boolean(it)) }
        put(result,"defaultControl",optionalObject(raw,"defaultControl",::control)?.takeIf { it.length()>0 })
        val roleRules=objects(arr(required(raw,"roleRules"))).map { r -> enum(required(r,"role"),roles) to control(obj(required(r,"appearance"))) }.filter { it.second.length()>0 }.toMap()
        result.put("roleRules",array(roles.mapNotNull { r -> roleRules[r]?.let { JSONObject().put("role",r).put("appearance",it) } }))
        val buttonRules=objects(arr(required(raw,"buttonRules"))).map { r ->
            val id=text(required(r,"button"));if(!Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}").matches(id)) bad()
            UUID.fromString(id).toString().uppercase() to control(obj(required(r,"appearance")))
        }.filter { it.second.length()>0 }.toMap()
        result.put("buttonRules",array(buttonRules.toSortedMap().map { (id,c) -> JSONObject().put("button",id).put("appearance",c) }))
        result.put("styleLibrary",styles(obj(required(raw,"styleLibrary"))))
        val artwork=value(raw,"artworkLayers")?.let { objects(arr(it)).mapNotNull(::artwork) }.orEmpty().associateBy { it.getString("id") }.values
            .sortedWith(compareBy<JSONObject> { it.getString("plane") }.thenBy { it.getLong("zIndex") }.thenBy { it.getString("id") })
        result.put("artworkLayers",array(artwork))
        return result
    }
    fun skin(raw: JSONObject): JSONObject {
        val base=appearance(obj(required(raw,"base")))
        val decoded=objects(arr(required(raw,"variants"))).map { v ->
            val id=normalizedStyleID(text(required(v,"id")))
            val result=JSONObject().put("id",id)
            put(result,"orientation",optionalEnum(v,"orientation",listOf("portrait","landscape")));put(result,"colorScheme",optionalEnum(v,"colorScheme",listOf("light","dark")))
            put(result,"actionSet",optionalEnum(v,"actionSet",listOf("base","left-trigger","right-trigger","both-triggers")))
            result.put("appearance",appearance(obj(required(v,"appearance"))))
            result.takeIf { id.isNotEmpty() }
        }
        val seen=mutableSetOf<String>()
        return JSONObject().put("base",base).put("variants",array(decoded.filterNotNull().filter { seen.add(it.getString("id")) }))
    }
    fun decode(kind: String,raw: JSONObject): Any? = when(kind) {
        "color" -> color(raw);"icon" -> icon(raw);"haptic" -> haptic(raw);"fill" -> fill(raw);"content" -> content(raw);"state" -> state(raw)
        "visual" -> visual(raw);"control" -> control(raw);"styleLibrary" -> styles(raw);"artwork" -> artwork(raw);"appearance" -> appearance(raw);"skin" -> skin(raw)
        else -> bad()
    }
}
