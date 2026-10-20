package com.thumble.android

import org.json.JSONArray
import org.json.JSONObject

/** Removal intents belong to the Mac paired when the user requested removal. */
internal data class PendingSkinRemoval(val reference: SkinReference, val serverID: String) {
    init { require(serverID.isNotBlank() && serverID.length<=512) }
}
internal object SkinRemovalJournal {
    fun encode(values: List<PendingSkinRemoval>): JSONArray {
        require(values.size<=256 && values.distinct().size==values.size)
        return JSONArray().apply { values.forEach { put(JSONObject().put("skinReference",JSONObject().put("identifier",it.reference.identifier).put("version",it.reference.version)).put("serverID",it.serverID)) } }
    }
    fun decode(raw: JSONArray): List<PendingSkinRemoval> = (0 until raw.length()).map {
        val item=raw.getJSONObject(it)
        PendingSkinRemoval(SkinReference.parse(item.getJSONObject("skinReference")),item.getString("serverID"))
    }.also { encode(it) }
}
