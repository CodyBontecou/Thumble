package com.thumble.android

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.nio.file.Files
import java.util.Base64
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream

class IncomingSkinSyncTest {
    private fun bytes(name: String=SkinPackageTest.fixtures.first()) = javaClass.classLoader!!.getResourceAsStream(name)!!.use { it.readBytes() }
    private fun batch(vararg archives: ByteArray): IncomingSkinPackages {
        val message=JSONObject().put("skinPackages",JSONArray().also { a -> archives.forEach { a.put(Base64.getEncoder().encodeToString(it)) } })
        return IncomingSkinPackages.validated(message,message.toString().toByteArray().size)!!
    }
    private fun editManifest(bytes: ByteArray, edit: (JSONObject)->Unit): ByteArray {
        val files=linkedMapOf<String,ByteArray>()
        ZipInputStream(ByteArrayInputStream(bytes)).use { zip ->
            while(true) { val entry=zip.nextEntry ?: break;files[entry.name]=zip.readBytes();zip.closeEntry() }
        }
        files["manifest.json"]=JSONObject(files.getValue("manifest.json").toString(Charsets.UTF_8)).also(edit).toString().toByteArray()
        val result=ByteArrayOutputStream()
        ZipOutputStream(result).use { zip -> files.forEach { (name,data) -> zip.putNextEntry(ZipEntry(name));zip.write(data);zip.closeEntry() } }
        return result.toByteArray()
    }
    @Test fun syncedDowngradeAndIndependentArchiveFailuresMatchNativeStorePolicy() {
        val root=Files.createTempDirectory("incoming-skin").toFile()
        try {
            val original=bytes();val newer=editManifest(original) { it.put("version","2.0.0") }
            val other=bytes(SkinPackageTest.fixtures[1]);val store=SkinLibrary(root)
            store.install(newer)
            val result=IncomingSkinSync.install(store,batch(original,"invalid archive".toByteArray(),other))
            assertNotNull(result.failure)
            assertEquals(setOf(SkinPackageCodec.decode(original).reference,SkinPackageCodec.decode(other).reference),result.changed)
            assertArrayEquals(original,store.archiveFor(SkinPackageCodec.decode(original).reference))
            assertEquals(3,result.installed!!.size)
        } finally { root.deleteRecursively() }
    }
    @Test fun invalidReplacementPreservesPriorBytesAndExactResyncDoesNotChangeAppearance() {
        val root=Files.createTempDirectory("incoming-skin-replace").toFile()
        try {
            val original=bytes();val store=SkinLibrary(root);val ref=store.install(original).reference
            val rejected=IncomingSkinSync.install(store,batch(byteArrayOf(1,2,3)))
            assertTrue(rejected.changed.isEmpty());assertNotNull(rejected.failure);assertArrayEquals(original,store.archiveFor(ref))
            val replaced=editManifest(original) { it.put("name","Synced metadata replacement") }
            assertEquals(setOf(ref),IncomingSkinSync.install(store,batch(replaced)).changed)
            assertArrayEquals(replaced,store.archiveFor(ref))
            val unchanged=IncomingSkinSync.install(store,batch(replaced))
            assertTrue(unchanged.changed.isEmpty());assertNull(unchanged.failure)
        } finally { root.deleteRecursively() }
    }
    @Test fun typedWireDataRejectsWholeMalformedBatchBeforeAnyInstallation() {
        for(value in listOf<Any>("invalid",JSONArray().put(5),JSONArray().put("not-base64"))) {
            try { IncomingSkinPackages.validated(JSONObject().put("skinPackages",value),100);fail("Malformed Data array must not enter installation") }
            catch(_:IllegalArgumentException) { } catch(_:org.json.JSONException) { }
        }
        val nativePadding=IncomingSkinPackages.validated(JSONObject().put("skinPackages",JSONArray().put("AA======")),100)!!
        assertArrayEquals(byteArrayOf(0),nativePadding.archive(0))
        assertNull(IncomingSkinPackages.validated(JSONObject().put("skinPackages",JSONObject.NULL),100))
    }
    @Test fun boundedWorkerRejectsOverflowRecoversCapacityAfterFailureAndCloses() {
        val payload=batch(bytes());val executor=Executors.newSingleThreadExecutor()
        val started=CountDownLatch(1);val release=CountDownLatch(1);val completed=CountDownLatch(3);val firstPair=CountDownLatch(2);val calls=AtomicInteger()
        val queue=SkinSyncQueue(executor,{ if(calls.incrementAndGet()==1) { started.countDown();check(release.await(5,TimeUnit.SECONDS));throw java.io.IOException("fixture") };SyncedSkinPackages(emptySet(),emptyList(),null) },
            { completed.countDown();firstPair.countDown() },maximumBytes=payload.wireBytes.toLong()*2)
        try {
            assertTrue(queue.submit(payload));assertTrue(started.await(5,TimeUnit.SECONDS))
            assertTrue(queue.submit(payload));assertFalse(queue.submit(payload))
            release.countDown()
            assertTrue(firstPair.await(5,TimeUnit.SECONDS))
            assertEquals(2,calls.get());assertTrue(queue.submit(payload))
            assertTrue(completed.await(5,TimeUnit.SECONDS));queue.close();assertFalse(queue.submit(payload))
        } finally { release.countDown();queue.close();executor.shutdownNow();assertTrue(executor.awaitTermination(5,TimeUnit.SECONDS)) }
        val attempts=AtomicInteger()
        val rejecting=SkinSyncQueue(java.util.concurrent.Executor { task -> if(attempts.incrementAndGet()==1) throw java.util.concurrent.RejectedExecutionException();task.run() },
            { SyncedSkinPackages(emptySet(),emptyList(),null) },{},maximumBatches=1)
        assertFalse(rejecting.submit(payload));assertTrue(rejecting.submit(payload));rejecting.close()
    }
}
