package com.thumble.android

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class ProfileArtifactAdoptionTest {
    private val metadata=ArtifactAdoptionMetadata(UUID.fromString("00000000-0000-0000-0000-000000000001"),UUID.fromString("00000000-0000-0000-0000-000000000002"),"fixture-server","a".repeat(64),"b".repeat(64),262145,2)
    private fun result(status: String="succeeded",ids: List<UUID> = listOf(UUID.fromString("00000000-0000-0000-0000-000000000003")))=WireCodec.message("profile_artifact_adoption_result")
        .put("profileArtifactAdoptionResult",JSONObject().put("operationID",metadata.operationID.toString()).put("recordID",metadata.recordID.toString())
            .put("serverID",metadata.serverID).put("contentHash",metadata.contentHash).put("rawSHA256",metadata.rawSHA256).put("status",status)
            .put("destinationProfileIDs",JSONArray(ids.map { it.toString() })))
    @Test fun metadataMatchesNativeNamesAndExactChunkBounds() {
        assertTrue(metadata.valid());assertEquals("append_as_copies",metadata.json().getString("conflictPolicy"))
        assertEquals(metadata.serverID,metadata.json().getString("intendedServerID"));assertEquals(2,metadata.json().getInt("chunkCount"))
        for(value in listOf(metadata.copy(byteCount=0),metadata.copy(byteCount=PortableProfileArtifact.MAX_BYTES+1),metadata.copy(chunkCount=1),
            metadata.copy(serverID="bad\nserver"),metadata.copy(contentHash="A".repeat(64)))) assertFalse(value.valid())
    }
    @Test fun successReplayAcceptanceAndCodedFailureAreValidatedSeparately() {
        assertEquals("succeeded",ArtifactAdoptionResult.parse(result(),metadata).status)
        assertEquals("replayed",ArtifactAdoptionResult.parse(result("replayed"),metadata).status)
        assertEquals("accepted",ArtifactAdoptionResult.parse(result("accepted",emptyList()),metadata).status)
        val failure=result("failed",emptyList());failure.getJSONObject("profileArtifactAdoptionResult").put("errorCode","disconnected")
        assertEquals("disconnected",ArtifactAdoptionResult.parse(failure,metadata).errorCode)
    }
    @Test fun everyIdentityHashAndStatusGateProtectsPendingBuildDeletion() {
        for(field in listOf("operationID","recordID","serverID","contentHash","rawSHA256")) {
            val value=result();value.getJSONObject("profileArtifactAdoptionResult").put(field,if(field.endsWith("ID") && field!="serverID") UUID.randomUUID().toString() else "other")
            assertTrue(field,runCatching { ArtifactAdoptionResult.parse(value,metadata) }.isFailure)
        }
        val id=UUID.randomUUID()
        for(value in listOf(result("succeeded",emptyList()),result("succeeded",listOf(id,id)),result("accepted"),result("failed",emptyList()),result("future"),
            result().put("gamepadProfiles",JSONArray()),result().put("timestamp","not-a-number")))
            assertTrue(value.toString(),runCatching { ArtifactAdoptionResult.parse(value,metadata) }.isFailure)
        val unknownError=result("failed",emptyList());unknownError.getJSONObject("profileArtifactAdoptionResult").put("errorCode","private-host-diagnostic")
        assertTrue(runCatching { ArtifactAdoptionResult.parse(unknownError,metadata) }.isFailure)
    }
}
