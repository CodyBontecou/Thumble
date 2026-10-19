package com.thumble.android

import org.json.JSONArray
import org.json.JSONObject
import java.util.Base64

/** Canonical-profile mutation. Does not install packages, alter bindings, or send network messages. */
internal object SkinProfileLifecycle {
    private val slots = listOf("customization", "landscapeCustomization", "portraitCustomization")
    private val baselines = listOf("skinBaselineCustomization", "landscapeSkinBaselineCustomization", "portraitSkinBaselineCustomization")
    private fun copy(o: JSONObject) = JSONObject(o.toString())
    private fun orientation(layout: JSONObject): String = SkinCanvas.from(layout).let { if (it.width >= it.height) "landscape" else "portrait" }

    fun apply(profile: ControllerProfile, packageValue: SkinPackage, scheme: String, now: Long = System.currentTimeMillis()): ControllerProfile {
        require(packageValue.hasSkin && scheme in setOf("light", "dark"))
        val source = profile.source
        val result = copy(source)
        for (index in slots.indices) {
            val local = source.optJSONObject(slots[index]) ?: continue
            val previous = source.optJSONObject(baselines[index]) ?: source.optJSONObject(baselines[0])
            val direction = if (index == 0) orientation(local) else if (index == 1) "landscape" else "portrait"
            val baseline = SkinProfileResolver.apply(packageValue, local, direction, scheme, preserveLocal = false).customization
            val applied = if (previous == null) baseline else SkinProfileResolver.apply(packageValue, local, direction, scheme, baseline = previous).customization
            result.put(slots[index], dehydrate(applied, packageValue))
            result.put(baselines[index], dehydrate(baseline, packageValue))
        }
        result.put("skinReference", JSONObject().put("identifier", packageValue.reference.identifier).put("version", packageValue.reference.version))
        result.put("updatedAt", now)
        return ControllerProfile.parse(result)
    }

    fun detach(profile: ControllerProfile, packageValue: SkinPackage?, scheme: String, now: Long = System.currentTimeMillis()): ControllerProfile {
        require(scheme in setOf("light", "dark"))
        val result = copy(profile.source)
        val reference = if(packageValue==null) null else profile.source.optJSONObject("skinReference")?.let { SkinReference.parse(it) }
        for (index in slots.indices) {
            val slot = profile.source.optJSONObject(slots[index]) ?: continue
            val direction = if (index == 0) orientation(slot) else if (index == 1) "landscape" else "portrait"
            if (packageValue != null) {
                // Native detachment resolves through orientation selection, including
                // a present variant for the primary slot's canvas orientation.
                val local = copy(profile.layout(direction == "landscape"))
                local.put("colorSchemePreference", profile.source.getJSONObject("customization").optString("colorSchemePreference", "system"))
                val baseline = profile.source.optJSONObject(if (direction == "landscape") baselines[1] else baselines[2])
                    ?: profile.source.optJSONObject(baselines[0])
                result.put(slots[index], if (packageValue.reference == reference)
                    SkinProfileResolver.apply(packageValue, local, direction, scheme, baseline = baseline).customization else local)
            }
        }
        result.remove("skinReference")
        baselines.forEach(result::remove)
        result.put("updatedAt", now)
        return ControllerProfile.parse(result)
    }

    /** Visit appearance owners only; input/future element metadata is opaque. */
    private fun dehydrate(source: JSONObject, packageValue: SkinPackage): JSONObject {
        val result = copy(source)
        val assets = packageValue.assetIDs.associate { SkinText.canonicalKey(it) to packageValue.asset(it)!! }
        fun removeOwnedData(image: JSONObject, idKey: String) {
            val id = image.optString(idKey).takeIf { it.isNotEmpty() } ?: return
            val bytes = assets[SkinText.canonicalKey(id)] ?: return
            val data = image.optString("data").takeIf { it.isNotEmpty() } ?: return
            if (runCatching { Base64.getDecoder().decode(data).contentEquals(bytes) }.getOrDefault(false)) image.remove("data")
        }
        fun fill(owner: JSONObject, key: String) {
            val fill = owner.optJSONObject(key) ?: return
            if (fill.optString("kind") == "image") fill.optJSONObject("image")?.let { removeOwnedData(it,"assetID") }
        }
        fun visual(style: JSONObject) { for (state in listOf("normal","pressed","active","disabled")) style.optJSONObject(state)?.let { fill(it,"fillStyle") } }
        fun layout(layout: JSONObject) {
            for (field in listOf("fillStyle","lightFillStyle","darkFillStyle")) fill(layout,field)
            layout.optJSONObject("visualStyle")?.let(::visual)
        }
        fun each(array: JSONArray?, visit: (JSONObject) -> Unit) {
            if (array != null) repeat(array.length()) { visit(array.getJSONObject(it)) }
        }
        for (field in listOf("backgroundFillStyle","backgroundLightFillStyle","backgroundDarkFillStyle")) fill(result,field)
        each(result.optJSONArray("artworkLayers")) { fill(it,"fillStyle") }
        each(result.optJSONObject("styleLibrary")?.optJSONArray("styles")) { it.optJSONObject("visualStyle")?.let(::visual) }
        for (field in listOf("customButtons","elements")) each(result.optJSONArray(field)) { it.optJSONObject("layout")?.let(::layout) }
        result.optJSONObject("topBarActivationRegion")?.let(::layout)
        each(result.optJSONArray("controlBarItemCustomizations")) { it.optJSONObject("appearance")?.let(::layout) }
        val overrides = JSONArray()
        result.swiftMap("buttonCustomizations").toSortedMap().forEach { (id,value) ->
            if (value is JSONObject) layout(value)
            overrides.put(id).put(value)
        }
        result.put("buttonCustomizations",overrides)
        each(result.optJSONObject("assetLibrary")?.optJSONArray("assets")) { removeOwnedData(it,"id") }
        return result
    }
}
