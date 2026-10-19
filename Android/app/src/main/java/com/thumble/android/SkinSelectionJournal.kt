package com.thumble.android

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

internal data class PendingSkinSelection(val profileID: UUID, val reference: SkinReference?, val updatedAt: Long, val serverID: String? = null) {
    fun json() = JSONObject().put("profileID",profileID.toString()).put("updatedAt",updatedAt).apply {
        reference?.let { put("skinReference",JSONObject().put("identifier",it.identifier).put("version",it.version)) }
        serverID?.let { put("serverID",it) }
    }
    fun request() = WireCodec.message("gamepad_profile_skin_selection").put("gamepadProfileID",profileID.toString().uppercase()).apply {
        reference?.let { put("skinReference",JSONObject().put("identifier",it.identifier).put("version",it.version)) }
    }
}

/** Last intent per profile; only an authoritative matching reference acknowledges it. */
internal object SkinSelectionJournal {
    fun decode(array: JSONArray?): List<PendingSkinSelection> {
        if (array == null) return emptyList()
        require(array.length() <= 256)
        val seen=hashSetOf<UUID>()
        return (0 until array.length()).map { index ->
            val o=array.getJSONObject(index);val id=UUID.fromString(o.getString("profileID"))
            require(seen.add(id))
            val stamp=o.get("updatedAt") as? Number ?: error("Invalid pending skin timestamp")
            val timestamp=try { java.math.BigDecimal(stamp.toString()).longValueExact() } catch(e:ArithmeticException) { throw IllegalArgumentException("Invalid pending skin timestamp",e) }
            val server=if(o.isNull("serverID") || !o.has("serverID")) null else o.getString("serverID").also { require(it.isNotBlank() && it.length<=512) }
            val reference=if(o.isNull("skinReference") || !o.has("skinReference")) null else SkinReference.parse(o.getJSONObject("skinReference"))
            PendingSkinSelection(id,reference,timestamp,server)
        }
    }
    fun encode(values: List<PendingSkinSelection>) = JSONArray().also { a -> values.forEach { a.put(it.json()) } }
    fun replacing(values: List<PendingSkinSelection>, value: PendingSkinSelection): List<PendingSkinSelection> =
        (values.filterNot { it.profileID==value.profileID }+value).also { require(it.size<=256) }
    fun acknowledge(values: List<PendingSkinSelection>, snapshot: ProfileSnapshot, serverID: String?): List<PendingSkinSelection> = values.filterNot { pending ->
        if(pending.serverID!=null && pending.serverID!=serverID) false else {
            val profile=snapshot.profiles.firstOrNull { it.id==pending.profileID }
            profile!=null && (if(!profile.source.has("skinReference") || profile.source.isNull("skinReference")) null
                else SkinReference.parse(profile.source.getJSONObject("skinReference")))==pending.reference
        }
    }
}
