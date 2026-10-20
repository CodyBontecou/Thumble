package com.thumble.android

import android.content.ClipData
import android.content.Context
import android.content.Intent
import androidx.core.content.FileProvider
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

internal data class SkinTransfer(val file: File, val share: Boolean, val id: String=UUID.randomUUID().toString())
internal object SkinTransferFiles {
    fun filename(name: String,version: String): String {
        val base=name.lowercase().replace(Regex("[^a-z0-9]+"),"-").trim('-').take(80).ifEmpty { "thumble-skin" }
        val safeVersion=version.replace(Regex("[^a-zA-Z0-9.+-]"),"-").take(80)
        return "$base-$safeVersion.pocketpad"
    }
    fun prepare(cache: File, pkg: SkinPackage): File {
        val root=File(cache,"skin-shares");check(root.mkdirs() || root.isDirectory)
        // Unique directories preserve bytes already handed to another app.
        root.listFiles().orEmpty().filter { System.currentTimeMillis()-it.lastModified()>24*60*60*1000L }.forEach { it.deleteRecursively() }
        val directory=File(root,UUID.randomUUID().toString());check(directory.mkdir())
        return File(directory,filename(pkg.name,pkg.reference.version)).also { file ->
            FileOutputStream(file).use { output -> output.write(pkg.archiveBytes());output.fd.sync() }
        }
    }
    fun shareIntent(context: Context,file: File): Intent {
        val uri=FileProvider.getUriForFile(context,"${context.packageName}.skin-files",file)
        return Intent(Intent.ACTION_SEND).setType("application/octet-stream")
            .putExtra(Intent.EXTRA_STREAM,uri).putExtra(Intent.EXTRA_TITLE,file.name)
            .apply { clipData=ClipData.newRawUri(file.name,uri) }.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
}
