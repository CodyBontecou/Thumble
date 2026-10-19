package com.thumble.android

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class SkinSelectionJournalTest {
    @Test fun intentSurvivesRoundTripAndOnlyMatchingMacAndProfileAcknowledgeIt() {
        val id=UUID.randomUUID();val ref=SkinReference("com.example.test","1.0.0")
        val pending=PendingSkinSelection(id,ref,123,"mac-a")
        assertEquals(listOf(pending),SkinSelectionJournal.decode(SkinSelectionJournal.encode(listOf(pending))))
        fun snapshot(reference: SkinReference?) = ProfileSnapshot(listOf(ControllerProfile(id,"Fixture",JSONObject().apply {
            reference?.let { put("skinReference",JSONObject().put("identifier",it.identifier).put("version",it.version)) }
        })),id)
        assertEquals(listOf(pending),SkinSelectionJournal.acknowledge(listOf(pending),snapshot(ref),"mac-b"))
        assertEquals(listOf(pending),SkinSelectionJournal.acknowledge(listOf(pending),snapshot(null),"mac-a"))
        assertTrue(SkinSelectionJournal.acknowledge(listOf(pending),snapshot(ref),"mac-a").isEmpty())
        assertEquals(listOf(pending),SkinSelectionJournal.acknowledge(listOf(pending),ProfileSnapshot(),"mac-a"))
        val detached=PendingSkinSelection(id,null,124,"mac-a")
        assertEquals(listOf(detached),SkinSelectionJournal.replacing(listOf(pending),detached))
        assertFalse(detached.request().has("skinReference"))
        assertTrue(SkinSelectionJournal.acknowledge(listOf(detached),snapshot(null),"mac-a").isEmpty())
    }
    @Test fun malformedOrDuplicatePendingIntentsAreRejectedInsteadOfLost() {
        val valid=PendingSkinSelection(UUID.randomUUID(),null,123).json()
        for(array in listOf(JSONArray().put(valid).put(valid),JSONArray().put(JSONObject(valid.toString()).put("updatedAt",1.5)),
            JSONArray().put(JSONObject(valid.toString()).put("updatedAt",1e30)),JSONArray().put(JSONObject(valid.toString()).put("skinReference","invalid")))) {
            try { SkinSelectionJournal.decode(array);fail("Invalid pending intent must fail closed") } catch(_:IllegalArgumentException) { } catch(_:org.json.JSONException) { }
        }
    }
}
