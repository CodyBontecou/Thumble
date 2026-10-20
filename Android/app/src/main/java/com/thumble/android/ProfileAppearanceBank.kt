package com.thumble.android

import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject

/** Profile-owned paint. Preparation runs on a worker; no package or geometry rules are consulted. */
internal class ProfileAppearanceBank(raw: JSONObject) {
    private val variants: Map<Pair<String, String>, JSONObject>
    private val reference: JSONObject

    init {
        require(raw.keys().asSequence().all { it in setOf("schemaVersion", "variants") } &&
            raw.opt("schemaVersion") is Number && raw.getDouble("schemaVersion") == 1.0) { "unsupported-appearance-bank" }
        val rows = AppearanceJSON.objects(raw.getJSONArray("variants"))
        require(rows.size == 8) { "incomplete-appearance-bank" }
        val states = linkedMapOf<Pair<String, String>, JSONObject>()
        for (row in rows) {
            val key = row.getString("colorScheme") to row.getString("actionSet")
            require(key.first in schemes && key.second in actions && key !in states) { "invalid-appearance-state" }
            val appearance = AppearanceJSON.objectCopy(row.getJSONObject("appearance"))
            validate(appearance)
            states[key] = appearance
        }
        reference = states.getValue("light" to "base")
        val ids = reference.getJSONObject("controls").keys().asSequence().toSet()
        require(states.values.all { it.getJSONObject("controls").keys().asSequence().toSet() == ids }) { "inconsistent-appearance-controls" }
        variants = states
    }

    /** Three-way edit merge against saved light/Base; all nonappearance fields come from current. */
    fun resolve(current: JSONObject, scheme: String, action: String = "base"): JSONObject {
        require(scheme in schemes && action in actions) { "invalid-appearance-state" }
        val target = variants.getValue(scheme to action)
        val edited = snapshot(current)
        val merged = AppearanceJSON.objectCopy(target)
        for (field in surfaceFields) choose(merged, field, edited, reference, target)
        merged.put("artworkLayers", collection(edited.optJSONArray("artworkLayers"), reference.optJSONArray("artworkLayers"),
            target.optJSONArray("artworkLayers")) { e, b, t -> fields(e, b, t) })
        merged.put("controls", controls(edited.getJSONObject("controls"), reference.getJSONObject("controls"),
            target.getJSONObject("controls"), scheme, merged.optString("accentStyle", "monochrome")))
        merged.put("topBar", control(edited.getJSONObject("topBar"), reference.getJSONObject("topBar"),
            target.getJSONObject("topBar"), scheme, merged.optString("accentStyle", "monochrome")))
        merged.put("controlBar", controls(edited.getJSONObject("controlBar"), reference.getJSONObject("controlBar"),
            target.getJSONObject("controlBar"), scheme, merged.optString("accentStyle", "monochrome")))
        for ((library, entries) in listOf("styleLibrary" to "styles", "assetLibrary" to "assets")) {
            val items = collection(edited.optJSONObject(library)?.optJSONArray(entries), reference.optJSONObject(library)?.optJSONArray(entries),
                target.optJSONObject(library)?.optJSONArray(entries)) { e, b, t ->
                if (library == "assetLibrary") picked(e, b, t) as JSONObject else fields(e, b, t, mapOf("visualStyle" to ::visual))
            }
            merged.put(library, JSONObject().put(entries, items))
        }
        return applying(current, merged)
    }

    private fun validate(snapshot: JSONObject) {
        require(snapshot.keys().asSequence().all { it in snapshotFields }) { "invalid-appearance-field" }
        val controls = snapshot.getJSONObject("controls")
        require(controls.length() <= 2048 && controls.keys().asSequence().all {
            runCatching { UUID.fromString(it).toString() == it }.getOrDefault(false)
        }) { "invalid-appearance-control-id" }
        val bars = snapshot.getJSONObject("controlBar")
        require(bars.keys().asSequence().all { it in barItems }) { "invalid-appearance-bar" }
        (controls.keys().asSequence().map { controls.getJSONObject(it) } +
            sequenceOf(snapshot.getJSONObject("topBar")) + bars.keys().asSequence().map { bars.getJSONObject(it) }).forEach { control ->
            require(control.keys().asSequence().all { it in controlFields }) { "invalid-control-appearance-field" }
        }
        require(snapshot.optString("accentStyle") in setOf("monochrome", "blue", "green", "purple", "pink", "amber") &&
            snapshot.opt("showsButtonLabels") is Boolean) { "invalid-appearance-surface" }
        val assets = AppearanceJSON.objects(snapshot.getJSONObject("assetLibrary").getJSONArray("assets"))
            .filter { (it.opt("data") as? String)?.isNotEmpty() == true }.map { it.getString("id") }.toSet()
        // Resource envelopes are expanded and validated before construction. Asset references
        // without inline bytes must resolve within this state, including nested icons/effects.
        fun visit(node: Any) {
            when (node) {
                is JSONObject -> {
                    require(!node.has("resourceSHA256")) { "unexpanded-appearance-resource" }
                    if (node.optString("kind") == "image") node.optJSONObject("image")?.let { image ->
                        val id = image.optString("assetID")
                        require(id.isEmpty() || (image.opt("data") as? String)?.isNotEmpty() == true || id in assets) { "missing-appearance-asset:$id" }
                    }
                    if (node.optString("source") == "asset") require(node.optString("value") in assets) { "missing-appearance-icon" }
                    node.keys().forEach { visit(node.get(it)) }
                }
                is JSONArray -> repeat(node.length()) { visit(node.get(it)) }
            }
        }
        visit(snapshot)
    }

    internal fun snapshot(layout: JSONObject): JSONObject {
        val result = JSONObject()
        for (field in surfaceFields) AppearanceJSON.set(result, field, AppearanceJSON.value(layout, field) ?: when (field) {
            "accentStyle" -> "monochrome"; "showsButtonLabels" -> true; else -> null
        })
        result.put("artworkLayers", normalizedArtwork(layout.optJSONArray("artworkLayers")))
        for ((field, entries) in listOf("styleLibrary" to "styles", "assetLibrary" to "assets"))
            result.put(field, AppearanceJSON.copy(layout.optJSONObject(field) ?: JSONObject().put(entries, JSONArray())))
        val controls = JSONObject(); val overrides = layout.swiftMap("buttonCustomizations")
        for (element in AppearanceJSON.objects(layout.optJSONArray("elements"))) {
            val id = UUID.fromString(element.getString("id"))
            val value = if (element.optString("kind", "button") == "button" && id.starterSlot() != null)
                overrides[id.toString().uppercase()] as? JSONObject else null
            controls.put(id.toString(), controlSnapshot(value ?: element.optJSONObject("layout") ?: JSONObject()))
        }
        result.put("controls", controls)
        result.put("topBar", controlSnapshot(layout.optJSONObject("topBarActivationRegion") ?: defaultTopBar()))
        result.put("controlBar", JSONObject().also { bars ->
            AppearanceJSON.objects(layout.optJSONArray("controlBarItemCustomizations")).forEach {
                val paint = controlSnapshot(it.getJSONObject("appearance"))
                if (!AppearanceJSON.same(paint, controlSnapshot(JSONObject()))) bars.put(it.getString("item"), paint)
            }
        })
        return result
    }

    private fun controlSnapshot(layout: JSONObject) = JSONObject().also { result ->
        for (field in controlFields) AppearanceJSON.set(result, field, AppearanceJSON.value(layout, field))
        if (!result.has("shadowStrength")) result.put("shadowStrength", 1)
        if (result.optBoolean("showsIntegratedLabel", true)) result.remove("showsIntegratedLabel")
        if (result.optString("joystickVisualStyle") == "pad") result.remove("joystickVisualStyle")
    }

    private fun applying(current: JSONObject, paint: JSONObject): JSONObject {
        val result = AppearanceJSON.objectCopy(current)
        for (field in snapshotFields - setOf("controls", "topBar", "controlBar"))
            AppearanceJSON.set(result, field, AppearanceJSON.value(paint, field))
        fun apply(local: JSONObject, style: JSONObject): JSONObject = AppearanceJSON.objectCopy(local).also { output ->
            for (field in controlFields) AppearanceJSON.set(output, field, AppearanceJSON.value(style, field))
        }
        val controls = paint.getJSONObject("controls"); val overrides = result.swiftMap("buttonCustomizations").toMutableMap()
        val customs = AppearanceJSON.objects(result.optJSONArray("customButtons")).associateBy { UUID.fromString(it.getString("id")).toString() }
        for (element in AppearanceJSON.objects(result.optJSONArray("elements"))) {
            val id = UUID.fromString(element.getString("id")); val style = controls.optJSONObject(id.toString()) ?: continue
            val isBuiltin = element.optString("kind", "button") == "button" && id.starterSlot() != null
            val local = (if (isBuiltin) overrides[id.toString().uppercase()] as? JSONObject else null)
                ?: element.optJSONObject("layout") ?: JSONObject()
            val layout = apply(local, style)
            element.put("layout", layout)
            if (isBuiltin) overrides[id.toString().uppercase()] = AppearanceJSON.objectCopy(layout)
            customs[id.toString()]?.put("layout", AppearanceJSON.objectCopy(layout))
        }
        result.put("buttonCustomizations", JSONArray().also { pairs -> overrides.toSortedMap().forEach { (id, value) -> pairs.put(id).put(value) } })
        result.put("topBarActivationRegion", apply(result.optJSONObject("topBarActivationRegion") ?: defaultTopBar(), paint.getJSONObject("topBar")))
        val oldBars = AppearanceJSON.objects(result.optJSONArray("controlBarItemCustomizations")).associateBy { it.getString("item") }
        val bars = paint.getJSONObject("controlBar")
        // Preserve retained bar membership and opaque metadata; only replace paint on its owners.
        val items = result.optJSONArray("controlBarItems")?.let { array -> (0 until array.length()).map { array.getString(it) } } ?: barItems
        result.put("controlBarItemCustomizations", AppearanceJSON.rows(items.map { item ->
            val old = oldBars[item]
            (old?.let(AppearanceJSON::objectCopy) ?: JSONObject().put("item", item)).put("appearance",
                apply(old?.optJSONObject("appearance") ?: JSONObject(), bars.optJSONObject(item) ?: controlSnapshot(JSONObject())))
        }))
        result.put("artworkLayers", normalizedArtwork(result.optJSONArray("artworkLayers")))
        return result
    }

    private fun normalizedArtwork(layers: JSONArray?): JSONArray = AppearanceJSON.rows(AppearanceJSON.objects(layers)
        .filterNot { it.optBoolean("isHidden", false) }
        .sortedWith(compareBy<JSONObject> { it.optString("plane", "underlay") }.thenBy { it.optDouble("zIndex", 0.0) }.thenBy { it.getString("id") }))

    private fun controls(edited: JSONObject, baseline: JSONObject, target: JSONObject, scheme: String, accent: String): JSONObject {
        val result = AppearanceJSON.objectCopy(target)
        baseline.keys().forEach { id ->
            val current = edited.optJSONObject(id)
            if (current == null) result.remove(id) else {
                val original = baseline.getJSONObject(id); val destination = target.optJSONObject(id)
                if (destination != null) result.put(id, control(current, original, destination, scheme, accent))
                else if (!AppearanceJSON.same(current, original)) result.put(id, AppearanceJSON.objectCopy(current))
            }
        }
        edited.keys().asSequence().filterNot(baseline::has).forEach { id ->
            result.put(id, target.optJSONObject(id)?.let { control(edited.getJSONObject(id), controlSnapshot(JSONObject()), it, scheme, accent) }
                ?: AppearanceJSON.objectCopy(edited.getJSONObject(id)))
        }
        return result
    }

    private fun control(edited: JSONObject, baseline: JSONObject, target: JSONObject, scheme: String, accent: String): JSONObject {
        val result = fields(edited, baseline, target)
        AppearanceJSON.set(result, "visualStyle", visual(edited.optJSONObject("visualStyle"), baseline.optJSONObject("visualStyle"),
            if (AppearanceJSON.same(edited.opt("styleID"), baseline.opt("styleID"))) target.optJSONObject("visualStyle") else null))
        val relevant = listOf("fillColor", "fillStyle", "${scheme}FillColor", "${scheme}FillStyle")
        if (relevant.any { !AppearanceJSON.same(edited.opt(it), baseline.opt(it)) }) {
            fun effectiveFill(value: JSONObject): JSONObject {
                val direct = AppearanceJSON.objectCopy(value).apply { remove("visualStyle"); remove("styleID") }
                return ControlPresentation.resolve(Control(UUID(0, 0), "", "button", direct, "standard"),
                    JSONObject().put("accentStyle", accent), PresentationState.NORMAL, scheme == "dark").getJSONObject("fillStyle")
            }
            val fill = effectiveFill(edited)
            if (!AppearanceJSON.same(fill, effectiveFill(baseline))) {
                val visual = result.optJSONObject("visualStyle") ?: JSONObject().also { result.put("visualStyle", it) }
                val normal = visual.optJSONObject("normal") ?: JSONObject().also { visual.put("normal", it) }
                normal.put("fillStyle", fill)
            }
        }
        val icon = edited.optJSONObject("icon")
        if (icon != null && !AppearanceJSON.same(icon, baseline.opt("icon"))) {
            val visual = result.optJSONObject("visualStyle") ?: JSONObject().also { result.put("visualStyle", it) }
            for (name in listOf("normal", "pressed", "active", "disabled")) {
                val state = visual.optJSONObject(name) ?: JSONObject().also { visual.put(name, it) }
                val content = state.optJSONObject("content") ?: JSONObject().also { state.put("content", it) }
                content.put("icon", AppearanceJSON.objectCopy(icon))
            }
        }
        return result
    }

    private fun picked(edited: Any?, baseline: Any?, target: Any?) = AppearanceJSON.copy(if (AppearanceJSON.same(edited, baseline)) target else edited)
    private fun choose(result: JSONObject, key: String, edited: JSONObject, baseline: JSONObject, target: JSONObject) =
        AppearanceJSON.set(result, key, picked(AppearanceJSON.value(edited, key), AppearanceJSON.value(baseline, key), AppearanceJSON.value(target, key)))

    private fun fields(edited: JSONObject, baseline: JSONObject, target: JSONObject,
                       nested: Map<String, (JSONObject?, JSONObject?, JSONObject?) -> JSONObject?> = emptyMap()): JSONObject {
        val result = AppearanceJSON.objectCopy(target)
        (edited.keys().asSequence() + baseline.keys().asSequence()).toSet().forEach { key ->
            val merge = nested[key]
            AppearanceJSON.set(result, key, if (merge == null) picked(AppearanceJSON.value(edited, key), AppearanceJSON.value(baseline, key), AppearanceJSON.value(target, key))
                else merge(edited.optJSONObject(key), baseline.optJSONObject(key), target.optJSONObject(key)))
        }
        return result
    }
    private fun optional(edited: JSONObject?, baseline: JSONObject?, target: JSONObject?,
                         nested: Map<String, (JSONObject?, JSONObject?, JSONObject?) -> JSONObject?> = emptyMap()): JSONObject? {
        if (AppearanceJSON.same(edited, baseline)) return target?.let(AppearanceJSON::objectCopy)
        if (edited == null) return null
        return fields(edited, baseline ?: JSONObject(), target ?: JSONObject(), nested)
    }
    private fun visual(e: JSONObject?, b: JSONObject?, t: JSONObject?): JSONObject? =
        optional(e, b, t, listOf("normal", "pressed", "active", "disabled").associateWith { ::state })?.also {
            if (it.optJSONObject("normal") == null) it.put("normal", JSONObject())
        }
    private fun state(e: JSONObject?, b: JSONObject?, t: JSONObject?): JSONObject? = optional(e, b, t, mapOf("content" to ::content))
    private fun content(e: JSONObject?, b: JSONObject?, t: JSONObject?): JSONObject? = optional(e, b, t,
        mapOf("pointing" to { edited, baseline, target -> optional(edited, baseline, target) }))

    /** Native identity/order merge: preserve variant-only slots and never resurrect unchanged removed entries. */
    private fun collection(edited: JSONArray?, baseline: JSONArray?, target: JSONArray?, merge: (JSONObject, JSONObject, JSONObject) -> JSONObject): JSONArray {
        val e = AppearanceJSON.objects(edited); val b = AppearanceJSON.objects(baseline); val t = AppearanceJSON.objects(target)
        if (AppearanceJSON.same(edited ?: JSONArray(), baseline ?: JSONArray())) return AppearanceJSON.copy(target ?: JSONArray()) as JSONArray
        if (AppearanceJSON.same(target ?: JSONArray(), baseline ?: JSONArray()) || e.isEmpty()) return AppearanceJSON.copy(edited ?: JSONArray()) as JSONArray
        fun keyed(items: List<JSONObject>): Map<String, JSONObject> = items.associateBy { it.getString("id") }.also {
            require(it.size == items.size) { "duplicate-appearance-entry" }
        }
        val eb = keyed(e); val bb = keyed(b); keyed(t)
        val result = mutableListOf<JSONObject>(); val seen = mutableSetOf<String>()
        for (item in t) {
            val id = item.getString("id"); seen.add(id)
            if (id in bb) { if (id in eb) result.add(merge(eb.getValue(id), bb.getValue(id), item)) }
            else result.add(AppearanceJSON.objectCopy(eb[id] ?: item))
        }
        for (item in e) if (seen.add(item.getString("id")) && !AppearanceJSON.same(bb[item.getString("id")], item))
            result.add(AppearanceJSON.objectCopy(item))
        val common = bb.keys.intersect(eb.keys)
        if (b.map { it.getString("id") }.filter(common::contains) != e.map { it.getString("id") }.filter(common::contains) || !bb.keys.containsAll(eb.keys)) {
            val byID = result.associateBy { it.getString("id") }; val reordered = e.mapNotNull { byID[it.getString("id")] }.iterator()
            return AppearanceJSON.rows(result.map { if (it.getString("id") in eb && reordered.hasNext()) reordered.next() else it })
        }
        return AppearanceJSON.rows(result)
    }

    companion object {
        val schemes = listOf("light", "dark")
        val actions = listOf("base", "left-trigger", "right-trigger", "both-triggers")
        private val surfaceFields = setOf("backgroundLightColor", "backgroundDarkColor", "backgroundFillStyle", "backgroundLightFillStyle",
            "backgroundDarkFillStyle", "accentStyle", "showsButtonLabels")
        private val snapshotFields = surfaceFields + setOf("artworkLayers", "controls", "topBar", "controlBar", "styleLibrary", "assetLibrary")
        private val controlFields = setOf("shape", "accentStyle", "fillColor", "lightFillColor", "darkFillColor", "fillStyle", "lightFillStyle", "darkFillStyle",
            "joystickKnobColor", "lightJoystickKnobColor", "darkJoystickKnobColor", "joystickVisualStyle", "styleID", "visualStyle", "icon", "hapticStyle",
            "hapticFeedback", "cornerRadius", "cornerRadii", "shadowStrength", "showsIntegratedLabel")
        private val barItems = listOf("status", "profile_menu", "launch_target", "spacer", "edit_layout", "settings", "home", "connection")
        private fun defaultTopBar() = JSONObject().put("centerX", .5).put("centerY", .115).put("zIndex", 100).put("shape", "capsule").put("accentStyle", "blue").put("cornerRadius", 18).put("shadowStrength", .35)
            .put("icon", JSONObject().put("source", "sf_symbol").put("value", "chevron.down").put("placement", "center").put("scale", 1).put("renderingMode", "template"))
    }
}
