package com.thumble.android

import android.util.AtomicFile
import java.io.File
import java.security.MessageDigest

/** Device-only reach samples. Call on the session's calibration worker. */
internal class ThumbCalibrationStore(private val directory: File) {
    private fun file(key: ThumbCalibrationKey): AtomicFile {
        val identity="${key.profileID}|${key.device.length}:${key.device}|${key.display.length}:${key.display}|${key.orientation.wireValue}"
        val hash=MessageDigest.getInstance("SHA-256").digest(identity.toByteArray()).joinToString("") { "%02x".format(it) }
        return AtomicFile(File(directory,"$hash.json"))
    }
    fun load(key: ThumbCalibrationKey): ThumbCalibration? {
        val f=file(key)
        val backup=File(f.baseFile.path+".bak")
        if(!f.baseFile.exists() && !backup.exists()) return null
        require(f.baseFile.length()<=64*1024 && backup.length()<=64*1024) { "Reach calibration is too large" }
        val bytes=f.readFully();require(bytes.size<=64*1024)
        return ThumbCalibration.parse(PackageJSON.objectValue(bytes)).also { require(it.key==key) }
    }
    fun save(value: ThumbCalibration) {
        check(directory.isDirectory || directory.mkdirs())
        val f=file(value.key)
        check(f.baseFile.exists() || directory.listFiles()?.count { it.extension=="json" }?.let { it<512 }!=false) { "Reach calibration storage is full" }
        val bytes=value.json().toString().toByteArray();require(bytes.size<=64*1024)
        val output=f.startWrite()
        try { output.write(bytes);f.finishWrite(output) } catch(error: Exception) { f.failWrite(output);throw error }
    }
    fun remove(key: ThumbCalibrationKey) { file(key).delete() }
}
