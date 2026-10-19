package com.thumble.android

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.nio.file.Files
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

class SkinPackageTest {
    private fun emptySkin()=JSONObject().put("base",JSONObject().put("roleRules",JSONArray()).put("buttonRules",JSONArray()).put("styleLibrary",JSONObject().put("styles",JSONArray())))
        .put("variants",JSONArray())
    private fun archive(version: String="1.0.0",skin: JSONObject=emptySkin(),asset: ByteArray?=null,edit: (JSONObject)->Unit={}): ByteArray {
        val files=linkedMapOf("skin.json" to skin.toString().toByteArray())
        val manifest=JSONObject().put("schema","com.codybontecou.pocketpad.skin-package").put("schemaVersion",1)
            .put("identifier","com.example.test-skin").put("version",version).put("kind","skin").put("name","Test skin")
            .put("author",JSONObject().put("name","Fixture")).put("summary","").put("license","MIT").put("tags",JSONArray())
            .put("skinPath","skin.json").put("skinSHA256",packageHash(files.getValue("skin.json")))
            .put("assets",JSONArray()).put("previews",JSONArray())
        asset?.let { files["assets/icon.png"]=it;manifest.getJSONArray("assets").put(JSONObject().put("id","icon").put("path","assets/icon.png")
            .put("contentType","image/png").put("role","icon").put("byteCount",it.size).put("sha256",packageHash(it))) }
        edit(manifest)
        files["manifest.json"]=manifest.toString().toByteArray()
        return zip(files)
    }
    private fun zip(files: Map<String,ByteArray>,stored: Boolean=false): ByteArray {
        val result=ByteArrayOutputStream()
        ZipOutputStream(result).use { zip -> for ((path,bytes) in files) {
            val entry=ZipEntry(path)
            if(stored) { entry.method=ZipEntry.STORED;entry.size=bytes.size.toLong();entry.compressedSize=bytes.size.toLong();entry.crc=java.util.zip.CRC32().apply { update(bytes) }.value }
            zip.putNextEntry(entry);zip.write(bytes);zip.closeEntry()
        } }
        return result.toByteArray()
    }
    private fun rejected(code: String,block: ()->Unit) {
        try { block();fail("Expected $code") } catch(e: SkinPackageException) { assertEquals(code,e.code) }
    }
    private fun u16(b: ByteArray,p: Int)=(b[p].toInt() and 255) or ((b[p+1].toInt() and 255) shl 8)
    private fun u32(b: ByteArray,p: Int)=u16(b,p).toLong() or (u16(b,p+2).toLong() shl 16)
    private fun put16(b: ByteArray,p: Int,v: Int) { b[p]=v.toByte();b[p+1]=(v ushr 8).toByte() }
    private fun put32(b: ByteArray,p: Int,v: Long) { repeat(4) { b[p+it]=(v ushr (it*8)).toByte() } }
    private fun centers(b: ByteArray): List<Int> {
        val result=mutableListOf<Int>();var p=u32(b,b.size-22+16).toInt()
        repeat(u16(b,b.size-22+10)) { result.add(p);p+=46+u16(b,p+28)+u16(b,p+30)+u16(b,p+32) }
        return result
    }
    @Test fun nativePublishedPackagesPreserveExactBytesAndVerifyAllResources() {
        for (name in fixtures) {
            val bytes=javaClass.classLoader!!.getResourceAsStream(name)!!.use { it.readBytes() }
            val packageValue=SkinPackageCodec.decode(bytes)
            assertTrue(packageValue.hasSkin);assertArrayEquals(bytes,packageValue.archiveBytes())
            val descriptors=packageValue.manifestJSON().getJSONArray("assets")
            assertEquals(4,descriptors.length())
            repeat(descriptors.length()) {
                val d=descriptors.getJSONObject(it);val data=packageValue.asset(d.getString("id"))!!
                assertEquals(d.getString("sha256"),packageHash(data));assertEquals(d.getInt("byteCount"),data.size)
                data.fill(0);assertNotEquals(packageHash(data),packageHash(packageValue.asset(d.getString("id"))!!))
            }
            packageValue.manifestJSON().put("identifier","corrupted")
            assertTrue(packageValue.reference.identifier.startsWith("com.codybontecou."))
        }
    }
    @Test fun archiveEnvelopeRejectsTraversalLinksDuplicatePathsAndHeaderMismatch() {
        rejected("unsafe-entry") { SkinPackageCodec.decode(zip(mapOf("../manifest.json" to byteArrayOf(1)))) }
        val link=archive();put32(link,centers(link).first()+38,0xa1ff0000L)
        rejected("unsupported-entry") { SkinPackageCodec.decode(link) }
        val duplicates=zip(linkedMapOf("skin.json" to byteArrayOf(1),"evil.json" to byteArrayOf(2)))
        val second=centers(duplicates)[1];"skin.json".toByteArray().copyInto(duplicates,second+46)
        rejected("duplicate-entry") { SkinPackageCodec.decode(duplicates) }
        val mismatch=archive();mismatch[30]='x'.code.toByte()
        rejected("invalid-archive") { SkinPackageCodec.decode(mismatch) }
        for (path in listOf("/root","~home/a","a/../b","a//b","a\\b","a/./b","a/\u0000b")) assertFalse(PackageArchive.safePath(path))
        assertTrue(PackageArchive.safePath("assets/example.png","assets"))
    }
    @Test fun legacyCP437NamesMatchNativeZIPDecoding() {
        val bytes=zip(mapOf("x.png" to byteArrayOf(1,2,3)))
        val center=centers(bytes).single()
        put16(bytes,6,u16(bytes,6) and 2048.inv());put16(bytes,center+8,u16(bytes,center+8) and 2048.inv())
        bytes[30]=0x82.toByte();bytes[center+46]=0x82.toByte()
        val index=PackageArchive.index(bytes)
        assertEquals(setOf("é.png"),index.paths)
        assertArrayEquals(byteArrayOf(1,2,3),index.extract("é.png"))
    }
    @Test fun crcManifestDigestsUnexpectedFilesAndResourceDigestsAreEnforced() {
        val corrupt=archive();val entry=centers(corrupt).first();put32(corrupt,entry+16,u32(corrupt,entry+16) xor 1)
        rejected("corrupt-entry") { SkinPackageCodec.decode(corrupt) }
        rejected("corrupt-entry") { SkinPackageCodec.decode(archive(edit={ it.put("skinSHA256","0".repeat(64)) })) }
        rejected("resource-integrity-mismatch") { SkinPackageCodec.decode(archive(asset=byteArrayOf(1,2,3),edit={ it.getJSONArray("assets").getJSONObject(0).put("sha256","0".repeat(64)) })) }
        val original=archive();val index=PackageArchive.index(original)
        val files=index.paths.associateWith { index.extract(it) }.toMutableMap();files["run.sh"]="echo no".toByteArray()
        rejected("unexpected-entry") { SkinPackageCodec.decode(zip(files)) }
    }
    @Test fun limitsApplyBeforeInflationAndRejectCompressionBombs() {
        val tooMany=archive();put16(tooMany,tooMany.size-22+8,257);put16(tooMany,tooMany.size-22+10,257)
        rejected("too-many-entries") { SkinPackageCodec.decode(tooMany) }
        val huge=archive();put32(huge,centers(huge).first()+24,PackageArchive.MAX_ENTRY+1L)
        rejected("entry-too-large") { SkinPackageCodec.decode(huge) }
        rejected("compression-ratio-too-high") { SkinPackageCodec.decode(zip(mapOf("README.md" to ByteArray(100_000)))) }
        val pattern=ByteArray(16*1024).also { java.util.Random(7).nextBytes(it) }
        val payload=ByteArray(9*1024*1024) { pattern[it%pattern.size] }
        val total=zip((0..5).associate { "asset$it.png" to payload })
        rejected("archive-too-large") { SkinPackageCodec.decode(total) }
    }
    @Test fun smallZip64ArchiveUsesTheSameBoundsAndIntegrityChecks() {
        val input=archive();val end=input.size-22;val zip64=ByteArray(76)
        put32(zip64,0,0x06064b50);put32(zip64,4,44);put16(zip64,12,45);put16(zip64,14,45)
        put32(zip64,24,u16(input,end+10).toLong());put32(zip64,32,u16(input,end+10).toLong())
        put32(zip64,40,u32(input,end+12));put32(zip64,48,u32(input,end+16))
        put32(zip64,56,0x07064b50);put32(zip64,64,end.toLong());put32(zip64,72,1)
        val tail=input.copyOfRange(end,input.size);put16(tail,8,65535);put16(tail,10,65535);put32(tail,12,0xffffffff);put32(tail,16,0xffffffff)
        val result=SkinPackageCodec.decode(input.copyOfRange(0,end)+zip64+tail)
        assertEquals("com.example.test-skin",result.reference.identifier)
    }
    @Test fun zip64EntrySizesOffsetsAndSingleDiskFieldsAreDecoded() {
        val source=archive();val index=PackageArchive.index(source)
        val input=zip(index.paths.associateWith { index.extract(it) },stored=true)
        val first=centers(input).first();val name=u16(input,first+28);assertEquals(0,u16(input,first+30))
        val header=input.copyOfRange(first,first+46+name);val extra=ByteArray(32)
        put16(extra,0,1);put16(extra,2,28)
        put32(extra,4,u32(input,first+24));put32(extra,12,u32(input,first+20));put32(extra,20,u32(input,first+42));put32(extra,28,0)
        put16(header,6,45);put16(header,30,32);put16(header,34,65535)
        put32(header,20,0xffffffff);put32(header,24,0xffffffff);put32(header,42,0xffffffff)
        val result=input.copyOfRange(0,first)+header+extra+input.copyOfRange(first+46+name,input.size)
        val end=result.size-22;put32(result,end+12,u32(input,input.size-22+12)+extra.size)
        assertEquals("com.example.test-skin",SkinPackageCodec.decode(result).reference.identifier)
    }
    @Test fun jsonValidationRejectsDuplicateEscapedKeysInvalidNumbersAndTrailingData() {
        for (text in listOf("{\"x\":1,\"\\u0078\":2}","{\"x\":NaN}","{\"x\":01}","{}[]","{\"x\":1e9999}","{\"x\":\"bad\\q\"}")) {
            assertTrue(runCatching { PackageJSON.objectValue(text.toByteArray()) }.isFailure)
        }
        assertTrue(runCatching { PackageJSON.objectValue(("[".repeat(130)+"0"+"]".repeat(130)).toByteArray()) }.isFailure)
        val values=PackageJSON.objectValue("{\"false\":false,\"zero\":0,\"empty\":null}".toByteArray())
        assertEquals(false,values.get("false"));assertEquals(0L,values.getLong("zero"));assertTrue(values.isNull("empty"))
    }
    @Test fun executableResourcesAndUndeclaredAssetsOrStylesAreRejected() {
        rejected("executable-asset") { SkinPackageCodec.decode(archive(asset=byteArrayOf(1),edit={ it.getJSONArray("assets").getJSONObject(0).put("contentType","application/javascript") })) }
        val missing=emptySkin();missing.getJSONObject("base").put("backgroundFillStyle",JSONObject().put("kind","image").put("image",JSONObject().put("assetID","missing").put("contentMode","fill").put("opacity",1)
            .put("exposure",0).put("contrast",0).put("saturation",0).put("temperature",0).put("tint",0).put("highlights",0).put("shadows",0)))
        rejected("missing-asset-reference") { SkinPackageCodec.decode(archive(skin=missing)) }
        val style=emptySkin();style.getJSONObject("base").put("defaultControl",JSONObject().put("styleID","missing"))
        rejected("missing-style-reference") { SkinPackageCodec.decode(archive(skin=style)) }
        rejected("unexpected-profile") { SkinPackageCodec.decode(archive(edit={ it.put("profilePath","profile.json") })) }
    }
    @Test fun libraryPoliciesAndPersistencePreserveArchivesAcrossReload() {
        val root=Files.createTempDirectory("skin-library-").toFile()
        try {
            val store=SkinLibrary(root);val first=archive();val id=SkinPackageCodec.decode(first).reference
            assertEquals(SkinInstallChange.INSTALLED,store.install(first).change)
            assertEquals(SkinInstallChange.UNCHANGED,store.install(first).change)
            val changed=archive(edit={ it.put("name","Changed") })
            rejected("version-already-installed") { store.install(changed) }
            assertEquals(SkinInstallChange.REPLACED,store.install(changed,SkinInstallPolicy.REPLACE_SAME_VERSION).change)
            assertEquals(SkinInstallChange.UPDATED,store.install(archive("2.0.0")).change)
            rejected("newer-version-installed") { store.install(archive("0.5.0")) }
            store.install(archive("0.5.0"),SkinInstallPolicy.ALLOW_DOWNGRADE)
            val reloaded=SkinLibrary(root)
            assertEquals(3,reloaded.installed().size);assertArrayEquals(changed,reloaded.archiveFor(id))
            assertEquals("2.0.0",reloaded.latest(id.identifier)!!.reference.version)
            reloaded.remove(id);assertEquals(2,reloaded.installed().size)
        } finally { root.deleteRecursively() }
    }
    @Test fun libraryHashesPhysicalNamesAndRefusesSymlinkRedirection() {
        val root=Files.createTempDirectory("skin-safe-").toFile();val outside=Files.createTempDirectory("skin-outside-").toFile()
        try {
            val bytes=archive("1.0.0-../../outside");val store=SkinLibrary(root);val id=SkinPackageCodec.decode(bytes).reference
            store.install(bytes);assertArrayEquals(bytes,store.archiveFor(id));assertTrue(outside.list()!!.isEmpty())
            val directory=root.listFiles()!!.single();directory.deleteRecursively();Files.createSymbolicLink(directory.toPath(),outside.toPath())
            rejected("invalid-store-path") { store.archiveFor(id) }
            rejected("invalid-store-path") { store.install(bytes) }
        } finally { root.deleteRecursively();outside.deleteRecursively() }
    }
    @Test fun semanticVersionsFollowNativeCoreBuildAndNaturalPrereleaseOrder() {
        assertTrue(SkinVersion.parse("1.0.0-rc2")!! < SkinVersion.parse("1.0.0-rc10")!!)
        assertTrue(SkinVersion.parse("1.0.0-rc10")!! < SkinVersion.parse("1.0.0")!!)
        assertEquals(0,SkinVersion.parse("01.0.0+one")!!.compareTo(SkinVersion.parse("1.0.0+two")!!))
        assertNull(SkinVersion.parse("1.0"));assertNull(SkinVersion.parse("1.0.0-"))
    }
    @Test fun baseActionSetStyleReferencesUseTheNativeCascade() {
        val skin=emptySkin()
        skin.getJSONObject("base").put("defaultControl",JSONObject().put("styleID","bank-only"))
        val appearance=JSONObject(emptySkin().getJSONObject("base").toString())
        appearance.getJSONObject("styleLibrary").getJSONArray("styles").put(JSONObject().put("id","bank-only").put("name","Bank")
            .put("visualStyle",JSONObject().put("normal",JSONObject().put("opacity",.8))))
        skin.getJSONArray("variants").put(JSONObject().put("id","base-bank").put("actionSet","base").put("appearance",appearance))
        fun bytes()=archive(skin=skin,edit={ manifest -> manifest.put("schemaVersion",2).put("compatibility",JSONObject()
            .put("mode","universal").put("orientations",JSONArray(listOf("portrait","landscape"))).put("templates",JSONArray())
            .put("requiredRoles",JSONArray()).put("requiredFeatures",JSONArray(listOf("action_set_layers")))) })
        assertTrue(SkinPackageCodec.decode(bytes()).hasSkin)
        appearance.getJSONObject("styleLibrary").put("styles",JSONArray())
        rejected("missing-style-reference") { SkinPackageCodec.decode(bytes()) }
    }
    @Test fun malformedNestedAppearanceCannotReplaceAnInstalledPackage() {
        val root=Files.createTempDirectory("skin-model-transaction-").toFile()
        try {
            val store=SkinLibrary(root);val original=archive();val reference=store.install(original).reference
            val bad=emptySkin().apply { getJSONObject("base").put("defaultControl",JSONObject().put("shadowStrength","invalid")) }
            rejected("invalid-skin-model") { store.install(archive(skin=bad),SkinInstallPolicy.REPLACE_SAME_VERSION) }
            assertArrayEquals(original,SkinLibrary(root).archiveFor(reference))
        } finally { root.deleteRecursively() }
    }
    @Test fun malformedCapturedMetadataCannotReplaceAnInstalledPackage() {
        val root=Files.createTempDirectory("skin-contract-transaction-").toFile()
        try {
            val oracle=javaClass.classLoader!!.getResourceAsStream("skin-resolution/v1/native-contract-oracle.json")!!.use { JSONObject(it.bufferedReader().readText()) }
            val compatibility=JSONObject(oracle.getJSONObject("bases").getJSONObject("rich").toString())
            fun bytes()=archive(edit={ it.put("schemaVersion",2).put("compatibility",compatibility) })
            val store=SkinLibrary(root);val original=bytes();val reference=store.install(original).reference
            compatibility.getJSONObject("capturedGeometry").getJSONArray("variants").getJSONObject(0)
                .getJSONObject("nativeLayout").getJSONArray("chromeSamples").getJSONObject(0).put("isConnected","invalid")
            rejected("invalid-skin-contract") { store.install(bytes(),SkinInstallPolicy.REPLACE_SAME_VERSION) }
            assertArrayEquals(original,SkinLibrary(root).archiveFor(reference))
        } finally { root.deleteRecursively() }
    }
    companion object {
        val fixtures=listOf("solar-sumi-1.0.0-edbecde5b708.pocketpad","foldline-relay-1.0.0-d04c121e9b0a.pocketpad", "indigo-pocket-1.0.0-72fdbb32d789.pocketpad","tideglass-field-1.0.0-77927e956d14.pocketpad")
    }
}
