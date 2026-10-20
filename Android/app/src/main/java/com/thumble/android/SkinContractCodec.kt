package com.thumble.android

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import kotlin.math.abs

private typealias ContractDecoder = (Any) -> Any

/** Strict typed decoding for compatibility/captured contracts, before package validation. */
internal object SkinContractCodec {
    /** Validate an untrusted profile's native layout model without rewriting its bytes. */
    fun validateLayout(raw: JSONObject) { rawLayout(raw) }
    fun decodedLayout(raw: JSONObject): JSONObject = rawLayout(raw)
    private fun bad(): Nothing = throw SkinPackageException("invalid-skin-contract")
    private fun value(o: JSONObject,k: String): Any? = o.opt(k).takeUnless { it===JSONObject.NULL }
    private fun obj(v: Any) = v as? JSONObject ?: bad()
    private val string: ContractDecoder = { v -> (v as? String)?.takeIf(SkinText::isWellFormed) ?: bad() }
    private val number: ContractDecoder = { v -> (v as? Number)?.toDouble()?.takeIf { it.isFinite() } ?: bad() }
    private val integer: ContractDecoder = { v ->
        if(v is Byte || v is Short || v is Int || v is Long) (v as Number).toLong()
        else { val n=number(v) as Double;if(n < -9223372036854775808.0 || n>=9223372036854775808.0 || n!=n.toLong().toDouble()) bad();n.toLong() }
    }
    private val bool: ContractDecoder = { v -> v as? Boolean ?: bad() }
    private fun enum(vararg values: String): ContractDecoder = { v -> string(v).also { if(it !in values) bad() } }
    private val orientation=enum("portrait","landscape")
    private val scheme=enum("light","dark")
    private val state=enum("normal","pressed","active","disabled")
    private val role=enum("movement","primary_action","secondary_action","utility","menu","custom","joystick","trigger","trackpad","decoration","system")
    private val kind=enum("button","joystick","trigger","trackpad","text","decoration")
    private val hapticStyle=enum("none","light","medium","heavy","soft","rigid")
    private val shape=enum("rounded_rectangle","rectangle","capsule","circle","ellipse","polygon","star")
    private val accent=enum("monochrome","blue","green","purple","pink","amber")
    private val barItem=enum("status","profile_menu","launch_target","spacer","edit_layout","settings","home","connection")
    private fun list(decode: ContractDecoder): ContractDecoder = { v ->
        val a=v as? JSONArray ?: bad();JSONArray().also { r -> repeat(a.length()) { r.put(decode(a.get(it))) } }
    }
    private fun dictionary(decode: ContractDecoder): ContractDecoder = { v -> obj(v).let { source -> JSONObject().also { r -> for(k in source.keys()) r.put(k,decode(source.get(k))) } } }
    private fun fields(v: Any,required: Map<String,ContractDecoder> = emptyMap(),optional: Map<String,ContractDecoder> = emptyMap(),defaults: Map<String,Any> = emptyMap()): JSONObject {
        val source=obj(v);val result=JSONObject()
        for((k,d) in required) result.put(k,d(value(source,k) ?: bad()))
        for((k,d) in optional) { val raw=value(source,k) ?: defaults[k];if(raw!=null) result.put(k,d(raw)) }
        return result
    }
    private fun numbers(vararg keys: String)=keys.associateWith { number }
    private fun strings(vararg keys: String)=keys.associateWith { string }
    private val rawColor: ContractDecoder = { fields(it,numbers("red","green","blue","alpha")) }
    private val rawRadii: ContractDecoder = { fields(it,numbers("topLeading","topTrailing","bottomTrailing","bottomLeading")) }
    private val rect: ContractDecoder = { fields(it,numbers("x","y","width","height")) }
    private val insets: ContractDecoder = { fields(it,numbers("top","leading","bottom","trailing")) }
    private val cgRect: ContractDecoder = { v ->
        val a=v as? JSONArray ?: bad();if(a.length()<2) bad()
        JSONArray().also { r -> repeat(2) { i -> val p=a.get(i) as? JSONArray ?: bad();if(p.length()<2) bad();r.put(JSONArray().put(number(p.get(0))).put(number(p.get(1)))) } }
    }
    private val uuid: ContractDecoder = { v ->
        val s=string(v) as String
        if(!Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}").matches(s)) bad()
        UUID.fromString(s).toString().uppercase()
    }
    private fun rawIcon(v: Any): JSONObject = fields(v,mapOf("source" to enum("sf_symbol","text","asset"),"value" to string,"placement" to enum("leading","trailing","top","bottom","center","background"),"scale" to number,"renderingMode" to enum("template","multicolor","original")),mapOf("tintColor" to rawColor))
    private fun rawHaptic(v: Any): JSONObject = fields(v,mapOf("style" to hapticStyle,"pattern" to enum("single","double","pulse","buzz"))+numbers("intensity","sharpness","duration"))
    private fun rawShadow(v: Any): JSONObject {
        val result=fields(v,mapOf("color" to rawColor),numbers("radius","x","y","opacity"),mapOf("radius" to 0,"x" to 0,"y" to 0,"opacity" to 1))
        result.put("color",SkinModelCodec.color(result.getJSONObject("color")))
        if(abs(result.getDouble("opacity")-1)<=.001) result.remove("opacity")
        return result
    }
    private fun rawContent(v: Any): JSONObject {
        val pointingColors=listOf("trackpadFrameColor","trackpadCursorColor","trackpadIndicatorColor","trackpadSecondaryIndicatorColor","joystickRingColor","joystickKnobFillColor","joystickKnobStrokeColor")
        val pointing: ContractDecoder = { p -> fields(p,optional=pointingColors.associateWith { rawColor }+numbers("trackpadFrameStrokeWidth","joystickRingStrokeWidth")) }
        return fields(v,optional=mapOf("pointing" to pointing,"icon" to ::rawIcon,"legend" to string,"fontWeight" to enum("regular","medium","semibold","bold"),"fontDesign" to enum("system","rounded","serif","monospaced"),"lineLimit" to integer,"alignment" to enum("leading","center","trailing"),"labelPlacement" to enum("center","top","bottom","leading","trailing"))+
            numbers("fontSize","tracking","labelPadding","joystickKnobRatio","joystickKnobStrokeWidth")+
            listOf("trackpadFrameVisible","trackpadCursorVisible","trackpadIndicatorsVisible","joystickRingVisible").associateWith { bool })
    }
    private val paintNumbers=listOf("strokeWidth","shadowRadius","shadowX","shadowY","glowRadius","innerShadowRadius","innerShadowX","innerShadowY","highlightRadius","highlightX","highlightY","highlightOpacity","bevelWidth","indexWidth","opacity","scale","blurRadius")
    private val paintColors=listOf("foregroundColor","strokeColor","shadowColor","glowColor","innerShadowColor","highlightColor","bevelHighlightColor","bevelShadowColor","indexColor")
    private val fill: ContractDecoder = { SkinModelCodec.fill(obj(it)) }
    private fun rawState(v: Any): JSONObject = fields(v,optional=paintNumbers.associateWith { number }+paintColors.associateWith { rawColor }+
        mapOf("content" to ::rawContent,"fillStyle" to fill,"shadows" to list(::rawShadow)))
    private fun rawVisual(v: Any): JSONObject = fields(v,mapOf("normal" to ::rawState),mapOf("pressed" to ::rawState,"active" to ::rawState,"disabled" to ::rawState,"icon" to ::rawIcon,"hapticStyle" to hapticStyle,"hapticFeedback" to ::rawHaptic))
    private fun rawLayout(v: Any): JSONObject {
        val result=fields(v,optional=numbers("centerX","centerY","widthScale","heightScale","rotationDegrees","cornerRadius","shadowStrength")+
            mapOf("zIndex" to integer,"hitInsets" to insets,"shape" to shape,"accentStyle" to accent,"styleID" to string,"visualStyle" to ::rawVisual,"icon" to ::rawIcon,"hapticStyle" to hapticStyle,"hapticFeedback" to ::rawHaptic,"cornerRadii" to rawRadii,
                "joystickVisualStyle" to enum("pad","thumbstick"),"showsIntegratedLabel" to bool,"isLocationLocked" to bool,"isHidden" to bool)+
            listOf("fillColor","lightFillColor","darkFillColor","joystickKnobColor","lightJoystickKnobColor","darkJoystickKnobColor").associateWith { rawColor }+
            listOf("fillStyle","lightFillStyle","darkFillStyle").associateWith { fill },
            defaults=mapOf("widthScale" to 1,"heightScale" to 1,"rotationDegrees" to 0,"zIndex" to 0,"shadowStrength" to 1,"showsIntegratedLabel" to true,"isLocationLocked" to false,"isHidden" to false))
        result.put("zIndex",result.getLong("zIndex").coerceIn(-100,100))
        if(result.getBoolean("showsIntegratedLabel")) result.remove("showsIntegratedLabel")
        result.optJSONObject("hitInsets")?.let { h -> for(k in listOf("top","leading","bottom","trailing")) h.put(k,h.getDouble(k).coerceIn(0.0,96.0)) }
        for(k in listOf("joystickKnobColor","lightJoystickKnobColor","darkJoystickKnobColor")) result.optJSONObject(k)?.let { result.put(k,SkinModelCodec.color(it)) }
        return result
    }
    private fun resolvedPaint(v: Any): JSONObject = fields(v,mapOf("fillStyle" to fill,"foregroundColor" to rawColor,"strokeColor" to rawColor,"shadowColor" to rawColor,"shadows" to list(::rawShadow),"hapticStyle" to hapticStyle,"hapticFeedback" to ::rawHaptic)+paintNumbers.associateWith { number },
        listOf("glowColor","innerShadowColor","highlightColor","bevelHighlightColor","bevelShadowColor","indexColor").associateWith { rawColor }+mapOf("content" to ::rawContent,"icon" to ::rawIcon))
    private fun barPaint(v: Any): JSONObject {
        val item: ContractDecoder = { p -> fields(p,mapOf("schemaVersion" to integer,"surfaceID" to string,"state" to state,"requested" to ::rawLayout,
            "fallbackForeground" to rawColor,"fallbackBackground" to rawColor,"fallbackBorder" to rawColor,"rendererShape" to string,"fallbacks" to list(string))+
            numbers("fallbackBorderWidth","fallbackCornerRadius","height","horizontalPadding"),mapOf("resolvedOverride" to ::resolvedPaint,"cornerRadii" to rawRadii)) }
        val icon: ContractDecoder = { p -> fields(p,mapOf("schemaVersion" to integer,"surfaceID" to string,"resolvedSource" to string,"resolvedValue" to string,"resolvedRenderingMode" to string,"fontSize" to number,"fallbacks" to list(string)),
            mapOf("requested" to ::rawIcon,"assetSHA256" to string,"tintColor" to rawColor,"frameWidth" to number)) }
        return fields(v,mapOf("schemaVersion" to integer,"items" to dictionary(item),"icons" to dictionary(icon),"foregroundBySurfaceID" to dictionary(rawColor),"scope" to string))
    }
    private fun surfaces(v: Any): JSONObject {
        val sample: ContractDecoder = { p -> fields(p,mapOf("colorScheme" to scheme,"state" to state,"surfaceIDs" to list(string),"localFrames" to dictionary(cgRect),"effectiveFaceScale" to number,"fixedProperties" to dictionary(number))) }
        return fields(v,mapOf("schemaVersion" to integer,"samples" to list(sample),"potentialSurfaceIDs" to list(string),"supportedProperties" to dictionary(list(string)),"limitations" to list(string)))
    }
    private fun chrome(v: Any): JSONObject {
        val container: ContractDecoder = { p -> fields(p,mapOf("schemaVersion" to integer,"shape" to string,"fillColor" to rawColor,"strokeColor" to rawColor,"shadowColor" to rawColor)+numbers("strokeWidth","spacing","padding","shadowRadius","shadowY"),numbers("cornerRadius")) }
        val visibility: ContractDecoder = { p -> fields(p,listOf("isConnected","isEditing","requestedClosedResolvesOpen","requestedOpenResolvesOpen").associateWith { bool }) }
        return fields(v,mapOf("schemaVersion" to integer,"canvasFrame" to cgRect,"canvasFills" to dictionary(fill),"surfaceIDs" to list(string),"potentialSurfaceIDs" to list(string),"visibleBarItems" to list(barItem),"drawerVisibility" to list(visibility),"baselineDrawerPadding" to dictionary(number),"supportedProperties" to dictionary(list(string)),"limitations" to list(string)),
            mapOf("containerPresentation" to dictionary(container),"revealControlID" to string,"revealArtboardFrame" to cgRect,"revealSurfaces" to ::surfaces))
    }
    private fun nativeLayout(v: Any): JSONObject {
        val control: ContractDecoder = { p -> fields(p,mapOf("controlID" to string,"colorScheme" to scheme,"state" to state,"flowFrames" to dictionary(cgRect))) }
        val chrome: ContractDecoder = { p -> fields(p,mapOf("kind" to string,"colorScheme" to scheme,"isConnected" to bool,"isEditing" to bool,"frames" to dictionary(cgRect),"viewport" to cgRect),mapOf("paint" to ::barPaint,"requestedVisibility" to bool,"resolvedVisibility" to bool)) }
        return fields(v,mapOf("schemaVersion" to integer,"rendererSHA256" to string,"renderScale" to number,"controlSamples" to list(control),"chromeSamples" to list(chrome),"scope" to string))
    }
    fun presentation(v: Any): JSONObject {
        val source=obj(v)
        val names=setOf("schemaVersion","actionID","purposeID","groupIDs","legend","caption","accessibilityName")
        if(source.keys().asSequence().any { it !in names }) bad()
        val result=fields(v,optional=mapOf("schemaVersion" to integer,"groupIDs" to list(string))+strings("actionID","purposeID","legend","caption","accessibilityName"),defaults=mapOf("schemaVersion" to 1,"groupIDs" to JSONArray()))
        if(result.getLong("schemaVersion")!=1L) bad()
        fun tag(s: String)=s.isNotEmpty() && s.toByteArray(Charsets.UTF_8).size<=64 && s.all { it in 'a'..'z' || it in '0'..'9' || it in "-._" }
        for(k in listOf("actionID","purposeID")) value(result,k)?.let { if(!tag(it as String)) bad() }
        val groups=result.getJSONArray("groupIDs");val seen=mutableSetOf<String>()
        if(groups.length()>16) bad()
        repeat(groups.length()) { val s=groups.getString(it);if(!tag(s) || !seen.add(s)) bad() }
        for((k,limit) in mapOf("legend" to 64,"caption" to 128,"accessibilityName" to 128)) value(result,k)?.let {
            val s=it as String;val scalars=s.codePoints().toArray()
            if(scalars.size>limit || scalars.any { c -> c<32 || c in 127..159 }) bad()
            if(k=="accessibilityName" && SkinText.trim(s).isEmpty()) bad()
        }
        return result
    }
    private fun control(v: Any): JSONObject = fields(v,mapOf("id" to string,"label" to string,"kind" to kind,"visualRole" to role,"frame" to rect),
        mapOf("inputID" to uuid,"rotationDegrees" to number,"presentation" to ::presentation,"nativeGeometry" to { p -> fields(p,mapOf("hitFrame" to rect,"scope" to string)) },"nativeSurfaces" to ::surfaces))
    fun captured(v: Any): JSONObject {
        val variant: ContractDecoder = { p -> fields(p,mapOf("id" to string,"orientation" to orientation,"canvasWidth" to number,"canvasHeight" to number,"safeAreaInsets" to insets,"controls" to list(::control)),mapOf("nativeLayout" to ::nativeLayout,"nativeChrome" to ::chrome)) }
        return fields(v,mapOf("variants" to list(variant)))
    }
    fun compatibility(raw: JSONObject): JSONObject {
        val template: ContractDecoder = { p -> fields(p,mapOf("templateID" to string,"minimumRevision" to integer),mapOf("maximumRevision" to integer)) }
        val result=fields(raw,mapOf("mode" to enum("universal","template_aligned","captured_controller"),"templates" to list(template),"orientations" to list(orientation),"requiredRoles" to list(role),"requiredFeatures" to list(enum("action_set_layers","artwork_layers","nine_slice_images","bitmap_control_states"))),
            numbers("minimumAspectRatio","maximumAspectRatio")+mapOf("capturedGeometry" to ::captured))
        for(k in listOf("orientations","requiredRoles","requiredFeatures")) {
            val a=result.getJSONArray(k);val seen=mutableSetOf<String>();val unique=JSONArray()
            repeat(a.length()) { if(seen.add(a.getString(it))) unique.put(a.get(it)) };result.put(k,unique)
        }
        val templates=result.getJSONArray("templates");val accepted=JSONArray();val seen=mutableSetOf<String>()
        repeat(templates.length()) { index ->
            val t=templates.getJSONObject(index);val id=SkinText.prefix(SkinText.trim(t.getString("templateID")).lowercase(),80)
            val minimum=t.getLong("minimumRevision").coerceAtLeast(1)
            t.put("templateID",id).put("minimumRevision",minimum)
            value(t,"maximumRevision")?.let { t.put("maximumRevision",(it as Number).toLong().coerceAtLeast(minimum)) }
            val key="${SkinText.canonicalKey(id)}:$minimum:${value(t,"maximumRevision") ?: Long.MAX_VALUE}"
            if(id.isNotEmpty() && seen.add(key)) accepted.put(t)
        }
        result.put("templates",accepted)
        value(result,"minimumAspectRatio")?.let { result.put("minimumAspectRatio",(it as Number).toDouble().coerceIn(.25,4.0)) }
        val minimum=(value(result,"minimumAspectRatio") as? Number)?.toDouble() ?: .25
        value(result,"maximumAspectRatio")?.let { result.put("maximumAspectRatio",(it as Number).toDouble().coerceIn(minimum,4.0)) }
        return result
    }
}
