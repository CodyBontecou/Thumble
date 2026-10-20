package com.thumble.android

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.StandardOpenOption
import java.util.UUID
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import org.json.JSONObject

/** Read-only upgrade recovery. Never instantiate the old expiring/pruning quarantine store here. */
internal class PendingBuildRecovery(private val directory: Path) {
    data class Record(val id: UUID, val name: String, val profileFile: Boolean, val bytes: Int,
        internal val artifactHash: String?, internal val metadataHash: String?)
    class Export internal constructor(val filename: String, private val payload: ByteArray) {
        fun writeTo(output: java.io.OutputStream) { output.write(payload); output.flush() }
    }
    private fun exists() = if (!Files.exists(directory, LinkOption.NOFOLLOW_LINKS)) false else {
        require(Files.isDirectory(directory, LinkOption.NOFOLLOW_LINKS) && !Files.isSymbolicLink(directory)) { "Unsafe recovery directory" }; true
    }
    private fun path(id: UUID, artifact: Boolean) = directory.resolve("$id.${if (artifact) "artifact" else "metadata"}.json")
    private fun read(id: UUID, artifact: Boolean): ByteArray? {
        val file = path(id, artifact)
        if (!Files.exists(file, LinkOption.NOFOLLOW_LINKS)) return null
        require(Files.isRegularFile(file, LinkOption.NOFOLLOW_LINKS) && !Files.isSymbolicLink(file)) { "Unsafe recovery file" }
        val maximum = if (artifact) PortableProfileArtifact.MAX_BYTES else 32 * 1024
        FileChannel.open(file, StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS).use { channel ->
            require(channel.size() <= maximum) { "Recovery file exceeds its size limit" }
            val result = ByteArrayOutputStream(); val buffer = ByteBuffer.allocate(64 * 1024)
            while (true) {
                buffer.clear(); val count = channel.read(buffer); if (count < 0) break
                require(result.size().toLong() + count <= maximum) { "Recovery file exceeds its size limit" }
                result.write(buffer.array(), 0, count)
            }
            return result.toByteArray()
        }
    }
    fun list(): List<Record> {
        if (!exists()) return emptyList()
        val ids = sortedSetOf<String>()
        Files.newDirectoryStream(directory).use { entries -> for (file in entries) {
            val name = file.fileName.toString()
            val suffix = listOf(".artifact.json", ".metadata.json").firstOrNull(name::endsWith) ?: continue
            val id = name.removeSuffix(suffix)
            if (runCatching { UUID.fromString(id).toString() == id }.getOrDefault(false)) ids.add(id)
            require(ids.size <= 256) { "Too many recovery records" }
        } }
        return ids.map { raw ->
            val id = UUID.fromString(raw); val artifact = read(id, true); val metadata = read(id, false)
            val decoded = artifact?.let { runCatching { PortableProfileArtifact.decode(it) }.getOrNull() }
            val name = decoded?.summaries?.firstOrNull()?.name?.filterNot(Char::isISOControl)?.take(160)?.ifBlank { null }
                ?: "Saved build ${raw.take(8)}"
            Record(id, name, decoded != null, (artifact?.size ?: 0) + (metadata?.size ?: 0),
                artifact?.let(::packageHash), metadata?.let(::packageHash))
        }
    }
    fun prepare(record: Record): Export {
        require(exists()) { "Recovery source is unavailable" }
        val artifact = read(record.id, true); val metadata = read(record.id, false)
        require(artifact?.let(::packageHash) == record.artifactHash && metadata?.let(::packageHash) == record.metadataHash) { "Recovery source changed; refresh before exporting" }
        require(artifact != null || metadata != null) { "Recovery source is unavailable" }
        if (record.profileFile) {
            val validated = PortableProfileArtifact.decode(requireNotNull(artifact))
            return Export("thumble-recovered-${record.id}.json", validated.rawData())
        }
        val output = ByteArrayOutputStream()
        ZipOutputStream(output).use { zip ->
            fun entry(name: String, bytes: ByteArray) {
                zip.putNextEntry(ZipEntry(name).apply { time = 0 }); zip.write(bytes); zip.closeEntry()
            }
            artifact?.let { entry("${record.id}.artifact.json", it) }
            metadata?.let { entry("${record.id}.metadata.json", it) }
            entry("recovery.json", JSONObject().put("version", 1).put("recordID", record.id.toString())
                .put("status", "manual-recovery-required").put("artifactSHA256", record.artifactHash ?: JSONObject.NULL)
                .put("metadataSHA256", record.metadataHash ?: JSONObject.NULL).toString().toByteArray(Charsets.UTF_8))
        }
        return Export("thumble-recovery-${record.id}.zip", output.toByteArray())
    }
}
