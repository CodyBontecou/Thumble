package com.thumble.android

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import kotlin.math.abs

internal data class SkinProfileResolution(val customization: JSONObject, val compatibility: SkinCompatibilityResult)

/** Render-only application to canonical model JSON; never persists or changes an input declaration. */
internal object SkinProfileResolver {
    private val backgroundFields = listOf("backgroundFillStyle","backgroundLightFillStyle","backgroundDarkFillStyle","backgroundLightColor","backgroundDarkColor")
    private val defaultItems = listOf("status","profile_menu","launch_target","spacer","edit_layout","settings","home","connection")
    private fun copy(o: JSONObject) = JSONObject(o.toString())
    private fun objects(a: JSONArray?) = if(a==null) emptyList() else (0 until a.length()).map { a.getJSONObject(it) }
    private fun has(o: JSONObject,key: String) = o.has(key) && !o.isNull(key)
    private fun rows(values: Collection<JSONObject>) = JSONArray().also { a -> values.forEach { a.put(it) } }
    private fun library(o: JSONObject,key: String) = o.optJSONObject(key) ?: JSONObject()

    internal fun defaultLayout() = JSONObject().put("widthScale",1).put("heightScale",1).put("rotationDegrees",0)
        .put("zIndex",0).put("shadowStrength",1).put("isLocationLocked",false).put("isHidden",false)
    internal fun defaultTopBar() = defaultLayout().put("centerX",.5).put("centerY",.115).put("zIndex",100)
        .put("shape","capsule").put("accentStyle","blue").put("cornerRadius",18).put("shadowStrength",.35)
        .put("icon",JSONObject().put("source","sf_symbol").put("value","chevron.down").put("placement","center")
            .put("scale",1).put("renderingMode","template"))

    private fun isDefault(o: JSONObject): Boolean {
        val defaults=defaultLayout().put("showsIntegratedLabel",true)
        return o.keys().asSequence().all { key ->
            val expected=defaults.opt(key)
            when {
                o.isNull(key) -> true
                expected is Number && o.opt(key) is Number -> abs(o.getDouble(key)-expected.toDouble())<.001
                else -> sameSkinJSON(o.opt(key),expected)
            }
        }
    }

    // Future element metadata and bindings are opaque input data. Native asset
    // resolution only visits appearance owners, never arbitrary JSON objects.
    private fun hydrateCustomization(source: JSONObject, assets: JSONObject): JSONObject {
        val result=copy(source)
        fun hydrate(owner: JSONObject,field: String) {
            owner.optJSONObject(field)?.let { owner.put(field,SkinAppearanceResolver.hydrateAssets(it,assets)) }
        }
        for(field in listOf("backgroundFillStyle","backgroundLightFillStyle","backgroundDarkFillStyle","styleLibrary","topBarActivationRegion")) hydrate(result,field)
        objects(result.optJSONArray("artworkLayers")).forEach { hydrate(it,"fillStyle") }
        objects(result.optJSONArray("customButtons")).forEach { hydrate(it,"layout") }
        objects(result.optJSONArray("elements")).forEach { hydrate(it,"layout") }
        objects(result.optJSONArray("controlBarItemCustomizations")).forEach { hydrate(it,"appearance") }
        val overrides=JSONArray()
        result.swiftMap("buttonCustomizations").toSortedMap().forEach { (id,value) ->
            overrides.put(id).put(if(value is JSONObject) SkinAppearanceResolver.hydrateAssets(value,assets) else value)
        }
        result.put("buttonCustomizations",overrides)
        return result
    }

    fun apply(packageValue: SkinPackage, original: JSONObject, orientation: String, scheme: String,
              preserveLocal: Boolean = true, baseline: JSONObject? = null, actionSet: String = "base"): SkinProfileResolution {
        val result=copy(original)
        val compatibility=SkinCompatibility.evaluate(packageValue.manifestJSON().optJSONObject("compatibility"),original,orientation)
        val skin=packageValue.skinJSON() ?: return SkinProfileResolution(result,compatibility)
        val appearance=SkinAppearanceResolver.appearance(skin,orientation,scheme,actionSet)
        val assets=SkinAppearanceResolver.mergeAssets(packageValue,library(original,"assetLibrary"),baseline?.let { library(it,"assetLibrary") })
        val styles=SkinAppearanceResolver.mergeStyles(appearance.getJSONObject("styleLibrary"),library(original,"styleLibrary"),baseline?.let { library(it,"styleLibrary") })
        if(assets.getJSONArray("assets").length()>0) result.put("assetLibrary",assets) else result.remove("assetLibrary")
        if(styles.getJSONArray("styles").length()>0) result.put("styleLibrary",styles) else result.remove("styleLibrary")
        val artwork=appearance.getJSONArray("artworkLayers")
        if(compatibility.allowsTemplateArtwork && artwork.length()>0) result.put("artworkLayers",artwork) else result.remove("artworkLayers")
        val mode=packageValue.manifestJSON().optJSONObject("compatibility")?.optString("mode","universal") ?: "universal"
        val aligned=mode in listOf("template_aligned","captured_controller")
        val changedBackground = if(baseline!=null) (backgroundFields+"artworkLayers").any { !sameSkinJSON(original.opt(it),baseline.opt(it)) }
            else listOf("backgroundFillStyle",if(scheme=="dark") "backgroundDarkFillStyle" else "backgroundLightFillStyle",if(scheme=="dark") "backgroundDarkColor" else "backgroundLightColor").any { has(original,it) }
        if(has(appearance,"backgroundFillStyle") && (!aligned || compatibility.allowsTemplateArtwork) && (!preserveLocal || !changedBackground)) {
            backgroundFields.forEach(result::remove)
            result.put("backgroundFillStyle",appearance.get("backgroundFillStyle"))
        }
        for((field,default) in listOf("accentStyle" to "monochrome","showsButtonLabels" to true)) {
            val changed=if(baseline!=null) !sameSkinJSON(original.opt(field),baseline.opt(field)) else !sameSkinJSON(original.opt(field) ?: default,default)
            if(has(appearance,field) && (!preserveLocal || !changed)) result.put(field,appearance.get(field))
        }
        val tokens=objects(styles.getJSONArray("styles")).associateBy { it.getString("id") }
        fun applyControl(local: JSONObject, kind: String? = null, id: UUID? = null, role: String? = null, previous: JSONObject? = null): JSONObject {
            val control=SkinAppearanceResolver.controlAppearance(appearance,kind,id,role)
            val icon=tokens[control.optString("styleID")]?.optJSONObject("visualStyle")?.optJSONObject("icon")
            return SkinAppearanceResolver.applyControl(control,local,icon,preserveLocal,previous)
        }
        val elements=objects(result.optJSONArray("elements"))
        val previousElements=baseline?.let { objects(it.optJSONArray("elements")).associateBy { e -> e.getString("id").uppercase() } }
        val localOverrides=original.swiftMap("buttonCustomizations");val previousOverrides=baseline?.swiftMap("buttonCustomizations")
        val overrides=localOverrides.toMutableMap()
        for(element in elements) {
            val id=UUID.fromString(element.getString("id"));val key=id.toString().uppercase()
            if(element.optString("kind","button")!="button" || id.starterSlot()==null) continue
            val local=localOverrides[key] as? JSONObject ?: element.optJSONObject("layout") ?: defaultLayout()
            val previous=if(baseline==null) null else previousOverrides?.get(key) as? JSONObject ?: previousElements?.get(key)?.optJSONObject("layout") ?: defaultLayout()
            val layout=applyControl(local,"button",id,element.optString("visualRole").ifEmpty { null },previous)
            element.put("layout",layout)
            if(isDefault(layout)) overrides.remove(key) else overrides[key]=layout
        }
        val pairs=JSONArray()
        overrides.toSortedMap().forEach { (id,value) -> pairs.put(id).put(value) }
        result.put("buttonCustomizations",pairs)
        val previousCustom=baseline?.let { objects(it.optJSONArray("customButtons")).associateBy { c -> c.getString("id").uppercase() } }
        val customs=objects(result.optJSONArray("customButtons"))
        for(custom in customs) {
            val id=UUID.fromString(custom.getString("id"));val key=id.toString().uppercase()
            val layout=applyControl(custom.optJSONObject("layout") ?: defaultLayout(),custom.optString("controlKind","button"),id,
                custom.optString("visualRole").ifEmpty { null },previousCustom?.get(key)?.optJSONObject("layout"))
            when(custom.optString("controlKind","button")) {
                "joystick" -> layout.put("shape","circle")
                "text" -> layout.put("shape","rectangle").put("shadowStrength",0).put("showsIntegratedLabel",false)
                "trigger" -> if(!has(layout,"shape")) layout.put("shape","capsule")
                else -> if(!has(layout,"shape")) layout.put("shape","rounded_rectangle")
            }
            custom.put("layout",layout)
            elements.firstOrNull { it.getString("id").uppercase()==key }?.put("layout",layout)
        }
        val top=applyControl(original.optJSONObject("topBarActivationRegion") ?: defaultTopBar(),role="system",
            previous=baseline?.let { it.optJSONObject("topBarActivationRegion") ?: defaultTopBar() })
        if(!has(top,"centerX")) top.put("centerX",.5)
        if(!has(top,"centerY")) top.put("centerY",.115)
        if(!has(top,"shape")) top.put("shape","capsule")
        if(sameSkinJSON(top,defaultTopBar())) result.remove("topBarActivationRegion") else result.put("topBarActivationRegion",top)
        val items=original.optJSONArray("controlBarItems")?.let { a -> (0 until a.length()).map { a.getString(it) } } ?: defaultItems
        val localBar=objects(original.optJSONArray("controlBarItemCustomizations")).associateBy { it.getString("item") }
        val previousBar=baseline?.let { objects(it.optJSONArray("controlBarItemCustomizations")).associateBy { c -> c.getString("item") } }
        val bar=mutableListOf<JSONObject>()
        for(item in items) {
            val role=if(item in listOf("profile_menu","launch_target","edit_layout","settings","home")) "utility" else "system"
            var layout=applyControl(localBar[item]?.getJSONObject("appearance") ?: defaultLayout(),role=role,
                previous=if(baseline==null) null else previousBar?.get(item)?.getJSONObject("appearance") ?: defaultLayout())
            for(field in listOf("centerX","centerY","joystickKnobColor","lightJoystickKnobColor","darkJoystickKnobColor","joystickVisualStyle")) layout.remove(field)
            layout.put("rotationDegrees",0).put("zIndex",0).put("isLocationLocked",false)
            if(item=="spacer") layout=defaultLayout().put("widthScale",layout.finite("widthScale",1.0)).put("isHidden",layout.optBoolean("isHidden"))
            if(!isDefault(layout)) bar.add(JSONObject().put("item",item).put("appearance",layout))
        }
        if(bar.isEmpty()) result.remove("controlBarItemCustomizations") else result.put("controlBarItemCustomizations",rows(bar))
        return SkinProfileResolution(hydrateCustomization(result,assets),compatibility)
    }
}
