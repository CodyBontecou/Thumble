package com.thumble.android

import org.json.JSONArray
import org.json.JSONObject
import java.math.BigDecimal
import java.util.UUID

internal data class ArtifactAdoptionMetadata(val operationID: UUID,val recordID: UUID,val serverID: String,
    val contentHash: String,val rawSHA256: String,val byteCount: Int,val chunkCount: Int) {
    fun json()=JSONObject().put("operationID",operationID.toString()).put("recordID",recordID.toString())
        .put("intendedServerID",serverID).put("contentHash",contentHash).put("rawSHA256",rawSHA256)
        .put("byteCount",byteCount).put("chunkCount",chunkCount).put("conflictPolicy","append_as_copies")
    fun valid()=validServer(serverID) && hash.matches(contentHash) && hash.matches(rawSHA256) &&
        byteCount in 1..PortableProfileArtifact.MAX_BYTES && chunkCount==(byteCount+CHUNK_BYTES-1)/CHUNK_BYTES
    companion object {
        const val CAPABILITY="profile_artifact_adoption_v1"
        const val CHUNK_BYTES=256*1024
        private val hash=Regex("[0-9a-f]{64}")
        fun validServer(value: String)=value.isNotEmpty() && value.codePointCount(0,value.length)<=128 && value.codePoints().noneMatch(SkinText::isControl)
        fun forRecord(record: PendingSharedBuild,serverID: String,operationID: UUID)=ArtifactAdoptionMetadata(operationID,record.id,serverID,
            record.contentHash,record.rawSHA256,record.bytes,(record.bytes+CHUNK_BYTES-1)/CHUNK_BYTES)
    }
}
internal enum class ArtifactAdoptionPhase { UPLOADING, AWAITING_SNAPSHOT, SUCCEEDED, FAILED }
internal data class ArtifactAdoptionState(val metadata: ArtifactAdoptionMetadata,val phase: ArtifactAdoptionPhase,
    val sourceProfiles: Int,val sentChunks: Int=0,val destinationProfileIDs: List<UUID> = emptyList(),val errorCode: String?=null) {
    val active get()=phase==ArtifactAdoptionPhase.UPLOADING || phase==ArtifactAdoptionPhase.AWAITING_SNAPSHOT
}
internal data class ArtifactAdoptionResult(val status: String,val errorCode: String?,val destinationIDs: List<UUID>) {
    companion object {
        private val errors=setOf("unsupported","unauthenticated","invalid_envelope","wrong_server","invalid_hash","invalid_size","invalid_chunk",
            "out_of_order","upload_busy","upload_expired","operation_conflict","operation_missing","artifact_invalid","import_failed","disconnected")
        /** Fail closed before profile/capability processing; never surface raw host text. */
        fun parse(message: JSONObject,expected: ArtifactAdoptionMetadata): ArtifactAdoptionResult {
            fun bad(): Nothing=throw SharedBuildException("invalid-artifact")
            if(!expected.valid() || message.opt("type")!="profile_artifact_adoption_result" ||
                message.keys().asSequence().any { it !in setOf("type","timestamp","profileArtifactAdoptionResult") && !message.isNull(it) }) bad()
            val timestamp=message.opt("timestamp") as? Number ?: bad()
            try { BigDecimal(timestamp.toString()).longValueExact() } catch(_: ArithmeticException) { bad() }
            val raw=message.optJSONObject("profileArtifactAdoptionResult") ?: bad()
            if(PortableProfileArtifact.id(raw.opt("operationID"))!=expected.operationID || PortableProfileArtifact.id(raw.opt("recordID"))!=expected.recordID ||
                raw.opt("serverID")!=expected.serverID || raw.opt("contentHash")!=expected.contentHash || raw.opt("rawSHA256")!=expected.rawSHA256) bad()
            val status=raw.opt("status") as? String ?: bad()
            val error=if(!raw.has("errorCode") || raw.isNull("errorCode")) null else raw.get("errorCode") as? String ?: bad()
            if(error!=null && error !in errors) bad()
            val destinations=raw.optJSONArray("destinationProfileIDs") ?: bad()
            if(destinations.length()>256) bad()
            val ids=(0 until destinations.length()).map { PortableProfileArtifact.id(destinations.get(it)) }
            if(ids.toSet().size!=ids.size) bad()
            when(status) {
                "accepted" -> if(error!=null || ids.isNotEmpty()) bad()
                "succeeded","replayed" -> if(error!=null || ids.isEmpty()) bad()
                "failed" -> if(error==null || ids.isNotEmpty()) bad()
                else -> bad()
            }
            return ArtifactAdoptionResult(status,error,ids)
        }
    }
}
