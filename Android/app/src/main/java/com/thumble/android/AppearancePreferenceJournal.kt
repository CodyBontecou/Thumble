package com.thumble.android

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** A profile appearance choice, independent of the phone's application theme. */
internal enum class AppearancePreference(val wireValue: String, val label: String) {
    SYSTEM("system", "System"), LIGHT("light", "Light"), DARK("dark", "Dark");

    fun isDark(systemDark: Boolean) = when (this) { SYSTEM -> systemDark; LIGHT -> false; DARK -> true }
    companion object {
        fun parse(value: String) = entries.firstOrNull { it.wireValue == value }
            ?: throw IllegalArgumentException("Invalid keypad appearance")
        fun forProfile(profile: ControllerProfile): AppearancePreference =
            runCatching { parse(profile.source.getJSONObject("customization").optString("colorSchemePreference", "system")) }.getOrDefault(SYSTEM)
    }
}

/** Immutable recovery bytes preserve an offline profile if the Mac deletes it. */
internal data class PendingAppearancePreference(
    val profileID: UUID, val preference: AppearancePreference, val updatedAt: Long,
    val serverID: String?, private val recoveryProfileJSON: String
) {
    init {
        require(updatedAt >= 0)
        require(serverID == null || (serverID.isNotBlank() && serverID == serverID.trim() && serverID.length <= 512))
        require(recoveryProfileJSON.toByteArray().size <= WireCodec.MAX_PAYLOAD)
        require(ControllerProfile.parse(JSONObject(recoveryProfileJSON)).id == profileID)
    }
    fun recoveredProfile(): ControllerProfile = ControllerProfile.parse(JSONObject(recoveryProfileJSON))
    fun json() = JSONObject().put("profileID", profileID.toString()).put("preference", preference.wireValue)
        .put("updatedAt", updatedAt).put("serverID", serverID ?: JSONObject.NULL).put("recoveryProfile", JSONObject(recoveryProfileJSON))
    companion object {
        fun create(profile: ControllerProfile, preference: AppearancePreference, updatedAt: Long, serverID: String?) =
            PendingAppearancePreference(profile.id, preference, updatedAt, serverID?.trim()?.ifEmpty { null }, profile.source.toString())
    }
}

internal data class AppearanceReconciliation(
    val snapshot: ProfileSnapshot, val remaining: List<PendingAppearancePreference>,
    val uploads: List<PendingAppearancePreference>, val recoveredProfileIDs: List<UUID>
)

/** Local choices survive reconnect until the same trusted Mac echoes their value.
 * Reapply only the appearance delta; unrelated new Mac layout/binding fields win. */
internal object AppearancePreferenceJournal {
    private const val MAXIMUM_EDITS = 256
    fun decode(array: JSONArray?): List<PendingAppearancePreference> {
        if (array == null) return emptyList()
        require(array.length() <= MAXIMUM_EDITS)
        val keys = hashSetOf<Pair<String?, UUID>>()
        return (0 until array.length()).map { index ->
            val value = array.getJSONObject(index)
            val stamp = value.get("updatedAt") as? Number ?: error("Invalid appearance timestamp")
            val timestamp = try { java.math.BigDecimal(stamp.toString()).longValueExact() }
                catch (error: ArithmeticException) { throw IllegalArgumentException("Invalid appearance timestamp", error) }
            val edit = PendingAppearancePreference(UUID.fromString(value.getString("profileID")),
                AppearancePreference.parse(value.getString("preference")), timestamp,
                if (!value.has("serverID") || value.isNull("serverID")) null else value.getString("serverID"),
                value.getJSONObject("recoveryProfile").toString())
            require(keys.add(edit.serverID to edit.profileID)) { "Duplicate pending appearance" }
            edit
        }
    }
    fun encode(values: List<PendingAppearancePreference>): JSONArray {
        require(values.size <= MAXIMUM_EDITS)
        require(values.map { it.serverID to it.profileID }.distinct().size == values.size)
        return JSONArray().also { array -> values.forEach { array.put(it.json()) } }
    }
    fun recording(values: List<PendingAppearancePreference>, edit: PendingAppearancePreference): List<PendingAppearancePreference> =
        (values.filterNot { it.profileID == edit.profileID && it.serverID == edit.serverID } + edit).also { encode(it) }

    fun applying(profile: ControllerProfile, edit: PendingAppearancePreference): ControllerProfile {
        require(profile.id == edit.profileID)
        val source = JSONObject(profile.source.toString())
        val primary = source.getJSONObject("customization")
        primary.put("colorSchemePreference", edit.preference.wireValue)
        primary.put("updatedAt", maxOf(primary.optLong("updatedAt"), edit.updatedAt))
        source.put("updatedAt", maxOf(source.optLong("updatedAt"), edit.updatedAt))
        return ControllerProfile.parse(source)
    }

    fun reconcile(incoming: ProfileSnapshot, values: List<PendingAppearancePreference>,
        authoritativeServerID: String?, canAcknowledge: Boolean, acknowledgeProfileIDs: Set<UUID>? = null): AppearanceReconciliation {
        encode(values)
        val profiles = incoming.profiles.toMutableList()
        val remaining = mutableListOf<PendingAppearancePreference>()
        val uploads = mutableListOf<PendingAppearancePreference>()
        val recovered = mutableListOf<UUID>()
        for (edit in values.sortedBy { it.updatedAt }) {
            if (edit.serverID == null || edit.serverID != authoritativeServerID?.trim()) {
                remaining += edit; continue
            }
            var index = profiles.indexOfFirst { it.id == edit.profileID }
            if (index >= 0 && canAcknowledge && (acknowledgeProfileIDs==null || edit.profileID in acknowledgeProfileIDs)) {
                val raw = profiles[index].source.getJSONObject("customization").opt("colorSchemePreference")
                val remotePreference = if (raw == null) AppearancePreference.SYSTEM else if (raw is String)
                    runCatching { AppearancePreference.parse(raw) }.getOrNull() else null
                if (remotePreference == edit.preference) continue
            }
            if (index < 0) {
                require(profiles.size < 256) { "Cannot recover another keypad: the profile limit has been reached" }
                val saved = edit.recoveredProfile()
                val source = JSONObject(saved.source.toString()).put("name", "Recovered Android Layout")
                profiles += ControllerProfile.parse(source); index = profiles.lastIndex
                recovered += edit.profileID
            }
            profiles[index] = applying(profiles[index], edit)
            remaining += edit; uploads += edit
        }
        return AppearanceReconciliation(incoming.copy(profiles = profiles), remaining, uploads, recovered)
    }
}
