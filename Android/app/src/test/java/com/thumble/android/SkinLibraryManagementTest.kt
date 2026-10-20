package com.thumble.android

import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Test

class SkinLibraryManagementTest {
    private val reference=SkinReference("com.example.skin","1.0.0")
    @Test fun removalIntentRoundTripsWithExplicitMacOwnership() {
        val values=listOf(PendingSkinRemoval(reference,"mac-a"),PendingSkinRemoval(reference,"mac-b"))
        assertEquals(values,SkinRemovalJournal.decode(SkinRemovalJournal.encode(values)))
    }
    @Test fun removalJournalRejectsDuplicatesMissingAuthorityAndExcessiveEntries() {
        val item=PendingSkinRemoval(reference,"mac-a")
        assertTrue(runCatching { SkinRemovalJournal.encode(listOf(item,item)) }.isFailure)
        assertTrue(runCatching { SkinRemovalJournal.decode(JSONArray("[{\"skinReference\":{\"identifier\":\"com.example.skin\",\"version\":\"1.0.0\"}}]")) }.isFailure)
        assertTrue(runCatching { SkinRemovalJournal.encode((0..256).map { PendingSkinRemoval(reference,"mac-$it") }) }.isFailure)
        assertTrue(runCatching { PendingSkinRemoval(reference," ") }.isFailure)
    }
    @Test fun exportFilenamesCannotContainPathsAndRemainBounded() {
        assertEquals("thumble-skin-1.0.0.pocketpad",SkinTransferFiles.filename("☀","1.0.0"))
        val name=SkinTransferFiles.filename("../../Secret "+"A".repeat(500),"../../1.0.0")
        assertFalse(name.contains('/'));assertFalse(name.contains('\\'));assertTrue(name.endsWith(".pocketpad"));assertTrue(name.length<=171)
    }
}
