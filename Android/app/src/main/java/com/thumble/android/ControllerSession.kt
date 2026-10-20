package com.thumble.android

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider

/** Application-context resources only: a recreated screen never owns or abandons a socket. */
internal class ControllerSession(store: SessionStore, discovery: MacDiscovery, val skinRenderer: SkinRenderRepository, private val skinLibrary: () -> SkinLibrary, private val cacheDirectory: java.io.File,
    val sharedBuilds: SharedBuildSession, private val retiredTraceDirectory: java.io.File) : ViewModel() {
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
    init {
        // Accepted calibration suggestions already live in profiles. Only obsolete traces are removed.
        skinWorker.execute { runCatching { retiredTraceDirectory.deleteRecursively() } }
    }
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
    var skinTransfer by mutableStateOf<SkinTransfer?>(null)
        private set
    var documentExport: java.io.File? = null
    var skinNotice by mutableStateOf<String?>(null)
        private set
    fun consumeSkinTransfer(): SkinTransfer? = skinTransfer.also { skinTransfer=null }
    fun reportSkinTransferError(message: String) { skinError=message }
    fun dismissSkinError() { skinError=null;client.dismissError() }
    fun packageForPreview(reference: SkinReference) = skinLibrary().packageFor(reference)
    val client = ControllerClient(store, discovery, removedSkins={ references,completed ->
        try { skinWorker.execute {
            val result=runCatching {
                references.forEach { reference ->
                    try { skinLibrary().remove(reference) }
                    catch(error: SkinPackageException) { if(error.code!="skin-not-installed") throw error }
                }
                skinLibrary().installed()
            }
            completed(result.isSuccess)
            main.post { if(!cleared) { result.onSuccess { installedSkins=it };skinLibraryChanged() } }
        } } catch(_: java.util.concurrent.RejectedExecutionException) { completed(false) }
    }, skinArchive = { skinLibrary().archiveFor(it) }, incomingSkins={ packages ->
        // Post the start before dispatching work, so completion cannot overtake it.
        main.post { if(!cleared) skinSyncInFlight++ }
        val accepted=incomingSkinQueue.submit(packages)
        if(!accepted) main.post { if(!cleared) skinSyncInFlight-- }
        accepted
    }) {
        if(!cleared) { state = it;sharedBuilds.observeAdoption(it.artifactAdoption) }
    }
    private data class ImportRequest(val uri: String?,val epoch: Long,val open: ()->java.io.InputStream)
    private var importEpoch=0L
    private var pendingImport: ImportRequest?=null
    private var activeImportURI: String?=null
    private var reviewImportURI: String?=null
    private var refreshPending=false
    val recoverableSkinImportURI: String? get()=pendingImport?.uri ?: activeImportURI ?: reviewImportURI
    private fun drainSkinRequests() {
        if(skinBusy || cleared) return
        if(refreshPending) {
            refreshPending=false
            // Opening the library can queue this refresh behind an external import.
            // Keep a failed import visible until the user dismisses it or retries.
            skinWork({ skinLibrary().installed() },clearError=false) { installedSkins=it }
            return
        }
        val request=pendingImport ?: return
        pendingImport=null;activeImportURI=request.uri;reviewedSkin=null;reviewImportURI=null
        skinWork({ SkinImportReader.packageValue(request.open) },after={ activeImportURI=null }) { pkg ->
            if(request.epoch==importEpoch) { reviewedSkin=pkg;reviewImportURI=request.uri }
        }
    }
    private fun <T> skinWork(work: () -> T, after: ()->Unit = {}, clearError: Boolean = true, commit: (T) -> Unit) {
        if (skinBusy || cleared) return
        skinBusy=true;if(clearError) skinError=null
        skinWorker.execute {
            val result=runCatching(work)
            main.post {
                if (!cleared) {
                    skinBusy=false
                    result.fold(commit) { skinError=it.message?.take(500) ?: "Could not update skins. Try again." }
                    after();drainSkinRequests()
                }
            }
        }
    }
    fun refreshSkins() { refreshPending=true;drainSkinRequests() }
    fun prepareSkinImport(open: () -> java.io.InputStream) = receiveSkinImport(null,open)
    fun receiveSkinImport(uri: String?,open: ()->java.io.InputStream) {
        if(cleared) return
        pendingImport=ImportRequest(uri,++importEpoch,open)
        drainSkinRequests()
    }
    fun cancelSkinImport() {
        if(!skinBusy) { reviewedSkin=null;reviewImportURI=null;skinError=null }
    }
    fun installReviewedSkin(applyAfter: Boolean = false, scheme: String = "light") {
        val reviewed=reviewedSkin ?: return
        if(skinBusy) return
        skinBusy=true
        client.cancelSkinRemoval(reviewed.reference) { allowed ->
            skinBusy=false
            if(!allowed) { drainSkinRequests();return@cancelSkinRemoval }
            skinWork({
                val bytes=reviewed.archiveBytes()
                skinLibrary().install(bytes,SkinInstallPolicy.REPLACE_SAME_VERSION)
                skinLibrary().installed() to bytes
            }) { (installed,bytes) ->
                installedSkins=installed;reviewedSkin=null;reviewImportURI=null;skinLibraryChanged()
                client.uploadSkinArchive(bytes)
                if(applyAfter) applySkin(reviewed.reference,scheme)
            }
        }
    }
    fun exportSkin(reference: SkinReference,share: Boolean) = skinWork({
        SkinTransferFiles.prepare(cacheDirectory,skinLibrary().packageFor(reference))
    }) { skinTransfer=SkinTransfer(it,share) }
    fun saveSkinDocument(open: () -> java.io.OutputStream) {
        val file=documentExport ?: return
        skinWork({ open().use { output -> file.inputStream().use { it.copyTo(output) } } }) {
            documentExport=null;skinNotice="Skin package saved."
        }
    }
    fun removeSkin(reference: SkinReference) {
        if(skinBusy) return
        skinBusy=true;skinError=null
        client.queueSkinRemoval(reference) { allowed ->
            skinBusy=false
            if(!allowed) { drainSkinRequests();return@queueSkinRemoval }
            skinWork({ skinLibrary().remove(reference);skinLibrary().installed() }) {
                installedSkins=it;skinLibraryChanged();client.flushSkinRemovals()
            }
        }
    }

    fun applySkin(reference: SkinReference, scheme: String) {
        val original=state.snapshot.selected ?: return
        skinWork({ SkinProfileLifecycle.apply(original,skinLibrary().packageFor(reference),scheme) }) {
            skinBusy=true;client.commitSkinChange(original,it,reference) { skinBusy=false;drainSkinRequests() }
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
            skinBusy=true;client.commitSkinChange(original,it,null) { skinBusy=false;drainSkinRequests() }
        }
    }
    override fun onCleared() { cleared=true;incomingSkinQueue.close();skinWorker.shutdownNow();sharedBuilds.close();client.dispose() }

    class Factory(private val context: Context) : ViewModelProvider.Factory {
        override fun <T : ViewModel> create(modelClass: Class<T>): T {
            require(modelClass == ControllerSession::class.java)
            val library by lazy { SkinLibrary(java.io.File(context.filesDir, "skins")) }
            return modelClass.cast(ControllerSession(ClientDependencies.sessionStore(context), NsdMacDiscovery(context),
                SkinRenderRepository { library.packageFor(it) }, { library },context.cacheDir,
                ClientDependencies.sharedBuildSession(context),java.io.File(context.noBackupFilesDir,"thumb-calibration")))!!
        }
    }
}
