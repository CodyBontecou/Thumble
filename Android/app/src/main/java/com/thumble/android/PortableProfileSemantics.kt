package com.thumble.android

import org.json.JSONArray
import org.json.JSONObject
import org.erdtman.jcs.JsonCanonicalizer
import java.math.BigDecimal
import java.util.UUID

/** Native Codable ownership/metadata checks, independent of byte-preserving storage. */
internal object PortableProfileSemantics {
    private val barItems=setOf("status","profile_menu","launch_target","spacer","edit_layout","settings","home","connection")
    private val settingsFields=listOf("joystickMapping","joystickOutputSettings","triggerSettings","trackpadSettings")
    private fun bad(): Nothing=throw SharedBuildException("invalid-artifact")
    private fun obj(value: Any?)=value as? JSONObject ?: bad()
    private fun array(value: Any?)=value as? JSONArray ?: bad()
    private fun string(value: Any?)=value as? String ?: bad()
    private fun integer(value: Any?): Long = try { BigDecimal((value as? Number ?: bad()).toString()).longValueExact() } catch(_: ArithmeticException) { bad() }
    private fun number(value: Any?)=(value as? Number)?.toDouble()?.takeIf { it.isFinite() } ?: bad()
    private fun bool(value: Any?)=value as? Boolean ?: bad()
    private fun optional(raw: JSONObject,field: String)=raw.opt(field).takeUnless { it===JSONObject.NULL }
    private fun enumerate(value: Any?,allowed: Set<String>)=string(value).also { if(it !in allowed) bad() }
    fun kind(raw: JSONObject,field: String="kind")=optional(raw,field)?.let(::string) ?: "button"
    private fun id(value: Any?)=PortableProfileArtifact.id(value)
    private fun strings(value: Any?) { val a=array(value);repeat(a.length()) { string(a.get(it)) } }

    private fun stroke(raw: JSONObject)=JSONObject().put("keyCode",integer(raw.get("keyCode"))).put("modifiersRawValue",integer(raw.get("modifiersRawValue")))
    private fun output(raw: JSONObject): JSONObject {
        val buttons=array(raw.get("gamepadButtons"))
        val result=JSONObject().put("gamepadButtons",JSONArray((0 until buttons.length()).map { string(buttons.get(it)) }.distinct().sorted()))
        optional(raw,"keyboard")?.let { value ->
            val keyboard=obj(value);val projected=stroke(keyboard)
            optional(keyboard,"sequence")?.let { sequence ->
                val a=array(sequence);projected.put("sequence",JSONArray((0 until a.length()).map { stroke(obj(a.get(it))) }))
            }
            result.put("keyboard",projected)
        }
        return result
    }
    private fun mapping(raw: JSONObject)=JSONObject().also { result ->
        for(direction in listOf("up","down","left","right")) result.put(direction,output(obj(raw.get(direction))))
    }
    private fun same(a: JSONObject?,b: JSONObject?): Boolean {
        if(a==null || b==null) return a==null && b==null
        return JsonCanonicalizer(a.toString()).encodedUTF8.contentEquals(JsonCanonicalizer(b.toString()).encodedUTF8)
    }
    private fun settings(kind: String,field: String,raw: JSONObject?): JSONObject? {
        if(field=="joystickMapping") return if(kind=="joystick") raw?.let(::mapping) else null
        val relevant=when(field) { "joystickOutputSettings" -> "joystick";"triggerSettings" -> "trigger";else -> "trackpad" }
        if(kind!=relevant) return null
        val result=JSONObject()
        fun n(key: String,default: Double,low: Double,high: Double) { result.put(key,(raw?.let { number(it.get(key)) } ?: default).coerceIn(low,high)) }
        fun b(key: String,default: Boolean) { result.put(key,raw?.let { bool(it.get(key)) } ?: default) }
        fun s(key: String,default: String) { result.put(key,raw?.let { string(it.get(key)) } ?: default) }
        when(field) {
            "joystickOutputSettings" -> {
                s("analogTarget","none");b("sendsDigitalDirections",true)
                if(result.getString("analogTarget")=="none") result.put("sendsDigitalDirections",true)
                n("deadZone",.12,0.0,.85);n("sensitivity",1.0,.2,3.0)
                b("invertX",false);b("invertY",false);b("snapToCardinal",false)
            }
            "triggerSettings" -> {
                s("target","right");s("orientation","vertical");n("deadZone",.03,0.0,.85)
                n("sensitivity",1.0,.2,3.0);b("sendsDigitalButton",false);n("digitalThreshold",.5,.01,1.0)
            }
            else -> {
                n("sensitivity",1.2,.2,4.0);n("scrollSensitivity",.85,.1,4.0)
                b("tapToClick",true);b("twoFingerScroll",true);b("naturalScrolling",true)
            }
        }
        return result
    }
    /** Must run after strict behavior decoding. Equality excludes unknown Codable fields. */
    fun mirror(declared: JSONObject,mirror: JSONObject) {
        val kind=kind(declared)
        if(kind(mirror,"controlKind")!=kind) bad()
        for(field in settingsFields) {
            val provided=optional(mirror,field) ?: continue
            val left=if(field=="joystickMapping") mapping(obj(provided)) else settings(kind,field,obj(provided))
            val right=settings(kind,field,optional(declared,field)?.let(::obj))
            if(!same(left,right)) bad()
        }
    }

    fun profile(raw: JSONObject) {
        optional(raw,"skinReference")?.let { value ->
            val reference=obj(value);string(reference.opt("identifier"));string(reference.opt("version"))
        }
    }
    fun layout(raw: JSONObject,elements: Map<UUID,JSONObject>) {
        fun uuidMap(value: Any?) { val map=obj(value);for(key in map.keys()) id(key) }
        for(field in listOf("keyBindings","outputBindings")) optional(raw,field)?.let(::uuidMap)
        for(field in listOf("profileKeyBindings","profileOutputBindings")) optional(raw,field)?.let { value ->
            val map=obj(value);for(key in map.keys()) uuidMap(map.get(key))
        }
        optional(raw,"deviceCanvas")?.let { string(obj(it).opt("frameID")) }
        for(field in listOf("backgroundLightColor","backgroundDarkColor")) optional(raw,field)?.let { SkinModelCodec.color(obj(it)) }
        for(field in listOf("backgroundFillStyle","backgroundLightFillStyle","backgroundDarkFillStyle")) optional(raw,field)?.let { SkinModelCodec.fill(obj(it)) }
        optional(raw,"updatedAt")?.let(::integer)
        optional(raw,"controlBarItems")?.let { value -> val a=array(value);repeat(a.length()) { enumerate(a.get(it),barItems) } }
        optional(raw,"controlBarItemCustomizations")?.let { value ->
            val a=array(value);repeat(a.length()) { index ->
                val item=obj(a.get(index));enumerate(item.opt("item"),barItems)
                SkinContractCodec.validateLayout(obj(item.opt("appearance")))
            }
        }
        optional(raw,"assetLibrary")?.let { value ->
            val a=array(obj(value).opt("assets"));repeat(a.length()) { index ->
                val asset=obj(a.get(index));for(field in listOf("id","name","contentType")) string(asset.opt(field))
                integer(asset.opt("byteCount"));enumerate(asset.opt("role"),setOf("background","icon","texture","reference"))
                for(field in listOf("fileName","hash")) optional(asset,field)?.let(::string)
            }
        }
        optional(raw,"designMetadata")?.let { design(obj(it),elements) }
    }

    private fun label(value: String)=SkinText.prefix(SkinText.trim(value),12)
    private fun controlLayout(raw: JSONObject,kind: String,mirror: Boolean): JSONObject {
        val result=SkinContractCodec.decodedLayout(raw)
        for(field in listOf("centerX","centerY")) {
            optional(result,field)?.let { result.put(field,number(it).coerceIn(0.0,1.0)) }
            if(mirror && !result.has(field)) result.put(field,.5)
        }
        for(field in listOf("widthScale","heightScale")) result.put(field,result.getDouble(field).coerceIn(.001,12.0))
        var rotation=result.getDouble("rotationDegrees")%360
        if(rotation>180) rotation-=360
        if(rotation<=-180) rotation+=360
        result.put("rotationDegrees",if(kotlin.math.abs(rotation)<.001) 0.0 else rotation)
        if(kind=="joystick") result.put("shape","circle")
        else if(!result.has("shape")) result.put("shape",when(kind) { "trigger" -> "capsule";"text" -> "rectangle";else -> "rounded_rectangle" })
        if(kind=="text") result.put("showsIntegratedLabel",false).put("shadowStrength",0)
        for(field in listOf("fillColor","lightFillColor","darkFillColor","joystickKnobColor","lightJoystickKnobColor","darkJoystickKnobColor"))
            optional(result,field)?.let { result.put(field,SkinModelCodec.color(obj(it))) }
        for(field in listOf("fillStyle","lightFillStyle","darkFillStyle")) optional(result,field)?.let { result.put(field,SkinModelCodec.fill(obj(it))) }
        for((field,decode) in listOf("visualStyle" to SkinModelCodec::visual,"icon" to SkinModelCodec::icon)) optional(result,field)?.let {
            val normalized=decode(obj(it));if(normalized==null) result.remove(field) else result.put(field,normalized)
        }
        optional(result,"hapticFeedback")?.let { result.put("hapticFeedback",SkinModelCodec.haptic(obj(it))) }
        optional(result,"styleID")?.let { val normalized=normalizedStyleID(string(it));if(normalized.isEmpty()) result.remove("styleID") else result.put("styleID",normalized) }
        return SkinAppearanceResolver.applyControl(JSONObject(),result)
    }
    private fun element(raw: JSONObject): JSONObject {
        val result=JSONObject(raw.toString());val kind=kind(raw);result.put("kind",kind)
        result.put("label",label(optional(raw,"label")?.let(::string) ?: "Button").ifEmpty { when(kind) {
            "joystick" -> "Joystick";"trigger" -> if(raw.optJSONObject("triggerSettings")?.optString("target")=="left") "LT" else "RT"
            "trackpad" -> "Trackpad";"text" -> "Text";"decoration" -> "Decoration";else -> "Button"
        } })
        result.put("layout",controlLayout(raw.optJSONObject("layout") ?: JSONObject(),kind,false))
        for(field in settingsFields) {
            val projected=settings(kind,field,optional(raw,field)?.let(::obj))
            if(projected==null) result.remove(field) else result.put(field,projected)
        }
        for(field in listOf("output","defaultOutput")) optional(raw,field)?.let { result.put(field,output(obj(it))) }
        optional(raw,"presentation")?.let { result.put("presentation",SkinContractCodec.presentation(it)) }
        val parts=linkedMapOf<String,JSONObject>()
        optional(raw,"partOutputs")?.let { value -> val a=array(value);for(i in 0 until a.length() step 2) parts[string(a.get(i))]=output(obj(a.get(i+1))) }
        result.optJSONObject("joystickMapping")?.let { mapping ->
            for(direction in listOf("up","down","left","right")) parts.putIfAbsent("joystick_$direction",mapping.getJSONObject(direction))
        }
        if(kind in setOf("text","decoration")) { result.remove("output");parts.clear() }
        result.put("partOutputs",JSONArray().apply { parts.toSortedMap().forEach { (part,binding) -> put(part);put(binding) } })
        for(field in listOf("visualRole","presentation","output","defaultOutput")) if(result.isNull(field)) result.remove(field)
        result.put("id",id(result.get("id")).toString().uppercase())
        return result
    }
    /** Normalize the current executable/rendering subset; the artifact owns untouched bytes. */
    fun previewLayout(raw: JSONObject): JSONObject {
        val result=JSONObject(raw.toString());val source=raw.getJSONArray("elements")
        val declared=(0 until source.length()).map { element(source.getJSONObject(it)) }.associateByTo(linkedMapOf()) { id(it.get("id")) }
        val mirrors=raw.optJSONArray("customButtons") ?: JSONArray();val order=linkedSetOf<UUID>()
        declared.forEach { (id,e) -> if(kind(e)=="button" && id.starterSlot()!=null) order.add(id) }
        repeat(mirrors.length()) { i ->
            val mirror=mirrors.getJSONObject(i);val uuid=id(mirror.get("id"));val target=declared.getValue(uuid)
            if(uuid !in order) {
                val kind=kind(target)
                val mirroredLabel=label(optional(mirror,"label")?.let(::string) ?: "Button").ifEmpty { when(kind) {
                    "joystick" -> "Joystick";"trigger" -> if(target.optJSONObject("triggerSettings")?.optString("target")=="left") "LT" else "RT"
                    "trackpad" -> "Trackpad";"text" -> "Text";"decoration" -> "Decoration";else -> target.getString("label")
                } }
                val mirrorLayout=mirror.optJSONObject("layout") ?: JSONObject().put("shape","rounded_rectangle")
                target.put("label",mirroredLabel).put("layout",controlLayout(mirrorLayout,kind,true))
                optional(mirror,"visualRole")?.let { target.put("visualRole",it) }
                order.add(uuid)
            }
        }
        for((uuid,target) in declared) if(order.add(uuid) && !(kind(target)=="button" && uuid.starterSlot()!=null)) {
            target.put("layout",controlLayout(target.getJSONObject("layout"),kind(target),true))
        }
        result.put("elements",JSONArray(order.map(declared::getValue)))
        return result
    }

    private fun identity(value: Any?): String {
        if(value is String) {
            if(value=="top_bar_activation" || value=="system.top_bar_activation") return "system.top_bar_activation"
            for(prefix in listOf("builtin.","custom.")) if(value.startsWith(prefix)) return prefix+id(value.removePrefix(prefix))
            if(value.startsWith("control_bar_item.")) return "bar."+enumerate(value.removePrefix("control_bar_item."),barItems)
            return "builtin."+id(value)
        }
        val raw=obj(value)
        return when(string(raw.opt("kind"))) {
            "builtin" -> "builtin."+id(raw.opt("button"))
            "custom" -> "custom."+id(raw.opt("id"))
            "system" -> "system."+enumerate(optional(raw,"system") ?: raw.opt("id"),setOf("top_bar_activation"))
            "controlBarItem" -> "bar."+enumerate(raw.opt("controlBarItem"),barItems)
            else -> bad()
        }
    }
    private fun design(raw: JSONObject,elements: Map<UUID,JSONObject>) {
        integer(raw.opt("schemaVersion"))
        val available=elements.map { (id,e) ->
            (if(kind(e)=="button" && id.starterSlot()!=null) "builtin." else "custom.")+id
        }.toSet()+"system.top_bar_activation"
        fun references(value: Any?) {
            val a=array(value);val seen=mutableSetOf<String>()
            repeat(a.length()) { val key=identity(a.get(it));if(key !in available || !seen.add(key)) bad() }
        }
        references(raw.opt("layerOrder"))
        val groups=array(raw.opt("groups"));val ids=mutableSetOf<UUID>()
        repeat(groups.length()) { index ->
            val group=obj(groups.get(index));if(!ids.add(id(group.opt("id")))) bad()
            string(group.opt("name"));bool(group.opt("isLocked"));bool(group.opt("isHidden"));references(group.opt("children"))
        }
        val grid=obj(raw.opt("grid"))
        for(field in listOf("showsGrid","snapToGrid","snapToObjects")) bool(grid.opt(field))
        for(field in listOf("gridSize","snapTolerance")) number(grid.opt(field))
        val guides=array(raw.opt("guides"));repeat(guides.length()) { index ->
            val guide=obj(guides.get(index));id(guide.opt("id"));enumerate(guide.opt("orientation"),setOf("horizontal","vertical"));number(guide.opt("position"))
        }
        strings(raw.opt("tags"))
        for(field in listOf("notes","sourceTemplateID")) optional(raw,field)?.let(::string)
        optional(raw,"sourceTemplateRevision")?.let(::integer)
    }
}
