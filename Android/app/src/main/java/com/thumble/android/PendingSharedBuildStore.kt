package com.thumble.android

import org.json.JSONArray
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.PosixFilePermissions
import java.util.UUID

internal enum class PendingBuildState { PREVIEWED, AWAITING_HOST, ADOPTING, ADOPTED, FAILED }
internal data class PendingSharedBuild(val id: UUID,val contentHash: String,val rawSHA256: String,val bytes: Int,
    val createdAt: Long,val expiresAt: Long,val state: PendingBuildState,val profiles: List<PortableProfileArtifact.Summary>,
    val operationID: UUID?=null,val intendedServerID: String?=null,val errorCode: String?=null) {
    fun json()=JSONObject().put("version",1).put("id",id.toString()).put("contentHash",contentHash).put("rawSHA256",rawSHA256)
        .put("bytes",bytes).put("createdAt",createdAt).put("expiresAt",expiresAt).put("state",state.name)
        .put("profiles",JSONArray().apply { profiles.forEach { put(JSONObject().put("id",it.id.toString()).put("name",it.name)) } })
        .put("operationID",operationID?.toString() ?: JSONObject.NULL).put("intendedServerID",intendedServerID ?: JSONObject.NULL).put("errorCode",errorCode ?: JSONObject.NULL)
}
internal class PendingBuildStoreException: IllegalStateException("Pending shared builds could not be stored safely.")

/** One serialized owner per app session. Only UUID pair files live in this no-backup directory. */
internal class PendingSharedBuildStore(private val directory: Path,private val now: ()->Long=System::currentTimeMillis) {
    companion object {
        const val MAX_RECORDS=32
        const val MAX_TOTAL=32*1024*1024
        const val MAX_METADATA=32*1024
        const val LIFETIME=7*24*60*60*1000L
        const val HARD_LIFETIME=30*24*60*60*1000L
        private fun safeCode(value: String?)=value==null || Regex("[a-z0-9._-]{1,128}").matches(value)
        private fun validServer(value: String?)=value==null || (value.isNotEmpty() && value.codePointCount(0,value.length)<=128 && value.codePoints().noneMatch(SkinText::isControl))
        private fun names(artifact: PortableProfileArtifact)=artifact.summaries.map { summary ->
            val clean=StringBuilder();summary.name.codePoints().forEach { clean.appendCodePoint(if(SkinText.isControl(it)) 32 else it) }
            summary.copy(name=SkinText.trim(clean.toString()))
        }
    }
    private val records=linkedMapOf<UUID,PendingSharedBuild>()
    init {
        Files.createDirectories(directory)
        if(!Files.isDirectory(directory,LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(directory)) throw PendingBuildStoreException()
        Files.setPosixFilePermissions(directory,PosixFilePermissions.fromString("rwx------"))
        reconcile()
    }
    private fun artifactPath(id: UUID)=directory.resolve("$id.artifact.json")
    private fun metadataPath(id: UUID)=directory.resolve("$id.metadata.json")
    private fun read(path: Path,maximum: Int): ByteArray {
        if(!Files.isRegularFile(path,LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(path) || Files.size(path)>maximum) throw PendingBuildStoreException()
        FileChannel.open(path,StandardOpenOption.READ,LinkOption.NOFOLLOW_LINKS).use { channel ->
            if(channel.size()>maximum) throw PendingBuildStoreException()
            val output=java.io.ByteArrayOutputStream();val buffer=ByteBuffer.allocate(64*1024)
            while(true) {
                buffer.clear();val count=channel.read(buffer);if(count<0) break
                if(output.size().toLong()+count>maximum) throw PendingBuildStoreException()
                output.write(buffer.array(),0,count)
            }
            return output.toByteArray()
        }
    }
    private fun write(path: Path,bytes: ByteArray) {
        val temp=directory.resolve(".${UUID.randomUUID()}.tmp")
        try {
            FileChannel.open(temp,setOf<java.nio.file.OpenOption>(StandardOpenOption.WRITE,StandardOpenOption.CREATE_NEW,LinkOption.NOFOLLOW_LINKS),
                PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------"))).use { channel ->
                val buffer=ByteBuffer.wrap(bytes);while(buffer.hasRemaining()) channel.write(buffer);channel.force(true)
            }
            Files.move(temp,path,StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING)
            FileChannel.open(directory,StandardOpenOption.READ).use { it.force(true) }
        } finally { Files.deleteIfExists(temp) }
    }
    private fun metadata(record: PendingSharedBuild)=record.json().toString().toByteArray().also {
        if(it.size>MAX_METADATA) throw PendingBuildStoreException()
    }
    private fun removePair(id: UUID) { Files.deleteIfExists(artifactPath(id));Files.deleteIfExists(metadataPath(id));records.remove(id) }
    private fun prune() {
        records.values.filter { it.state!=PendingBuildState.ADOPTING && now()>=it.expiresAt }.map { it.id }.forEach(::removePair)
    }
    private fun capacity(bytes: Int,count: Int) {
        while(records.size+count>MAX_RECORDS || records.values.sumOf { it.bytes.toLong() }+bytes>MAX_TOTAL) {
            val victim=records.values.filter { it.state!=PendingBuildState.ADOPTING }.minWithOrNull(compareBy<PendingSharedBuild> { it.createdAt }.thenBy { it.id.toString() }) ?: throw PendingBuildStoreException()
            removePair(victim.id)
        }
    }
    @Synchronized fun list(): List<PendingSharedBuild> {
        prune();return records.values.sortedWith(compareBy<PendingSharedBuild> { it.createdAt }.thenBy { it.id.toString() })
    }
    @Synchronized fun save(artifact: PortableProfileArtifact,id: UUID=UUID.randomUUID(),lifetime: Long=LIFETIME): PendingSharedBuild {
        if(id in records || artifact.byteCount>PortableProfileArtifact.MAX_BYTES) throw PendingBuildStoreException()
        val created=now();if(created<0 || created>Long.MAX_VALUE-HARD_LIFETIME) throw PendingBuildStoreException()
        val record=PendingSharedBuild(id,artifact.contentHash,artifact.rawSHA256,artifact.byteCount,created,created+lifetime.coerceIn(0,HARD_LIFETIME),PendingBuildState.PREVIEWED,names(artifact))
        val meta=metadata(record);prune();capacity(artifact.byteCount,1)
        write(artifactPath(id),artifact.rawData())
        try { write(metadataPath(id),meta) } catch(error: Exception) { Files.deleteIfExists(artifactPath(id));throw error }
        records[id]=record;return record
    }
    @Synchronized fun load(id: UUID): PortableProfileArtifact {
        prune();val record=records[id] ?: throw PendingBuildStoreException()
        try {
            val bytes=read(artifactPath(id),PortableProfileArtifact.MAX_BYTES);val artifact=PortableProfileArtifact.decode(bytes)
            if(bytes.size!=record.bytes || artifact.rawSHA256!=record.rawSHA256 || artifact.contentHash!=record.contentHash || names(artifact)!=record.profiles) throw PendingBuildStoreException()
            return artifact
        } catch(_: Exception) { removePair(id);throw PendingBuildStoreException() }
    }
    @Synchronized fun update(id: UUID,state: PendingBuildState,operationID: UUID?=null,serverID: String?=null,error: String?=null): PendingSharedBuild {
        val old=records[id] ?: throw PendingBuildStoreException()
        if(!safeCode(error) || !validServer(serverID)) throw PendingBuildStoreException()
        val next=old.copy(state=state,operationID=operationID,intendedServerID=serverID ?: old.intendedServerID,errorCode=error)
        write(metadataPath(id),metadata(next));records[id]=next;return next
    }
    @Synchronized fun delete(id: UUID) { if(records[id]?.state==PendingBuildState.ADOPTING) throw PendingBuildStoreException();removePair(id) }
    @Synchronized fun recoverInterruptedAdoptions() {
        for(record in records.values.toList()) if(record.state==PendingBuildState.ADOPTING)
            update(record.id,PendingBuildState.FAILED,record.operationID,record.intendedServerID,"disconnected")
        prune()
    }
    private fun reconcile() {
        val ids=mutableSetOf<UUID>()
        Files.newDirectoryStream(directory).use { entries -> for(path in entries) {
            val name=path.fileName.toString()
            val suffix=listOf(".artifact.json",".metadata.json").firstOrNull(name::endsWith)
            val raw=suffix?.let { name.removeSuffix(it) }
            val id=raw?.let { runCatching { PortableProfileArtifact.id(it) }.getOrNull() }
            if(id==null || raw!=id.toString()) Files.deleteIfExists(path) else ids+=id
        } }
        for(id in ids) {
            try {
                val raw=PackageJSON.objectValue(read(metadataPath(id),MAX_METADATA))
                fun integer(key: String): Long {
                    val number=raw.get(key) as? Number ?: throw PendingBuildStoreException()
                    return try { java.math.BigDecimal(number.toString()).longValueExact() } catch(_: ArithmeticException) { throw PendingBuildStoreException() }
                }
                fun string(key: String)=raw.get(key) as? String ?: throw PendingBuildStoreException()
                if(integer("version")!=1L || PortableProfileArtifact.id(raw.get("id"))!=id) throw PendingBuildStoreException()
                val artifact=PortableProfileArtifact.decode(read(artifactPath(id),PortableProfileArtifact.MAX_BYTES))
                val summaries=raw.getJSONArray("profiles")
                val profileNames=(0 until summaries.length()).map { summaries.getJSONObject(it).let { p -> PortableProfileArtifact.Summary(PortableProfileArtifact.id(p.get("id")),p.get("name") as? String ?: throw PendingBuildStoreException()) } }
                fun optional(key: String): String? = if(!raw.has(key) || raw.isNull(key)) null else raw.get(key) as? String ?: throw PendingBuildStoreException()
                val operation=optional("operationID")?.let { PortableProfileArtifact.id(it) }
                val server=optional("intendedServerID")
                val error=optional("errorCode")
                val byteCount=integer("bytes");if(byteCount !in 1..PortableProfileArtifact.MAX_BYTES.toLong()) throw PendingBuildStoreException()
                val record=PendingSharedBuild(id,string("contentHash"),string("rawSHA256"),byteCount.toInt(),integer("createdAt"),integer("expiresAt"),PendingBuildState.valueOf(string("state")),profileNames,operation,server,error)
                if(record.contentHash!=artifact.contentHash || record.rawSHA256!=artifact.rawSHA256 || record.bytes!=artifact.byteCount || record.profiles!=names(artifact) ||
                    !safeCode(error) || !validServer(server) || record.createdAt<0 || record.createdAt>Long.MAX_VALUE-HARD_LIFETIME || record.expiresAt !in record.createdAt..record.createdAt+HARD_LIFETIME ||
                    (record.state!=PendingBuildState.ADOPTING && now()>=record.expiresAt)) throw PendingBuildStoreException()
                records[id]=record
            } catch(_: Exception) { removePair(id) }
        }
        capacity(0,0)
    }
}
