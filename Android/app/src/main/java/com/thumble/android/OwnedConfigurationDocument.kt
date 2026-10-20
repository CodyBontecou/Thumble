package com.thumble.android

import org.json.JSONObject
import java.math.BigDecimal
import java.util.UUID

/** Explicit v5 reader. Original bytes remain authoritative; projections cannot be exported as v4. */
internal class OwnedConfigurationDocument private constructor(private val original: String,
    private val projections: List<String>, val activeProfileID: UUID, val defaultProfileID: UUID?) {
    fun originalData() = original.toByteArray(Charsets.UTF_8)
    fun projectedProfiles() = projections.map {
        val raw = StrictJSON.objectValue(it.toByteArray(Charsets.UTF_8))
        ControllerProfile.parse(raw).copy(name=raw.getString("name").trim())
    }
    companion object {
        const val VERSION = 5
        private val retired = listOf("skinReference","skinBaselineCustomization","landscapeSkinBaselineCustomization",
            "portraitSkinBaselineCustomization","landscapeCustomization","portraitCustomization","orientationPreference").map(::normalized)
        private val envelopeFields = listOf("schema","version","exportedAt","profiles","activeProfileID","defaultProfileID",
            "keyBindings","outputBindings","profileKeyBindings","profileOutputBindings")
        private val profileFields = listOf("id","name","updatedAt","customization","outputMode","launchTarget","appearanceBank",
            "appearanceResourceVersion","appearanceResources","profileFormatVersion")
        private val forbidden = setOf("serverid","trustedclients","authtoken","artifactversion","contenthash","catalogrevision")
        private fun normalized(value: String) = value.filter { it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' }.lowercase()
        private fun alias(key: String, known: List<String>) = known.any { it != key && normalized(it) == normalized(key) }
        private fun integer(value: Any?): Long {
            val number = value as? Number ?: error("Invalid v5 integer")
            return BigDecimal(number.toString()).longValueExact()
        }
        fun decode(data: ByteArray): OwnedConfigurationDocument {
            require(data.size <= WireCodec.MAX_PAYLOAD) { "Configuration exceeds 8 MiB" }
            val root = StrictJSON.objectValue(data)
            require(root.opt("schema") == "com.codybontecou.pocketpad.keypad-configuration" && integer(root.opt("version")) == 5L)
            root.keys().forEach { require(normalized(it) !in forbidden && !alias(it,envelopeFields)) }
            if (root.has("exportedAt")) require(integer(root.get("exportedAt")) >= 0)
            val profiles = root.getJSONArray("profiles")
            require(profiles.length() in 1..256)
            val declared = linkedMapOf<UUID, Set<UUID>>()
            val projected = (0 until profiles.length()).map { index ->
                val record = profiles.getJSONObject(index)
                require(integer(record.opt("profileFormatVersion")) == 5L && integer(record.opt("updatedAt")) >= 0)
                record.keys().forEach { require(normalized(it) !in retired && !alias(it,profileFields)) }
                val id = PortableProfileArtifact.id(record.opt("id"))
                val name = record.getString("name")
                require(name.isNotBlank() && name.codePointCount(0,name.length) <= 256)
                val layout = record.getJSONObject("customization")
                require(SkinCanvas.isCanonicalLandscapeFrameID(layout.getJSONObject("deviceCanvas").getString("frameID")))
                LayoutSnapshot.capture(layout)
                require(!record.has("outputMode") || record.isNull("outputMode") || record.getString("outputMode") in setOf("keyboard","controller","custom"))
                val copy = JSONObject(record.toString()).also { it.remove("profileFormatVersion");it.put("orientationPreference","landscape") }
                val profile = ControllerProfile.parse(copy)
                val elements = layout.getJSONArray("elements")
                val ids = (0 until elements.length()).map { PortableProfileArtifact.id(elements.getJSONObject(it).opt("id")) }.toSet()
                require(declared.put(id,ids) == null)
                val table = ProfileResourceTable.fromProfile(copy)
                val input = JSONObject().put("layout",layout)
                copy.optJSONObject("appearanceBank")?.let { input.put("bank",it) }
                val expanded = table?.expanding(input) ?: input
                PortableProfileArtifact.validateLayout(expanded.getJSONObject("layout"))
                expanded.optJSONObject("bank")?.let {
                    ProfileAppearanceBank(it).resolve(expanded.getJSONObject("layout"),"light","base")
                }
                profile.source.toString()
            }
            val active = PortableProfileArtifact.id(root.opt("activeProfileID"))
            require(root.has("defaultProfileID") && active in declared)
            val default = if (root.isNull("defaultProfileID")) null else PortableProfileArtifact.id(root.get("defaultProfileID"))
            require(default == null || default in declared)
            for ((field, output) in listOf("profileKeyBindings" to false,"profileOutputBindings" to true)) {
                if (!root.has(field)) continue
                val maps = root.getJSONObject(field)
                require(maps.length() <= 512)
                val seen = hashSetOf<UUID>()
                maps.keys().forEach { owner ->
                    val id = PortableProfileArtifact.id(owner)
                    require(seen.add(id))
                    bindings(maps.getJSONObject(owner),declared[id] ?: error("Missing binding profile"),output)
                }
            }
            for ((field, output) in listOf("keyBindings" to false,"outputBindings" to true)) {
                if (root.has(field)) bindings(root.getJSONObject(field),declared.getValue(active),output)
            }
            return OwnedConfigurationDocument(data.toString(Charsets.UTF_8),projected,active,default)
        }
        private fun bindings(map: JSONObject, declared: Set<UUID>, output: Boolean) {
            require(map.length() <= 384)
            val seen = hashSetOf<UUID>()
            map.keys().forEach { key ->
                val id = PortableProfileArtifact.id(key)
                require(seen.add(id) && id in declared)
                if (output) PortableProfileArtifact.outputBinding(map.getJSONObject(key))
                else PortableProfileArtifact.keyBinding(map.getJSONObject(key))
            }
        }
    }
}
