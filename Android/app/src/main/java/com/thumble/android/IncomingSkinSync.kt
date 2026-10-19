package com.thumble.android

import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executor
import java.util.concurrent.RejectedExecutionException

/** Owns a decoded message's immutable-by-convention Data array; never exposes it to callers. */
internal class IncomingSkinPackages private constructor(private val encoded: JSONArray, val wireBytes: Int) {
    val count get() = encoded.length()
    fun archive(index: Int): ByteArray = SkinModelCodec.foundationData(encoded.get(index) as String)
    override fun toString() = "IncomingSkinPackages(count=$count)"
    companion object {
        /** Typed Data decoding precedes profile acceptance, as with native Codable. */
        fun validated(message: JSONObject, wireBytes: Int): IncomingSkinPackages? {
            if(!message.has("skinPackages") || message.isNull("skinPackages")) return null
            require(wireBytes in 1..WireCodec.MAX_PAYLOAD)
            val array=message.getJSONArray("skinPackages")
            repeat(array.length()) { index ->
                val value=array.get(index) as? String ?: throw IllegalArgumentException("Invalid skin Data field")
                // Validate without retaining another whole batch of decoded archives.
                SkinModelCodec.foundationData(value)
            }
            return IncomingSkinPackages(array,wireBytes)
        }
    }
}

internal data class SyncedSkinPackages(val changed: Set<SkinReference>, val installed: List<InstalledSkin>?, val failure: String?)

internal object IncomingSkinSync {
    /** Archive failures are independent: native installation continues with the other packages. */
    fun install(library: SkinLibrary, packages: IncomingSkinPackages): SyncedSkinPackages {
        val changed=linkedSetOf<SkinReference>();var failure: String?=null
        repeat(packages.count) { index ->
            try {
                val result=library.install(packages.archive(index),SkinInstallPolicy.ALLOW_DOWNGRADE)
                if(result.change!=SkinInstallChange.UNCHANGED) changed.add(result.reference)
            } catch(e:Exception) { failure=e.message?.take(500) ?: "Could not install the synced package." }
        }
        val installed=runCatching { library.installed() }.getOrElse {
            failure=it.message?.take(500) ?: "Could not read installed skins.";null
        }
        return SyncedSkinPackages(changed,installed,failure)
    }
}

/** Bounded backlog on the existing skin worker. A rejected batch asks the transport to retry. */
internal class SkinSyncQueue(private val executor: Executor,
    private val install: (IncomingSkinPackages) -> SyncedSkinPackages,
    private val completed: (Result<SyncedSkinPackages>) -> Unit,
    private val maximumBytes: Long = 2L * WireCodec.MAX_PAYLOAD,
    private val maximumBatches: Int = 8) {
    private val lock=Any()
    private var bytes=0L
    private var batches=0
    private var closed=false
    fun submit(packages: IncomingSkinPackages): Boolean {
        synchronized(lock) {
            if(closed || batches>=maximumBatches || bytes+packages.wireBytes>maximumBytes) return false
            batches++;bytes+=packages.wireBytes
        }
        fun release() = synchronized(lock) { batches--;bytes-=packages.wireBytes }
        return try {
            executor.execute {
                val result=runCatching { synchronized(lock) { check(!closed) };install(packages) }
                release()
                completed(result)
            }
            true
        } catch(_:RejectedExecutionException) { release();false }
    }
    fun close() { synchronized(lock) { closed=true } }
}
