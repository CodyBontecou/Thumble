package com.thumble.android

import java.io.ByteArrayOutputStream
import java.nio.file.Files
import java.nio.file.Path
import java.util.UUID
import java.util.zip.ZipInputStream
import org.junit.Assert.*
import org.junit.Test

class PendingBuildRecoveryTest {
    private val id = UUID.fromString("b2100000-0000-0000-0000-000000000001")
    private fun fixture() = javaClass.classLoader!!.getResourceAsStream("profile-artifact/v1.json")!!.readBytes()
    private fun write(root: Path, suffix: String, bytes: ByteArray) = Files.write(root.resolve("$id.$suffix.json"), bytes)
    private fun snapshot(root: Path): Map<String, List<Byte>> = Files.list(root).use { files ->
        files.filter { Files.isRegularFile(it, java.nio.file.LinkOption.NOFOLLOW_LINKS) }.toList().associate { it.fileName.toString() to Files.readAllBytes(it).toList() }
    }
    @Test fun absentDirectoryIsNotCreatedAndDiscoveryDoesNotRepairOrPrune() {
        val root = Files.createTempDirectory("build-recovery")
        try {
            val absent = root.resolve("not-created")
            assertTrue(PendingBuildRecovery(absent).list().isEmpty()); assertFalse(Files.exists(absent))
            val raw = fixture(); write(root, "artifact", raw)
            write(root, "metadata", """{"expiresAt":0,"state":"ADOPTING","future":{"keep":"exact bytes"}}""".toByteArray())
            Files.write(root.resolve("unknown-file"), byteArrayOf(1, 2))
            val before = snapshot(root); val recovery = PendingBuildRecovery(root)
            val record = recovery.list().single(); assertTrue(record.profileFile)
            val export = recovery.prepare(record); val output = ByteArrayOutputStream(); export.writeTo(output)
            assertTrue(export.filename.endsWith(".json")); assertArrayEquals(raw, output.toByteArray())
            assertEquals(before, snapshot(root)); assertEquals(record, recovery.list().single())
        } finally { root.toFile().deleteRecursively() }
    }
    @Test fun corruptOrOrphanedRecordsExportRawRecoveryArchivesWithoutDeletingSources() {
        for (includeArtifact in listOf(true, false)) {
            val root = Files.createTempDirectory("build-recovery")
            try {
                val raw = "not valid json".toByteArray(); val metadata = byteArrayOf(0, 1, 2, 3)
                if (includeArtifact) write(root, "artifact", raw)
                write(root, "metadata", metadata)
                val before = snapshot(root); val recovery = PendingBuildRecovery(root); val record = recovery.list().single()
                assertFalse(record.profileFile)
                fun exported() = ByteArrayOutputStream().also { recovery.prepare(record).writeTo(it) }.toByteArray()
                val archive = exported(); assertArrayEquals(archive, exported())
                val entries = linkedMapOf<String, ByteArray>()
                ZipInputStream(archive.inputStream()).use { zip -> while (true) {
                    val entry = zip.nextEntry ?: break; entries[entry.name] = zip.readBytes()
                } }
                assertArrayEquals(metadata, entries["$id.metadata.json"])
                if (includeArtifact) assertArrayEquals(raw, entries["$id.artifact.json"]) else assertFalse(entries.containsKey("$id.artifact.json"))
                assertTrue(entries.containsKey("recovery.json")); assertEquals(before, snapshot(root))
            } finally { root.toFile().deleteRecursively() }
        }
    }
    @Test fun sourceChangeOrDisappearanceRequiresRefreshAndNeverReturnsMixedBytes() {
        val root = Files.createTempDirectory("build-recovery")
        try {
            write(root, "artifact", fixture()); val meta = write(root, "metadata", "old".toByteArray())
            val recovery = PendingBuildRecovery(root); val record = recovery.list().single()
            Files.write(meta, "changed".toByteArray())
            assertThrows(IllegalArgumentException::class.java) { recovery.prepare(record) }
            Files.delete(meta)
            assertThrows(IllegalArgumentException::class.java) { recovery.prepare(record) }
            assertTrue(Files.exists(root.resolve("$id.artifact.json")))
        } finally { root.toFile().deleteRecursively() }
    }
    @Test fun failedDestinationDoesNotConsumeTheOriginalAndCanBeRetried() {
        val root = Files.createTempDirectory("build-recovery")
        try {
            write(root, "artifact", fixture()); val before = snapshot(root)
            val recovery = PendingBuildRecovery(root); val record = recovery.list().single()
            assertThrows(java.io.IOException::class.java) {
                recovery.prepare(record).writeTo(object: java.io.OutputStream() { override fun write(value: Int) { throw java.io.IOException("fixture failure") } })
            }
            val output = ByteArrayOutputStream(); recovery.prepare(record).writeTo(output)
            assertArrayEquals(fixture(), output.toByteArray()); assertEquals(before, snapshot(root))
        } finally { root.toFile().deleteRecursively() }
    }
    @Test fun symbolicLinksOversizeAndUnknownFilenamesCannotBeFollowedOrDeleted() {
        val root = Files.createTempDirectory("build-recovery"); val outside = Files.createTempDirectory("build-recovery-outside")
        try {
            val target = Files.write(outside.resolve("outside.json"), fixture())
            val artifact = root.resolve("$id.artifact.json"); Files.createSymbolicLink(artifact, target)
            assertThrows(IllegalArgumentException::class.java) { PendingBuildRecovery(root).list() }
            assertTrue(Files.isSymbolicLink(artifact)); assertArrayEquals(fixture(), Files.readAllBytes(target))
            Files.delete(artifact)
            Files.newByteChannel(artifact, java.nio.file.StandardOpenOption.CREATE_NEW, java.nio.file.StandardOpenOption.WRITE).use {
                it.position(PortableProfileArtifact.MAX_BYTES.toLong()); it.write(java.nio.ByteBuffer.wrap(byteArrayOf(1)))
            }
            assertThrows(IllegalArgumentException::class.java) { PendingBuildRecovery(root).list() }
            assertEquals(PortableProfileArtifact.MAX_BYTES.toLong() + 1, Files.size(artifact))
            Files.delete(artifact); Files.write(root.resolve("not-a-uuid.artifact.json"), byteArrayOf(3))
            assertTrue(PendingBuildRecovery(root).list().isEmpty()); assertTrue(Files.exists(root.resolve("not-a-uuid.artifact.json")))
            val link = outside.resolve("linked-directory"); Files.createSymbolicLink(link, root)
            assertThrows(IllegalArgumentException::class.java) { PendingBuildRecovery(link).list() }
        } finally { root.toFile().deleteRecursively(); outside.toFile().deleteRecursively() }
    }
}
