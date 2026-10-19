package com.thumble.android

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider

/** Application-context resources only: a recreated screen never owns or abandons a socket. */
internal class ControllerSession(store: SessionStore, discovery: MacDiscovery, val skinRenderer: SkinRenderRepository, private val skinLibrary: () -> SkinLibrary) : ViewModel() {
    var state by mutableStateOf(ClientState())
        private set
    var skinRevision by mutableStateOf(0L)
        private set
    fun skinLibraryChanged() { skinRenderer.invalidate(); skinRevision++ }
    var installedSkins by mutableStateOf<List<InstalledSkin>>(emptyList())
        private set
    var skinBusy by mutableStateOf(false)
        private set
    var skinError by mutableStateOf<String?>(null)
        private set
    var reviewedSkin by mutableStateOf<SkinPackage?>(null)
        private set
    private val skinWorker = java.util.concurrent.Executors.newSingleThreadExecutor()
    private val main = android.os.Handler(android.os.Looper.getMainLooper())
    private var cleared = false
    var skinSyncInFlight by mutableStateOf(0)
        private set
    private val incomingSkinQueue = SkinSyncQueue(skinWorker,
        { IncomingSkinSync.install(skinLibrary(),it) },
        { result -> main.post { completeIncomingSkins(result) } })
    private fun completeIncomingSkins(result: Result<SyncedSkinPackages>) {
        if(cleared) return
        skinSyncInFlight--
        result.fold({ synced ->
            synced.installed?.let { installedSkins=it }
            if(synced.changed.isNotEmpty()) {
                // Invalidate package cache even if another profile is selected.
                skinRenderer.invalidate()
                val active=state.snapshot.selected?.source?.optJSONObject("skinReference")?.let { runCatching { SkinReference.parse(it) }.getOrNull() }
                if(active in synced.changed) skinRevision++
            }
            skinError=synced.failure?.let { "A synced skin could not be installed: $it" }
        }, { skinError="A synced skin could not be installed: ${it.message?.take(500).orEmpty()}" })
    }
    val client = ControllerClient(store, discovery, skinArchive = { skinLibrary().archiveFor(it) }, incomingSkins={ packages ->
        // Post the start before dispatching work, so completion cannot overtake it.
        main.post { if(!cleared) skinSyncInFlight++ }
        val accepted=incomingSkinQueue.submit(packages)
        if(!accepted) main.post { if(!cleared) skinSyncInFlight-- }
        accepted
    }) {
        if(!cleared) state = it
    }
    private fun <T> skinWork(work: () -> T, commit: (T) -> Unit) {
        if (skinBusy || cleared) return
        skinBusy=true;skinError=null
        skinWorker.execute {
            val result=runCatching(work)
            main.post {
                if (!cleared) {
                    skinBusy=false
                    result.fold(commit) { skinError=it.message?.take(500) ?: "Could not update skins. Try again." }
                }
            }
        }
    }
    fun refreshSkins() = skinWork({ skinLibrary().installed() }) { installedSkins=it }
    fun prepareSkinImport(open: () -> java.io.InputStream) = skinWork({
        val bytes=open().use { input ->
            val output=java.io.ByteArrayOutputStream();val buffer=ByteArray(64*1024)
            while(true) {
                val n=input.read(buffer);if(n<0) break
                require(output.size().toLong()+n<=PackageArchive.MAX_ARCHIVE) { "This skin package is too large." }
                output.write(buffer,0,n)
            }
            output.toByteArray()
        }
        SkinPackageCodec.decode(bytes).also { require(it.hasSkin) { "This package does not contain a skin." } }
    }) { reviewedSkin=it }
    fun cancelSkinImport() { if (!skinBusy) { reviewedSkin=null;skinError=null } }
    fun installReviewedSkin() {
        val reviewed=reviewedSkin ?: return
        skinWork({
            val bytes=reviewed.archiveBytes()
            skinLibrary().install(bytes,SkinInstallPolicy.REPLACE_SAME_VERSION)
            skinLibrary().installed() to bytes
        }) { (installed,bytes) ->
            installedSkins=installed;reviewedSkin=null;skinLibraryChanged()
            client.uploadSkinArchive(bytes)
        }
    }
    fun applySkin(reference: SkinReference, scheme: String) {
        val original=state.snapshot.selected ?: return
        skinWork({ SkinProfileLifecycle.apply(original,skinLibrary().packageFor(reference),scheme) }) {
            skinBusy=true;client.commitSkinChange(original,it,reference) { skinBusy=false }
        }
    }
    fun detachSkin(scheme: String) {
        val original=state.snapshot.selected ?: return
        if(original.source.optJSONObject("skinReference")==null) return
        skinWork({
            val reference=runCatching { SkinReference.parse(original.source.getJSONObject("skinReference")) }.getOrNull()
            val packageValue=reference?.let { runCatching { skinLibrary().packageFor(it) }.getOrNull() }
            SkinProfileLifecycle.detach(original,packageValue,scheme)
        }) {
            skinBusy=true;client.commitSkinChange(original,it,null) { skinBusy=false }
        }
    }
    override fun onCleared() { cleared=true;incomingSkinQueue.close();skinWorker.shutdownNow();client.dispose() }

    class Factory(private val context: Context) : ViewModelProvider.Factory {
        override fun <T : ViewModel> create(modelClass: Class<T>): T {
            require(modelClass == ControllerSession::class.java)
            val library by lazy { SkinLibrary(java.io.File(context.filesDir, "skins")) }
            return modelClass.cast(ControllerSession(ClientDependencies.sessionStore(context), NsdMacDiscovery(context),
                SkinRenderRepository { library.packageFor(it) }, { library }))!!
        }
    }
}
