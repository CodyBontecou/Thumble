package com.thumble.android

import org.json.JSONArray
import org.json.JSONObject
import java.util.Base64
import java.util.UUID
import kotlin.math.abs

internal fun sameSkinJSON(a: Any?,b: Any?): Boolean {
    val left=a.takeUnless { it===JSONObject.NULL };val right=b.takeUnless { it===JSONObject.NULL }
    if(left==null || right==null) return left==null && right==null
    if(left is Number && right is Number) return abs(left.toDouble()-right.toDouble())<1e-12
    if(left is JSONObject && right is JSONObject) {
        val keys=left.keys().asSequence().toSet()
        return keys==right.keys().asSequence().toSet() && keys.all { sameSkinJSON(left.opt(it),right.opt(it)) }
    }
    if(left is JSONArray && right is JSONArray) return left.length()==right.length() && (0 until left.length()).all { sameSkinJSON(left.opt(it),right.opt(it)) }
    return left==right
}

/**
 * Pure appearance stages over validated native model JSON. Returned JSON owns its
 * nested values, so a preview/editor cannot mutate the installed package or saved
 * local appearance. Full profile compatibility and model decoding are separate.
 */
internal object SkinAppearanceResolver {
    private val controlFields=listOf("styleID","shape","accentStyle","visualStyle","icon","hapticFeedback","cornerRadius","cornerRadii","shadowStrength","joystickKnobColor","joystickVisualStyle")
    private val visualFields=listOf("shape","accentStyle","fillColor","lightFillColor","darkFillColor","fillStyle","lightFillStyle","darkFillStyle",
        "joystickKnobColor","lightJoystickKnobColor","darkJoystickKnobColor","joystickVisualStyle","styleID","visualStyle","icon","hapticStyle","hapticFeedback","cornerRadius","cornerRadii","shadowStrength")
    private fun copy(value: JSONObject)=JSONObject(value.toString())
    private fun value(o: JSONObject,key: String): Any? = o.opt(key).takeUnless { it===JSONObject.NULL }
    private fun set(o: JSONObject,key: String,v: Any?) { if(v==null || v===JSONObject.NULL) o.remove(key) else o.put(key,v) }
    private fun array(o: JSONObject,key: String)=o.optJSONArray(key) ?: JSONArray()
    private fun objects(a: JSONArray)=(0 until a.length()).mapNotNull { a.optJSONObject(it) }
    private fun jsonArray(rows: Collection<JSONObject>)=JSONArray().also { a -> rows.forEach { a.put(it) } }
    private fun normalizeControl(raw: JSONObject): JSONObject = SkinModelCodec.control(raw)
    private val corners = listOf("topLeading", "topTrailing", "bottomTrailing", "bottomLeading")

    private fun normalizedRadii(raw: JSONObject): JSONObject = JSONObject().also { result ->
        for (corner in corners) result.put(corner, maxOf(0.0, raw.finite(corner, 0.0)))
    }

    // Native layouts omit redundant static defaults. Dynamic silhouettes retain
    // explicit radii because their implicit radius depends on the rendered size.
    private fun normalizeLayoutCorners(result: JSONObject) {
        val shape = result.optString("shape")
        val dynamic = shape in listOf("capsule", "circle", "ellipse")
        val defaultRadius = if (shape == "rectangle") 0.0 else 6.0
        val radii = result.optJSONObject("cornerRadii")
        if (radii != null) {
            val normalized = normalizedRadii(radii)
            val first = normalized.getDouble("topLeading")
            val uniform = corners.all { abs(normalized.getDouble(it) - first) < .001 }
            if (!dynamic && uniform && abs(first - defaultRadius) < .001) result.remove("cornerRadii")
            else result.put("cornerRadii", normalized)
            result.remove("cornerRadius")
        } else if (value(result, "cornerRadius") != null) {
            val radius = maxOf(0.0, result.finite("cornerRadius", 0.0))
            if (!dynamic && abs(radius - defaultRadius) < .001) result.remove("cornerRadius")
            else result.put("cornerRadius", radius)
        }
    }

    private fun mergeControl(base: JSONObject,overlay: JSONObject): JSONObject = copy(base).also { result ->
        val normalized=normalizeControl(overlay)
        for(key in controlFields) value(normalized,key)?.let { result.put(key,it) }
    }
    internal fun normalizeStyles(raw: JSONObject): JSONObject = SkinModelCodec.styles(
        if(raw.length()==0) JSONObject().put("styles",JSONArray()) else raw)

    internal fun normalizeAppearance(raw: JSONObject): JSONObject = copy(SkinModelCodec.appearance(raw))
    private fun mergeAppearance(base: JSONObject,overlay: JSONObject): JSONObject {
        val result=copy(base);val top=normalizeAppearance(overlay)
        for(key in listOf("backgroundFillStyle","accentStyle","showsButtonLabels")) value(top,key)?.let { result.put(key,it) }
        result.put("styleLibrary",mergeStyles(top.getJSONObject("styleLibrary"),base.getJSONObject("styleLibrary"),null,localWins=false))
        for((field,key) in listOf("roleRules" to "role","buttonRules" to "button")) {
            val rules=objects(base.getJSONArray(field)).associateByTo(linkedMapOf()) { it.getString(key) }
            for(rule in objects(top.getJSONArray(field))) {
                val id=rule.getString(key);val previous=rules[id]?.getJSONObject("appearance") ?: JSONObject()
                rules[id]=JSONObject().put(key,id).put("appearance",mergeControl(previous,rule.getJSONObject("appearance")))
            }
            result.put(field,jsonArray(rules.values))
        }
        top.optJSONObject("defaultControl")?.let { result.put("defaultControl",mergeControl(base.optJSONObject("defaultControl") ?: JSONObject(),it)) }
        val artwork=objects(base.getJSONArray("artworkLayers")).associateByTo(linkedMapOf()) { it.getString("id") }
        for(layer in objects(top.getJSONArray("artworkLayers"))) artwork[layer.getString("id")]=layer
        result.put("artworkLayers",jsonArray(artwork.values.filterNot { it.optBoolean("isHidden") }))
        return normalizeAppearance(result)
    }
    fun appearance(skin: JSONObject,orientation: String,scheme: String,actionSet: String="base"): JSONObject {
        require(orientation in listOf("portrait","landscape") && scheme in listOf("light","dark") && actionSet in listOf("base","left-trigger","right-trigger","both-triggers"))
        var result=normalizeAppearance(skin.getJSONObject("base"));val seen=mutableSetOf<String>()
        val variants=objects(array(skin,"variants")).mapNotNull { raw ->
            val id=normalizedStyleID(raw.getString("id"));if(id.isEmpty() || !seen.add(id)) null else copy(raw).put("id",id)
        }.filter { (value(it,"orientation")==null || it.getString("orientation")==orientation) &&
            (value(it,"colorScheme")==null || it.getString("colorScheme")==scheme) &&
            (value(it,"actionSet")==null || it.getString("actionSet")==actionSet) }
            .sortedWith(compareBy<JSONObject> { (if(value(it,"orientation")!=null) 1 else 0)+(if(value(it,"colorScheme")!=null) 1 else 0)+(if(value(it,"actionSet")!=null) 4 else 0) }.thenBy { it.getString("id") })
        for(variant in variants) result=mergeAppearance(result,variant.getJSONObject("appearance"))
        return result
    }
    fun controlAppearance(appearance: JSONObject,kind: String?=null,id: UUID?=null,role: String?=null): JSONObject {
        val normalized=normalizeAppearance(appearance)
        var result=normalized.optJSONObject("defaultControl")?.let(::copy) ?: JSONObject()
        val resolvedRole=role ?: when(kind) { "button" -> "custom"; "text","decoration" -> "decoration"; else -> kind }
        objects(normalized.getJSONArray("roleRules")).lastOrNull { it.getString("role")==resolvedRole }?.let { result=mergeControl(result,it.getJSONObject("appearance")) }
        if(id!=null) objects(normalized.getJSONArray("buttonRules")).lastOrNull { UUID.fromString(it.getString("button"))==id }?.let { result=mergeControl(result,it.getJSONObject("appearance")) }
        return result
    }
    fun applyControl(appearance: JSONObject,local: JSONObject,styleIcon: JSONObject?=null,preserveLocal: Boolean=true,baseline: JSONObject?=null): JSONObject {
        val skin=normalizeControl(appearance);val result=copy(local)
        visualFields.forEach(result::remove);result.put("shadowStrength",1)
        for(key in listOf("shape","cornerRadius","cornerRadii")) set(result,key,value(local,key))
        for(key in controlFields) value(skin,key)?.let { result.put(key,it) }
        set(result,"icon",skin.optJSONObject("icon") ?: skin.optJSONObject("visualStyle")?.optJSONObject("icon") ?: styleIcon ?: local.optJSONObject("icon"))
        if(value(skin,"hapticFeedback")!=null) result.remove("hapticStyle")
        value(skin,"cornerRadius")?.let { result.put("cornerRadius",it);result.remove("cornerRadii") }
        value(skin,"cornerRadii")?.let { result.put("cornerRadii",it);result.remove("cornerRadius") }
        if(preserveLocal && baseline!=null) {
            for(key in visualFields) {
                val a=value(local,key);val b=value(baseline,key)
                val changed=if(key=="shadowStrength") abs(local.finite(key,1.0)-baseline.finite(key,1.0))>=.001 else !sameSkinJSON(a,b)
                if(changed) set(result,key,a)
            }
        } else if(preserveLocal) {
            for(key in visualFields.filterNot { it in listOf("shadowStrength","cornerRadius","cornerRadii") }) value(local,key)?.let { result.put(key,it) }
            if(value(local,"cornerRadius")!=null) { result.put("cornerRadius",local.get("cornerRadius"));result.remove("cornerRadii") }
            if(value(local,"cornerRadii")!=null) { result.put("cornerRadii",local.get("cornerRadii"));result.remove("cornerRadius") }
            if(abs(local.finite("shadowStrength",1.0)-1)>=.001) result.put("shadowStrength",local.get("shadowStrength"))
        }
        result.put("shadowStrength",result.finite("shadowStrength",1.0).coerceIn(0.0,2.0))
        if(result.optString("joystickVisualStyle")=="pad") result.remove("joystickVisualStyle")
        result.optJSONObject("hapticFeedback")?.let { feedback ->
            val haptic=KeypadHaptic.parse(feedback)
            if(haptic.style=="light" && haptic.pattern=="single" && abs(haptic.intensity-.45)<.001 &&
                abs(haptic.sharpness-.48)<.001 && abs(haptic.duration-.06)<.001) result.remove("hapticFeedback")
        }
        normalizeLayoutCorners(result)
        return copy(result)
    }
    fun mergeStyles(skin: JSONObject,local: JSONObject,baseline: JSONObject?=null,localWins: Boolean=true): JSONObject {
        // During variant cascade the overlay replaces whole tokens. During
        // profile rendering only local tokens changed from baseline replace them.
        val base=if(localWins) skin else local;val overlay=if(localWins) local else skin
        val result=objects(normalizeStyles(base).getJSONArray("styles")).associateByTo(linkedMapOf()) { it.getString("id") }
        val previous=baseline?.let { objects(normalizeStyles(it).getJSONArray("styles")).associateBy { t -> t.getString("id") } }
        for(token in objects(normalizeStyles(overlay).getJSONArray("styles"))) {
            val id=token.getString("id")
            if(previous==null || !sameSkinJSON(token,previous[id])) result[id]=token
        }
        return JSONObject().put("styles",jsonArray(result.values))
    }
    private fun normalizedAssets(raw: JSONObject): List<JSONObject> {
        val seen=mutableSetOf<String>();val result=mutableListOf<JSONObject>()
        for(asset in objects(array(raw,"assets"))) {
            val id=normalizedStyleID(asset.optString("id"));val name=asset.optString("name").trim().take(64)
            if(id.isEmpty() || name.isEmpty() || !seen.add(id)) continue
            val row=copy(asset).put("id",id).put("name",name)
            value(row,"fileName")?.let { row.put("fileName",(it as String).trim()) }
            val type=row.optString("contentType").trim().ifEmpty { "application/octet-stream" }.take(80)
            row.put("contentType",type)
            value(row,"hash")?.let { row.put("hash",(it as String).trim()) }
            var size=maxOf(0,row.optInt("byteCount"))
            value(row,"data")?.let {
                val bytes=Base64.getDecoder().decode(it as String)
                if(bytes.size>2_500_000) row.remove("data") else size=bytes.size
            }
            row.put("byteCount",size)
            if(value(row,"role")==null) row.put("role","reference")
            result.add(row)
        }
        return result
    }
    fun mergeAssets(packageValue: SkinPackage,local: JSONObject,baseline: JSONObject?=null): JSONObject {
        val result=linkedMapOf<String,JSONObject>()
        val manifest=packageValue.manifestJSON()
        for(d in objects(array(manifest,"assets"))) {
            val id=d.getString("id");val data=packageValue.asset(id) ?: continue
            val name=d.getString("path").substringAfterLast('/')
            val a=JSONObject().put("id",id).put("name",name.substringBeforeLast('.',name)).put("fileName",name)
                .put("contentType",d.getString("contentType")).put("data",Base64.getEncoder().encodeToString(data))
                .put("byteCount",d.getInt("byteCount")).put("hash",d.getString("sha256")).put("role",d.getString("role"))
            result[id]=a
        }
        val previous=baseline?.let { normalizedAssets(it).associateBy { a -> a.getString("id") } }
        for(asset in normalizedAssets(local)) {
            val id=asset.getString("id")
            if(previous!=null && sameSkinJSON(asset,previous[id])) continue
            if(result[id]==null || value(asset,"data")!=null || value(result.getValue(id),"data")==null) result[id]=asset
        }
        return JSONObject().put("assets",jsonArray(normalizedAssets(JSONObject().put("assets",jsonArray(result.values)))))
    }
    fun hydrateAssets(source: JSONObject,library: JSONObject): JSONObject {
        val assets=normalizedAssets(library).associateBy { it.getString("id") }
        val result=copy(source)
        fun visit(value: Any?) {
            when(value) {
                is JSONObject -> {
                    if(value.optString("kind")=="image") value.optJSONObject("image")?.let { image ->
                        if(value(image,"data")==null) {
                            val id=normalizedStyleID(image.optString("assetID"))
                            assets[id]?.let { asset -> value(asset,"data")?.let { image.put("data",it) } }
                        }
                    }
                    for(key in value.keys()) visit(value.opt(key))
                }
                is JSONArray -> for(i in 0 until value.length()) visit(value.opt(i))
            }
        }
        visit(result)
        return result
    }
}
