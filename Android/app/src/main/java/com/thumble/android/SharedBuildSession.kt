package com.thumble.android

import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.nio.file.Path
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/** Upgrade-only local recovery. Hosted fetching, preview and adoption are no longer offered. */
internal class SharedBuildSession(directory: Path) {
    var records by mutableStateOf<List<PendingBuildRecovery.Record>>(emptyList()); private set
    var busy by mutableStateOf(false); private set
    var error by mutableStateOf<String?>(null); private set
    var documentExport: PendingBuildRecovery.Record? = null
    private val recovery = PendingBuildRecovery(directory)
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private var closed = false
    init { refresh() }
    private fun submit(work: () -> Unit) { try { worker.execute(work) } catch (_: RejectedExecutionException) {} }
    fun route(raw: String): Boolean {
        val uri = runCatching { java.net.URI(raw.take(4096)) }.getOrNull() ?: return false
        if (uri.host?.equals("thumble-mcp-gateway.fly.dev", ignoreCase = true) != true) return false
        error = "Hosted shared builds have been retired. You can export builds already saved on this device."
        return true
    }
    fun dismissError() { error = null }
    fun refresh() { submit {
        val result = runCatching { recovery.list() }
        main.post { if (!closed) result.fold({ records = it }, { error = "Saved builds could not be read. Their original files have been kept." }) }
    } }
    fun saveDocument(destination: () -> java.io.OutputStream) {
        val record = documentExport; documentExport = null
        if (record == null) { error = "Choose Save again to export this saved build."; return }
        export(record, destination)
    }
    private fun export(record: PendingBuildRecovery.Record, destination: () -> java.io.OutputStream) {
        if (busy) return
        busy = true; error = null
        submit {
            val result = runCatching {
                val prepared = recovery.prepare(record)
                destination().use(prepared::writeTo)
            }
            main.post { if (!closed) {
                busy = false
                result.onFailure { error = "The export could not be completed. The original saved build is still on this device." }
            } }
        }
    }
    fun close() { closed = true; worker.shutdownNow() }
}
