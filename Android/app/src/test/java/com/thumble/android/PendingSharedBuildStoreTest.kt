package com.thumble.android

import org.json.JSONObject
import org.erdtman.jcs.JsonCanonicalizer
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermissions
import java.util.UUID

class PendingSharedBuildStoreTest {
    private fun fixture()=javaClass.classLoader!!.getResourceAsStream("profile-artifact/v1.json")!!.readBytes()
    private fun artifact()=PortableProfileArtifact.decode(fixture())
    private fun root()=Files.createTempDirectory("thumble-pending-build-test-")
    @Test fun reloadPreservesExactBytesAndMetadataWithoutCredentialsOrShareReference() {
        val root=root()
        try {
            val store=PendingSharedBuildStore(root) { 1000 };val artifact=artifact();val record=store.save(artifact)
            val reloaded=PendingSharedBuildStore(root) { 1001 }
            assertEquals(listOf(record),reloaded.list());assertArrayEquals(fixture(),reloaded.load(record.id).rawData())
            assertEquals(PosixFilePermissions.fromString("rwx------"),Files.getPosixFilePermissions(root))
            Files.newDirectoryStream(root).use { files -> for(file in files) {
                assertEquals(PosixFilePermissions.fromString("rw-------"),Files.getPosixFilePermissions(file))
                if(file.toString().endsWith("metadata.json")) {
                    val text=file.toFile().readText();assertFalse(text.contains("token="));assertFalse(text.contains("Authorization"));assertFalse(text.contains("sourceHost"))
                }
            } }
        } finally { root.toFile().deleteRecursively() }
    }
    @Test fun expiredAndInterruptedAdoptionRecoveryMatchesNativeRetention() {
        val root=root();var clock=1000L
        try {
            val store=PendingSharedBuildStore(root) { clock };val ordinary=store.save(artifact(),lifetime=10)
            val adopting=store.save(artifact(),lifetime=10);val operation=UUID.randomUUID()
            store.update(adopting.id,PendingBuildState.ADOPTING,operation,"fixture-mac")
            clock+=11
            assertEquals(listOf(adopting.id),store.list().map { it.id });assertFalse(Files.exists(root.resolve("${ordinary.id}.artifact.json")))
            val recovered=PendingSharedBuildStore(root) { clock }
            assertEquals(PendingBuildState.ADOPTING,recovered.list().single().state)
            recovered.recoverInterruptedAdoptions();assertTrue(recovered.list().isEmpty())
        } finally { root.toFile().deleteRecursively() }
    }
    @Test fun interruptedAndCorruptPairsAndUnsafeSymlinksCannotBecomeRecords() {
        val root=root();val target=Files.createTempFile("thumble-private-target-",".json")
        try {
            target.toFile().writeText("unchanged")
            val store=PendingSharedBuildStore(root) { 1000 };val record=store.save(artifact())
            val valid=store.save(artifact());root.resolve("orphan.tmp").toFile().writeText("incomplete")
            val orphan=UUID.randomUUID();Files.write(root.resolve("$orphan.artifact.json"),fixture())
            Files.delete(root.resolve("${record.id}.artifact.json"));Files.createSymbolicLink(root.resolve("${record.id}.artifact.json"),target)
            val reloaded=PendingSharedBuildStore(root) { 1001 }
            assertEquals(listOf(valid.id),reloaded.list().map { it.id });assertEquals("unchanged",target.toFile().readText())
            assertFalse(Files.exists(root.resolve("orphan.tmp")));assertFalse(Files.exists(root.resolve("$orphan.artifact.json")))
            root.resolve("${valid.id}.artifact.json").toFile().writeText("{}")
            assertTrue(runCatching { reloaded.load(valid.id) }.isFailure);assertTrue(reloaded.list().isEmpty())
        } finally { root.toFile().deleteRecursively();Files.deleteIfExists(target) }
    }
    @Test fun quotaEvictsOldestNonadoptingAndNeverEvictsActiveAdoption() {
        val root=root();var clock=1000L
        try {
            val store=PendingSharedBuildStore(root) { clock };val bytes=artifact()
            val first=store.save(bytes);store.update(first.id,PendingBuildState.ADOPTING,UUID.randomUUID(),"mac")
            val oldestOrdinary=store.save(bytes);repeat(31) { clock++;store.save(bytes) }
            assertEquals(32,store.list().size);assertTrue(store.list().any { it.id==first.id });assertTrue(store.list().none { it.id==oldestOrdinary.id })
            for(record in store.list()) store.update(record.id,PendingBuildState.ADOPTING,UUID.randomUUID(),"mac")
            assertTrue(runCatching { store.save(bytes) }.isFailure);assertEquals(32,store.list().size)
            assertTrue(runCatching { store.delete(first.id) }.isFailure)
        } finally { root.toFile().deleteRecursively() }
    }
    @Test fun aggregateQuotaIsEnforcedWithValidArtifactsAndRawDataStaysByteExact() {
        val root=root();var clock=1000L
        try {
            val raw=JSONObject(fixture().toString(Charsets.UTF_8))
            repeat(9) { raw.put("futureExtension$it","a".repeat(240000)) }
            val content=JSONObject(raw.toString()).apply { remove("exportedAt");remove("contentHash") }
            raw.getJSONObject("contentHash").put("value",packageHash(JsonCanonicalizer(content.toString()).encodedUTF8))
            val large=PortableProfileArtifact.decode(raw.toString().toByteArray());val store=PendingSharedBuildStore(root) { clock }
            val first=store.save(large);repeat(16) { clock++;store.save(large) }
            assertTrue(store.list().sumOf { it.bytes.toLong() }<=PendingSharedBuildStore.MAX_TOTAL)
            assertTrue(store.list().none { it.id==first.id })
            assertArrayEquals(large.rawData(),store.load(store.list().last().id).rawData())
        } finally { root.toFile().deleteRecursively() }
    }
    @Test fun invalidStateMetadataFailsBeforeReplacingTheOldRecord() {
        val root=root()
        try {
            val store=PendingSharedBuildStore(root) { 1000 };val record=store.save(artifact());val operation=UUID.randomUUID()
            val next=store.update(record.id,PendingBuildState.ADOPTING,operation,"mac")
            assertTrue(runCatching { store.update(record.id,PendingBuildState.FAILED,operation,"mac","private token") }.isFailure)
            assertEquals(next,PendingSharedBuildStore(root) { 1001 }.list().single())
            val failed=store.update(record.id,PendingBuildState.FAILED,operation,"mac","disconnected")
            assertEquals(operation,failed.operationID);assertEquals("mac",failed.intendedServerID)
        } finally { root.toFile().deleteRecursively() }
    }
}
