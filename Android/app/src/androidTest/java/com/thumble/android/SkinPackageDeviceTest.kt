package com.thumble.android

import android.util.Base64
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class SkinPackageDeviceTest {
    private val instrumentation get()=InstrumentationRegistry.getInstrumentation()
    private val fixtureNames=listOf("solar-sumi-1.0.0-edbecde5b708.pocketpad","foldline-relay-1.0.0-d04c121e9b0a.pocketpad", "indigo-pocket-1.0.0-72fdbb32d789.pocketpad","tideglass-field-1.0.0-77927e956d14.pocketpad")
    @Test fun publishedArchivesPersistExportAndRenderReferencedImagesOnTheMinimumAPI() {
        val root=File(instrumentation.targetContext.noBackupFilesDir,"skin-acceptance-${UUID.randomUUID()}")
        val hashes=JSONObject()
        try {
            val store=SkinLibrary(root)
            for (name in fixtureNames) {
                val bytes=instrumentation.context.assets.open(name).use { it.readBytes() }
                val value=SkinPackageCodec.decode(bytes)
                assertEquals(SkinInstallChange.INSTALLED,store.install(bytes).change)
                assertEquals(SkinInstallChange.UNCHANGED,store.install(bytes).change)
                val reopened=SkinLibrary(root).packageFor(value.reference)
                assertArrayEquals(bytes,reopened.archiveBytes())
                val descriptor=reopened.manifestJSON().getJSONArray("assets").getJSONObject(0)
                val id=descriptor.getString("id")
                val data=reopened.asset(id)!!
                val library=JSONObject().put("assets",JSONArray().put(JSONObject().put("id",id).put("name",id)
                    .put("data",Base64.encodeToString(data,Base64.NO_WRAP))))
                val images=AssetImages(library)
                val image=images.image(JSONObject().put("assetID",id),64,64)
                assertNotNull("Native package image must decode on API ${android.os.Build.VERSION.SDK_INT}",image)
                assertTrue(image!!.intrinsicWidth>0 && image.intrinsicHeight>0)
                val exported=File(root,"export.pocketpad")
                exported.writeBytes(reopened.archiveBytes())
                assertEquals(value.reference,SkinPackageCodec.decode(exported.readBytes()).reference)
                exported.delete()
                hashes.put(name,JSONObject().put("archiveSHA256",value.archiveSHA256).put("imageWidth",image.intrinsicWidth).put("imageHeight",image.intrinsicHeight))
            }
            assertEquals(4,SkinLibrary(root).installed().size)
            val remove=store.installed().first().reference
            store.remove(remove)
            assertEquals(3,SkinLibrary(root).installed().size)
            val evidence=File(instrumentation.targetContext.getExternalFilesDir(null),"skin-package-result.json")
            evidence.writeText(JSONObject().put("sdk",android.os.Build.VERSION.SDK_INT).put("packages",hashes)
                .put("atomicPersistenceReload",true).put("exactArchiveExport",true).put("referencedImagesDecoded",true)
                .put("controllerSkinApplicationImplemented",false).toString(2))
        } finally { root.deleteRecursively() }
    }
    @Test fun corruptImportPreservesThePreviouslyInstalledPackageAndRejectsDuplicateJSON() {
        val root=File(instrumentation.targetContext.noBackupFilesDir,"skin-rejection-${UUID.randomUUID()}")
        try {
            val bytes=instrumentation.context.assets.open(fixtureNames.first()).use { it.readBytes() }
            val store=SkinLibrary(root);val reference=store.install(bytes).reference
            val corrupt=bytes.copyOf()
            // Flip the CRC in the manifest's central record without changing data.
            val central=(0 until corrupt.size-46).first { i -> corrupt[i]==0x50.toByte() && corrupt[i+1]==0x4b.toByte() && corrupt[i+2]==1.toByte() && corrupt[i+3]==2.toByte() }
            corrupt[central+16]=(corrupt[central+16].toInt() xor 1).toByte()
            try { store.install(corrupt,SkinInstallPolicy.ALLOW_DOWNGRADE);fail("Corrupt data must not replace a valid package") } catch (_: SkinPackageException) { }
            assertArrayEquals(bytes,SkinLibrary(root).archiveFor(reference))
            assertEquals(1,store.installed().size)
            val output=java.io.ByteArrayOutputStream()
            java.util.zip.ZipOutputStream(output).use { zip ->
                zip.putNextEntry(java.util.zip.ZipEntry("x.png"));zip.write(byteArrayOf(1,2,3));zip.closeEntry()
            }
            val legacy=output.toByteArray()
            val position=(0 until legacy.size-46).first { i -> legacy[i]==0x50.toByte() && legacy[i+1]==0x4b.toByte() && legacy[i+2]==1.toByte() && legacy[i+3]==2.toByte() }
            legacy[7]=(legacy[7].toInt() and 8.inv()).toByte();legacy[position+9]=(legacy[position+9].toInt() and 8.inv()).toByte()
            legacy[30]=0x82.toByte();legacy[position+46]=0x82.toByte()
            assertArrayEquals(byteArrayOf(1,2,3),PackageArchive.index(legacy).extract("é.png"))
            try { PackageJSON.objectValue("{\"id\":1,\"\\u0069d\":2}".toByteArray());fail("Android JSON must reject escaped duplicate keys") } catch (_: SkinPackageException) { }
        } finally { root.deleteRecursively() }
    }
}
