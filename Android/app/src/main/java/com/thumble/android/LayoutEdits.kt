package com.thumble.android

import org.json.JSONArray
import org.json.JSONObject
import java.math.BigDecimal
import java.util.UUID

internal enum class LayoutOrientation(val wireValue: String, val slot: String) {
    PORTRAIT("portrait", "portraitCustomization"), LANDSCAPE("landscape", "landscapeCustomization");
    companion object {
        fun parse(raw: String) = entries.firstOrNull { it.wireValue == raw }
            ?: throw IllegalArgumentException("Invalid layout orientation")
        fun of(layout: JSONObject) = SkinCanvas.from(layout).let { if (it.width >= it.height) LANDSCAPE else PORTRAIT }
    }
}

/** Immutable canonical layout bytes. Editing must never alias a received profile,
 * an undo entry, or another orientation's mutable JSONObject. */
internal class LayoutSnapshot private constructor(private val bytes: String) {
    fun json() = JSONObject(bytes)
    override fun equals(other: Any?) = other is LayoutSnapshot && bytes == other.bytes
    override fun hashCode() = bytes.hashCode()
    val orientation: LayoutOrientation get() = LayoutOrientation.of(json())
    fun oriented(orientation: LayoutOrientation): LayoutSnapshot {
        if (this.orientation == orientation) return this
        val raw = json()
        raw.put("deviceCanvas", JSONObject().put("frameID", SkinCanvas.orientedFrameID(raw, orientation == LayoutOrientation.LANDSCAPE)))
        return capture(raw)
    }
    fun stamped(now: Long): LayoutSnapshot {
        require(now >= 0)
        return capture(json().put("updatedAt", now))
    }
    fun samePresentation(other: LayoutSnapshot): Boolean = equivalent(json(), other.json(), root = true)

    companion object {
        fun capture(raw: JSONObject): LayoutSnapshot {
            val bytes = raw.toString()
            require(bytes.toByteArray(Charsets.UTF_8).size <= WireCodec.MAX_PAYLOAD) { "Layout is too large" }
            val copy = PackageJSON.objectValue(bytes.toByteArray(Charsets.UTF_8))
            // Reuse renderer parsing; these are canonical model snapshots, not
            // an arbitrary profile-import normalization boundary.
            ControllerProfile.parse(JSONObject().put("id", "00000000-0000-0000-0000-000000000001")
                .put("name", "Layout").put("customization", copy))
            val elements = copy.getJSONArray("elements")
            repeat(elements.length()) { parseLayoutUUID(elements.getJSONObject(it).getString("id")) }
            for (field in listOf("labelOverrides", "buttonCustomizations")) canonicalMap(copy.opt(field))
            return LayoutSnapshot(bytes)
        }

        fun resolved(profile: ControllerProfile, orientation: LayoutOrientation): LayoutSnapshot {
            val raw = JSONObject(profile.layout(orientation == LayoutOrientation.LANDSCAPE).toString())
            // Saved Mode belongs to the whole profile in the native model.
            raw.put("colorSchemePreference", profile.source.getJSONObject("customization").optString("colorSchemePreference", "system"))
            return capture(raw)
        }

        private fun canonicalMap(raw: Any?): Map<UUID, Any> {
            if (raw == null || raw === JSONObject.NULL) return emptyMap()
            val pairs = when (raw) {
                is JSONObject -> raw.keys().asSequence().map { it to raw.get(it) }.toList()
                is JSONArray -> {
                    require(raw.length() % 2 == 0)
                    (0 until raw.length() step 2).map { raw.getString(it) to raw.get(it + 1) }
                }
                else -> throw IllegalArgumentException("Invalid layout dictionary")
            }
            val result = linkedMapOf<UUID, Any>()
            for ((key, value) in pairs) require(result.put(parseLayoutUUID(key), value) == null) { "Duplicate layout dictionary key" }
            return result
        }

        private fun equivalent(a: Any?, b: Any?, root: Boolean = false): Boolean {
            if (a == null || a === JSONObject.NULL || b == null || b === JSONObject.NULL)
                return (a == null || a === JSONObject.NULL) && (b == null || b === JSONObject.NULL)
            if (a is Number && b is Number) return BigDecimal(a.toString()).compareTo(BigDecimal(b.toString())) == 0
            if (a is JSONObject && b is JSONObject) {
                val keys = a.keys().asSequence().toSet() - if (root) setOf("updatedAt") else emptySet()
                val other = b.keys().asSequence().toSet() - if (root) setOf("updatedAt") else emptySet()
                return keys == other && keys.all { key ->
                    if (root && key in setOf("buttonCustomizations", "labelOverrides")) {
                        val left = canonicalMap(a.opt(key)); val right = canonicalMap(b.opt(key))
                        left.keys == right.keys && left.keys.all { equivalent(left[it], right[it]) }
                    } else equivalent(a.opt(key), b.opt(key))
                }
            }
            if (a is JSONArray && b is JSONArray) return a.length() == b.length() &&
                (0 until a.length()).all { equivalent(a.get(it), b.get(it)) }
            return a == b
        }
    }
}

/** Intermediate previews never enter history. One final gesture is one Undo. */
internal class LayoutEditSession(entry: LayoutSnapshot) {
    val entrySnapshot = entry
    var committed: LayoutSnapshot = entry; private set
    var preview: LayoutSnapshot = entry; private set
    private val undo = mutableListOf<LayoutSnapshot>()
    val canUndo get() = undo.isNotEmpty()
    val undoSnapshot get() = undo.lastOrNull()
    val hasChanges get() = !committed.samePresentation(entrySnapshot)
    fun preview(value: LayoutSnapshot) { preview = value }
    fun commit(value: LayoutSnapshot): Boolean {
        preview = value
        if (value.samePresentation(committed)) return false
        undo += committed; committed = value
        return true
    }
    fun undo(): LayoutSnapshot? = if (undo.isEmpty()) null else undo.removeAt(undo.lastIndex).also { committed = it; preview = it }
    fun cancel(): LayoutSnapshot = entrySnapshot.also { undo.clear(); committed = it; preview = it }
}

internal data class LayoutEditKey(val serverID: String?, val profileID: UUID, val orientation: LayoutOrientation)

private fun parseLayoutUUID(raw: String): UUID = UUID.fromString(raw).also {
    require(it.toString().equals(raw, ignoreCase = true)) { "Invalid layout UUID" }
}
/** Immutable, local-only recovery copy. Resource tables and unknown metadata
 * survive a host deleting the profile while this phone has pending edits. */
internal class LayoutRecoveryProfile private constructor(private val bytes: String) {
    fun profile(): ControllerProfile = ControllerProfile.parse(StrictJSON.objectValue(bytes.toByteArray(Charsets.UTF_8)))
    fun json(): JSONObject = profile().source
    companion object {
        fun capture(raw: JSONObject): LayoutRecoveryProfile {
            val bytes = raw.toString()
            require(bytes.toByteArray(Charsets.UTF_8).size <= WireCodec.MAX_PAYLOAD) { "Recovery profile is too large" }
            val copy = StrictJSON.objectValue(bytes.toByteArray(Charsets.UTF_8))
            val profile = ControllerProfile.parse(copy)
            require(copy.opt("appearanceBank") is JSONObject) { "Recovery profile needs owned appearance" }
            val table = ProfileResourceTable.fromProfile(copy)
            val payload = JSONObject().put("bank",copy.getJSONObject("appearanceBank")).put("layout",profile.layout(true))
            val expanded = table?.expanding(payload) ?: payload
            ProfileAppearanceBank(expanded.getJSONObject("bank")).resolve(expanded.getJSONObject("layout"), "light", "base")
            return LayoutRecoveryProfile(bytes)
        }
    }
}

internal data class PendingLayoutEdit(val profileID: UUID, val orientation: LayoutOrientation,
    val customization: LayoutSnapshot, val updatedAt: Long, val serverID: String?,
    val recoveryProfile: LayoutRecoveryProfile? = null) {
    init {
        require(updatedAt >= 0)
        require(serverID == null || (serverID.isNotBlank() && serverID == serverID.trim() && serverID.length <= 512))
        require(customization.orientation == orientation) { "Layout canvas does not match its orientation" }
        require(recoveryProfile == null || recoveryProfile.profile().id == profileID) { "Recovery profile owner mismatch" }
    }
    val key get() = LayoutEditKey(serverID, profileID, orientation)
    fun json() = JSONObject().put("profileID", profileID.toString()).put("orientation", orientation.wireValue)
        .put("customization", customization.json()).put("updatedAt", updatedAt).put("serverID", serverID ?: JSONObject.NULL)
        .also { recoveryProfile?.let { saved -> it.put("recoveryProfile",saved.json()) } }
    companion object {
        fun create(profileID: UUID, orientation: LayoutOrientation, layout: JSONObject, now: Long, serverID: String?,
            recoveryProfile: ControllerProfile? = null) =
            PendingLayoutEdit(profileID, orientation, LayoutSnapshot.capture(layout).oriented(orientation).stamped(now), now,
                serverID?.trim()?.ifEmpty { null }, recoveryProfile?.takeIf { it.source.opt("appearanceBank") is JSONObject }
                    ?.let { LayoutRecoveryProfile.capture(it.source) })
    }
}

internal data class LayoutReconciliation(val snapshot: ProfileSnapshot, val remaining: List<PendingLayoutEdit>,
    val uploads: List<PendingLayoutEdit>, val recoveredProfileIDs: List<UUID>)

internal object LayoutEditJournal {
    private const val MAXIMUM_EDITS = 512
    fun encode(values: List<PendingLayoutEdit>) = JSONArray().also { result ->
        require(values.size <= MAXIMUM_EDITS && values.map { it.key }.distinct().size == values.size)
        values.forEach { result.put(it.json()) }
        require(result.toString().toByteArray().size <= WireCodec.MAX_PAYLOAD)
    }
    fun decode(array: JSONArray?): List<PendingLayoutEdit> {
        if (array == null) return emptyList()
        require(array.length() <= MAXIMUM_EDITS)
        val values = (0 until array.length()).map { index ->
            val raw = array.getJSONObject(index)
            val number = raw.get("updatedAt") as? Number ?: throw IllegalArgumentException("Invalid layout timestamp")
            val now = try { BigDecimal(number.toString()).longValueExact() }
                catch (error: ArithmeticException) { throw IllegalArgumentException("Invalid layout timestamp", error) }
            PendingLayoutEdit(parseLayoutUUID(raw.getString("profileID")), LayoutOrientation.parse(raw.getString("orientation")),
                LayoutSnapshot.capture(raw.getJSONObject("customization")), now,
                if (!raw.has("serverID") || raw.isNull("serverID")) null else raw.getString("serverID"),
                if (!raw.has("recoveryProfile") || raw.isNull("recoveryProfile")) null else LayoutRecoveryProfile.capture(raw.getJSONObject("recoveryProfile")))
        }
        encode(values)
        return values
    }
    fun recording(values: List<PendingLayoutEdit>, edit: PendingLayoutEdit): List<PendingLayoutEdit> {
        encode(values)
        if (values.any { it.key == edit.key && it.updatedAt > edit.updatedAt }) return values
        return (values.filterNot { it.key == edit.key } + edit).also { encode(it) }
    }
    fun applying(profile: ControllerProfile, edit: PendingLayoutEdit): ControllerProfile {
        require(profile.id == edit.profileID)
        val result = JSONObject(profile.source.toString())
        val old = result.getJSONObject("customization")
        val previousOrientation = LayoutOrientation.of(old)
        if (previousOrientation != edit.orientation && result.optJSONObject(previousOrientation.slot) == null)
            result.put(previousOrientation.slot, JSONObject(old.toString()))
        var layout = edit.customization.json()
        val recovery = edit.recoveryProfile?.json()
        recovery?.optJSONObject("appearanceResources")?.let { retained ->
            if (result.opt("appearanceBank") is JSONObject) {
                // The authority may have replaced its resource table while this
                // edit was offline. Never leave the old layout's references dangling.
                val merged = result.optJSONObject("appearanceResources") ?: JSONObject()
                val used = requireNotNull(ProfileResourceTable.fromProfile(recovery)).referencedResourceIDs(layout)
                used.forEach { digest ->
                    require(!merged.has(digest) || merged.getString(digest) == retained.getString(digest)) { "Conflicting recovery resource" }
                    merged.put(digest,retained.getString(digest))
                }
                result.put("appearanceResourceVersion",1).put("appearanceResources",merged)
            } else {
                // An explicit legacy authority/rollback has no bank envelope.
                // Keep its format and expand only this canonical layout's bytes.
                layout = requireNotNull(ProfileResourceTable.fromProfile(recovery)).expanding(layout)
            }
        }
        result.put("customization", layout).put(edit.orientation.slot, JSONObject(layout.toString()))
        result.put("updatedAt", maxOf(result.optLong("updatedAt"), edit.updatedAt))
        val checked = ProfileResourceTable.fromProfile(result)?.pruningUnused(result) ?: result
        return ControllerProfile.parse(checked)
    }
    fun reconcile(incoming: ProfileSnapshot, values: List<PendingLayoutEdit>, serverID: String?,
        canAcknowledge: Boolean, acknowledgementKeys: Set<LayoutEditKey>? = null): LayoutReconciliation {
        encode(values)
        val profiles = incoming.profiles.toMutableList()
        val remaining = mutableListOf<PendingLayoutEdit>()
        val uploads = mutableListOf<PendingLayoutEdit>()
        val recovered = linkedSetOf<UUID>()
        for (edit in values.sortedWith(compareBy<PendingLayoutEdit> { it.updatedAt }.thenBy { it.key.toString() })) {
            if (edit.serverID == null || edit.serverID != serverID?.trim()) { remaining += edit; continue }
            var index = profiles.indexOfFirst { it.id == edit.profileID }
            // Always inspect original authority, never an optimistic overlay from
            // another pending orientation in this reconciliation pass.
            val remote = incoming.profiles.firstOrNull { it.id == edit.profileID }
            // An earlier orientation's pending edit can also change the profile's
            // global Saved Mode. Keep the later edit pending if uploading that
            // earlier edit would undo its otherwise matching appearance choice.
            val workingMode = profiles.getOrNull(index)?.source?.getJSONObject("customization")?.optString("colorSchemePreference", "system")
            val remoteMode = remote?.source?.getJSONObject("customization")?.optString("colorSchemePreference", "system")
            if (remote != null && canAcknowledge && (acknowledgementKeys == null || edit.key in acknowledgementKeys) &&
                workingMode == remoteMode &&
                LayoutSnapshot.resolved(remote, edit.orientation).samePresentation(edit.customization)) continue
            if (index < 0) {
                require(profiles.size < 256) { "Cannot recover another keypad: profile limit reached" }
                profiles += edit.recoveryProfile?.profile() ?: ControllerProfile.parse(JSONObject().put("id", edit.profileID.toString())
                    .put("name", "Recovered Android Layout").put("customization", edit.customization.json()).put("updatedAt", edit.updatedAt))
                index = profiles.lastIndex; recovered += edit.profileID
            }
            profiles[index] = applying(profiles[index], edit)
            remaining += edit; uploads += edit
        }
        return LayoutReconciliation(incoming.copy(profiles = profiles), remaining, uploads, recovered.toList())
    }
}
