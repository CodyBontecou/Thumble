package com.thumble.android

import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption

internal enum class SkinInstallPolicy { NEWER_ONLY, REPLACE_SAME_VERSION, ALLOW_DOWNGRADE }
internal enum class SkinInstallChange { INSTALLED, UPDATED, REPLACED, UNCHANGED }
internal data class SkinInstallResult(val reference: SkinReference,val change: SkinInstallChange,val previousVersion: String?=null)
internal data class InstalledSkin(val reference: SkinReference,val name: String,val archiveSHA256: String,val author: String="",val summary: String="",val license: String="")

/** Private, independently shareable archives. Atomic replacement never exposes a partial package. */
internal class SkinLibrary(private val root: File) {
    init {
        if (Files.isSymbolicLink(root.toPath())) throw SkinPackageException("invalid-store")
        check(root.mkdirs() || root.isDirectory)
    }
    @Synchronized fun installed(): List<InstalledSkin> = entries()
        .sortedWith(compareBy<InstalledSkin> { it.name.lowercase() }.thenByDescending { SkinVersion.parse(it.reference.version) })
    @Synchronized fun latest(identifier: String): InstalledSkin? = installed().filter { it.reference.identifier==identifier.trim().lowercase() }
        .maxByOrNull { SkinVersion.parse(it.reference.version)!! }
    @Synchronized fun packageFor(reference: SkinReference): SkinPackage {
        val file=destination(reference)
        if (!file.isFile) throw SkinPackageException("skin-not-installed")
        val packageValue=SkinPackageCodec.decode(read(file))
        if (packageValue.reference!=reference || !packageValue.hasSkin) throw SkinPackageException("invalid-store-identity")
        return packageValue
    }
    @Synchronized fun archiveFor(reference: SkinReference): ByteArray = packageFor(reference).archiveBytes()
    @Synchronized fun install(bytes: ByteArray,policy: SkinInstallPolicy=SkinInstallPolicy.NEWER_ONLY): SkinInstallResult {
        val incoming=SkinPackageCodec.decode(bytes)
        if (!incoming.hasSkin) throw SkinPackageException("package-has-no-skin")
        val reference=incoming.reference;val destination=destination(reference)
        val installed=entries().filter { it.reference.identifier==reference.identifier }
        val latest=installed.maxByOrNull { SkinVersion.parse(it.reference.version)!! }
        val exists=destination.isFile
        if (exists) {
            if (read(destination).contentEquals(bytes)) return SkinInstallResult(reference,SkinInstallChange.UNCHANGED)
            if (policy==SkinInstallPolicy.NEWER_ONLY) throw SkinPackageException("version-already-installed")
        } else if (policy!=SkinInstallPolicy.ALLOW_DOWNGRADE && latest!=null &&
            SkinVersion.parse(reference.version)!! < SkinVersion.parse(latest.reference.version)!!) {
            throw SkinPackageException("newer-version-installed")
        }
        val directory=destination.parentFile!!
        if (!directory.mkdirs() && !directory.isDirectory) throw SkinPackageException("cannot-write-package")
        // Recheck after creating the directory, before constructing the temp file.
        destination(reference)
        val temporary=File.createTempFile(".install-", ".tmp",directory)
        try {
            FileOutputStream(temporary).use { output -> output.write(incoming.archiveBytes());output.fd.sync() }
            Files.move(temporary.toPath(),destination.toPath(),StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING)
        } catch (_: Exception) { throw SkinPackageException("cannot-write-package") }
        finally { temporary.delete() }
        return SkinInstallResult(reference,if(exists) SkinInstallChange.REPLACED else if(latest!=null) SkinInstallChange.UPDATED else SkinInstallChange.INSTALLED,
            if(!exists) latest?.reference?.version else null)
    }
    @Synchronized fun remove(reference: SkinReference) {
        val file=destination(reference)
        if (!file.isFile) throw SkinPackageException("skin-not-installed")
        if (!file.delete()) throw SkinPackageException("cannot-remove-package")
        file.parentFile?.let { if (it.list()?.isEmpty()==true) it.delete() }
    }
    private fun read(file: File): ByteArray {
        if (file.length()>PackageArchive.MAX_ARCHIVE) throw SkinPackageException("archive-too-large")
        return file.inputStream().use { input ->
            val output=java.io.ByteArrayOutputStream();val buffer=ByteArray(64*1024)
            while (true) {
                val n=input.read(buffer);if(n<0) break
                if(output.size().toLong()+n>PackageArchive.MAX_ARCHIVE) throw SkinPackageException("archive-too-large")
                output.write(buffer,0,n)
            }
            output.toByteArray()
        }
    }
    private fun entries(): List<InstalledSkin> {
        val result=mutableListOf<InstalledSkin>()
        for (directory in root.listFiles().orEmpty()) {
            if (!directory.isDirectory || Files.isSymbolicLink(directory.toPath())) continue
            for (file in directory.listFiles().orEmpty()) {
                if (file.extension!="pocketpad" || !file.isFile || Files.isSymbolicLink(file.toPath())) continue
                val p=runCatching { SkinPackageCodec.decode(read(file)) }.getOrNull() ?: continue
                if (p.hasSkin && runCatching { destination(p.reference)==file }.getOrDefault(false)) result.add(InstalledSkin(p.reference,p.name,p.archiveSHA256,p.authorName,p.manifestJSON().optString("summary"),p.manifestJSON().optString("license")))
            }
        }
        return result
    }
    private fun destination(reference: SkinReference): File {
        // Hash physical names instead of trusting even syntactically valid
        // prerelease/version text as a path component; logical identity is preserved.
        val directory=File(root,packageHash(reference.identifier.toByteArray(Charsets.UTF_8)))
        val file=File(directory,packageHash(reference.version.toByteArray(Charsets.UTF_8))+".pocketpad")
        if (Files.isSymbolicLink(root.toPath()) || Files.isSymbolicLink(directory.toPath()) || Files.isSymbolicLink(file.toPath()) ||
            !file.canonicalPath.startsWith(root.canonicalPath+File.separator)) throw SkinPackageException("invalid-store-path")
        return file
    }
}
