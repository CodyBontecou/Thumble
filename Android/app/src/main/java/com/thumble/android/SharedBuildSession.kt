package com.thumble.android

import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.nio.file.Path
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

internal data class SharedBuildReview(val id: UUID,val artifactID: String,val sourceHost: String,val artifact: PortableProfileArtifact)

/** Retained UI coordinator. References/tokens never enter review or quarantine metadata. */
internal class SharedBuildSession(private val directory: Path,private val localTesting: Boolean=false) {
    var review by mutableStateOf<SharedBuildReview?>(null);private set
    var records by mutableStateOf<List<PendingSharedBuild>>(emptyList());private set
    var fetching by mutableStateOf(false);private set
    var busy by mutableStateOf(false);private set
    var error by mutableStateOf<String?>(null);private set
    var requestedPreviewID by mutableStateOf<UUID?>(null);private set
    var onPreview: (UUID,ProfileSnapshot)->Unit={ _,_ -> }
    var onAdopt: (PendingSharedBuild,PortableProfileArtifact,UUID,(Boolean)->Unit)->Unit={ _,_,_,done -> done(false) }
    var onCancelAdoption: ()->Unit={}
    var adoption by mutableStateOf<ArtifactAdoptionState?>(null);private set
    private var handledTerminal: Pair<UUID,ArtifactAdoptionPhase>?=null
    private val main=Handler(Looper.getMainLooper())
    private val worker=Executors.newSingleThreadExecutor()
    private val fetcher=BuilderArtifactFetcher()
    private var call: okhttp3.Call?=null
    private var activeArtifactID: String?=null
    private var epoch=0L
    private var closed=false
    private var store: PendingSharedBuildStore?=null
    private fun store()=store ?: PendingSharedBuildStore(directory).also { it.recoverInterruptedAdoptions();store=it }
    init { refresh() }
    private fun submit(work: ()->Unit) { try { worker.execute(work) } catch(_: RejectedExecutionException) {} }
    fun route(raw: String): Boolean {
        val reference=try { BuilderArtifactShare.parse(raw,localTesting) }
        catch(failure: SharedBuildException) {
            if(!BuilderArtifactShare.resembles(raw)) return false
            error=failure.message;return true
        }
        if(activeArtifactID==reference.artifactID || review?.artifactID==reference.artifactID) return true
        call?.cancel();val request=++epoch
        activeArtifactID=reference.artifactID;fetching=true;error=null
        call=try { fetcher.fetch(reference) { result -> submit {
            val artifact=result.mapCatching { PortableProfileArtifact.decode(it) }
            main.post { if(!closed && epoch==request) {
                fetching=false;call=null;activeArtifactID=null
                artifact.fold({ review=SharedBuildReview(UUID.randomUUID(),reference.artifactID,reference.sourceHost,it) },
                    { failure -> error=(failure as? SharedBuildException)?.message ?: "The shared build could not be opened." })
            } }
        } } } catch(_: Exception) {
            fetching=false;activeArtifactID=null;error="The shared build could not be downloaded.";null
        }
        return true
    }
    fun cancelDownload() { epoch++;call?.cancel();call=null;activeArtifactID=null;fetching=false }
    fun cancelReview() { if(!busy) review=null }
    fun openLink(raw: String) { if(!route(raw)) error="This is not a valid Thumble shared-build link." }
    fun consumePreviewRequest() { requestedPreviewID=null }
    fun dismissError() { error=null }
    fun refresh() { submit {
        val result=runCatching { store().list() }
        main.post { if(!closed) result.fold({ records=it },{ error="Pending shared builds could not be loaded." }) }
    } }
    fun keep() {
        val value=review ?: return
        if(busy) return
        busy=true;error=null
        submit {
            val result=runCatching { val saved=store().save(value.artifact);Triple(saved,store().list(),value.artifact.profileSnapshot()) }
            main.post { if(!closed) {
                busy=false
                result.fold({ (record,updated,snapshot) -> records=updated;if(review?.id==value.id) review=null;requestedPreviewID=record.id;onPreview(record.id,snapshot) },
                    { error="The shared build could not be kept on this Android device." })
            } }
        }
    }
    fun preview(id: UUID) {
        if(busy) return
        busy=true;error=null
        submit {
            val result=runCatching { store().load(id).profileSnapshot() to store().list() }
            main.post { if(!closed) {
                busy=false
                result.fold({ (snapshot,updated) -> records=updated;requestedPreviewID=id;onPreview(id,snapshot) },{ error="The pending shared build could not be opened.";refresh() })
            } }
        }
    }
    fun delete(id: UUID) {
        if(busy) return
        busy=true;error=null
        submit {
            val result=runCatching { store().delete(id);store().list() }
            main.post { if(!closed) { busy=false;result.fold({ records=it },{ error="The pending shared build could not be deleted." }) } }
        }
    }
    fun adopt(id: UUID,serverID: String) {
        if(busy || adoption?.active==true || !ArtifactAdoptionMetadata.validServer(serverID)) return
        busy=true;error=null
        submit {
            val prepared=runCatching {
                val current=store().list().firstOrNull { it.id==id } ?: throw PendingBuildStoreException()
                if(current.state==PendingBuildState.ADOPTED) throw PendingBuildStoreException()
                val artifact=store().load(id)
                val operation=if(current.intendedServerID==serverID) current.operationID ?: UUID.randomUUID() else UUID.randomUUID()
                val updated=store().update(id,PendingBuildState.ADOPTING,operation,serverID)
                Triple(updated,artifact,operation) to store().list()
            }
            main.post { if(!closed) {
                busy=false
                prepared.fold({ (value,updated) ->
                    records=updated;handledTerminal=null
                    val (record,artifact,operation)=value
                    onAdopt(record,artifact,operation) { started ->
                        if(!started && !closed) observeAdoption(ArtifactAdoptionState(ArtifactAdoptionMetadata.forRecord(record,serverID,operation),ArtifactAdoptionPhase.FAILED,record.profiles.size,errorCode="unsupported"))
                    }
                },{ error="The shared build could not be prepared for adoption. Your kept build is still on this device.";refresh() })
            } }
        }
    }
    fun observeAdoption(value: ArtifactAdoptionState?) {
        adoption=value
        if(value==null) return
        if(value.active) { handledTerminal=null;return }
        val key=value.metadata.operationID to value.phase
        if(handledTerminal==key) return
        handledTerminal=key
        submit {
            val result=runCatching {
                val record=store().list().firstOrNull { it.id==value.metadata.recordID }
                if(record!=null && record.operationID==value.metadata.operationID && record.intendedServerID==value.metadata.serverID &&
                    record.contentHash==value.metadata.contentHash && record.rawSHA256==value.metadata.rawSHA256) {
                    if(value.phase==ArtifactAdoptionPhase.SUCCEEDED) {
                        store().update(record.id,PendingBuildState.ADOPTED,value.metadata.operationID,value.metadata.serverID)
                        store().delete(record.id)
                    } else store().update(record.id,PendingBuildState.FAILED,value.metadata.operationID,value.metadata.serverID,value.errorCode ?: "disconnected")
                }
                store().list()
            }
            main.post { if(!closed) result.fold({ records=it },{
                error="The adoption result could not be saved on this device. The kept build has been retained.";refresh()
            }) }
        }
    }
    fun close() { closed=true;epoch++;call?.cancel();call=null;worker.shutdownNow() }
}
