package com.thumble.android

import android.content.Intent
import android.net.Uri
import android.os.Build
import java.io.ByteArrayOutputStream
import java.io.InputStream

internal class SkinImportException(message: String): IllegalArgumentException(message)

internal object SkinImportIntents {
    const val MIME="application/vnd.pocketpad.skin+zip"
    val mimeTypes=setOf(MIME,"application/zip","application/x-zip-compressed","application/octet-stream")
    fun uri(intent: Intent): Uri? {
        if(intent.action !in setOf(Intent.ACTION_VIEW,Intent.ACTION_SEND,Intent.ACTION_SEND_MULTIPLE)) return null
        if(intent.action==Intent.ACTION_SEND_MULTIPLE) throw SkinImportException("Choose one skin package at a time.")
        if(intent.type?.substringBefore(';')?.trim()?.lowercase() !in mimeTypes) throw SkinImportException("Choose a .pocketpad or ZIP skin package.")
        val candidates=linkedSetOf<Uri>()
        try {
            if(intent.action==Intent.ACTION_VIEW) intent.data?.let(candidates::add)
            else {
                val stream=if(Build.VERSION.SDK_INT>=33) intent.getParcelableExtra(Intent.EXTRA_STREAM,Uri::class.java)
                    else @Suppress("DEPRECATION") (intent.getParcelableExtra<android.os.Parcelable>(Intent.EXTRA_STREAM) as? Uri)
                stream?.let(candidates::add)
                intent.clipData?.let { clip ->
                    if(clip.itemCount>4) throw SkinImportException("Choose one skin package at a time.")
                    repeat(clip.itemCount) { clip.getItemAt(it).uri?.let(candidates::add) }
                }
            }
        } catch(error: SkinImportException) { throw error }
        catch(_: RuntimeException) { throw SkinImportException("This share did not contain a readable skin file.") }
        if(candidates.size!=1) throw SkinImportException("Choose one skin package at a time.")
        return validated(candidates.single())
    }
    fun validated(uri: Uri): Uri = uri.also {
        if(it.scheme!="content" || it.authority.isNullOrBlank() || it.toString().length>8192)
            throw SkinImportException("Choose a skin file from a document or sharing app.")
    }
}

internal object SkinImportReader {
    fun bytes(open: ()->InputStream, maximum: Int=PackageArchive.MAX_ARCHIVE): ByteArray {
        require(maximum in 1..PackageArchive.MAX_ARCHIVE)
        return open().use { input ->
            val output=ByteArrayOutputStream(minOf(maximum,64*1024));val buffer=ByteArray(64*1024)
            while(true) {
                val n=input.read(buffer)
                if(n<0) break
                if(n==0) {
                    val one=input.read();if(one<0) break
                    if(output.size()>=maximum) throw SkinImportException("This skin package is too large.")
                    output.write(one)
                } else {
                    if(output.size().toLong()+n>maximum) throw SkinImportException("This skin package is too large.")
                    output.write(buffer,0,n)
                }
            }
            output.toByteArray()
        }
    }
    fun packageValue(open: ()->InputStream): SkinPackage = try {
        SkinPackageCodec.decode(bytes(open)).also { if(!it.hasSkin) throw SkinImportException("This package does not contain a skin.") }
    } catch(error: SkinImportException) { throw error }
    catch(_: SecurityException) { throw SkinImportException("Access to this file has expired. Share it again or choose it with Import.") }
    catch(error: SkinPackageException) { throw SkinImportException("This is not a supported .pocketpad skin package (${error.code}).") }
    catch(_: Exception) { throw SkinImportException("Could not read this skin file. Choose it again with Import.") }
}
