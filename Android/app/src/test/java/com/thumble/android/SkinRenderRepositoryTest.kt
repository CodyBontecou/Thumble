package com.thumble.android

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
import java.util.Base64
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.*

class SkinRenderRepositoryTest {
    @Test fun cancelledDisplayRequestsDoNotEnterBlockingResolutionBeforeLatestRequest() = runBlocking {
        val fixture=oracle();val pkg=packageValue(fixture)
        val entered=CountDownLatch(1);val release=CountDownLatch(1);val loads=AtomicInteger()
        val repository=SkinRenderRepository {
            loads.incrementAndGet();entered.countDown()
            check(release.await(5,TimeUnit.SECONDS));pkg
        }
        val local=fixture.getJSONObject("profiles").getJSONObject("arcadeStick")
        val first=launch(Dispatchers.Default) { repository.resolveForDisplay(profile(local,pkg.reference),false,false) }
        try {
            assertTrue(entered.await(5,TimeUnit.SECONDS))
            first.cancel()
            val superseded=(0 until 32).map {
                launch(start=CoroutineStart.UNDISPATCHED) {
                    repository.resolveForDisplay(profile(local,SkinReference(pkg.reference.identifier,"9.0.0")),false,false)
                }
            }
            superseded.forEach { it.cancel() }
            val latest=profile(local,pkg.reference)
            val result=async(start=CoroutineStart.UNDISPATCHED) { repository.resolveForDisplay(latest,false,false) }
            release.countDown();first.join();superseded.forEach { it.join() }
            assertTrue(superseded.all { it.isCancelled })
            assertSame(latest,withTimeout(5_000) { result.await() }.original)
            assertEquals("cancelled requests must not load their different skin",1,loads.get())
        } finally { release.countDown();first.cancelAndJoin() }
    }
    private fun oracle() = javaClass.classLoader!!.getResourceAsStream("skin-resolution/v1/native-profile-oracle.json")!!.use { JSONObject(it.bufferedReader().readText()) }
    private fun packageValue(v: JSONObject): SkinPackage {
        val data=v.getJSONObject("assetPayloads")
        return SkinPackage(byteArrayOf(),v.getJSONObject("manifest"),v.getJSONObject("skin"),null,
            data.keys().asSequence().associateWith { Base64.getDecoder().decode(data.getString(it)) },emptyMap())
    }
    private fun profile(local: JSONObject, reference: SkinReference): ControllerProfile = ControllerProfile.parse(JSONObject()
        .put("id",UUID.randomUUID().toString()).put("name","Native fixture").put("customization",JSONObject(local.toString()))
        .put("skinReference",JSONObject().put("identifier",reference.identifier).put("version",reference.version)))

    @Test fun orientationAndBaselineProjectionMatchesNativeAndLeavesSyncedProfileIntact() {
        val v=oracle();val pkg=packageValue(v);var loads=0
        val repository=SkinRenderRepository { loads++;pkg }
        val rows=v.getJSONArray("cases");var checked=0
        repeat(rows.length()) { index ->
            val row=rows.getJSONObject(index)
            if (!row.getBoolean("preserve")) return@repeat
            val local=v.getJSONObject("profiles").getJSONObject(row.getString("profile"))
            val p=profile(local,pkg.reference)
            val landscape=row.getString("orientation")=="landscape"
            p.source.getJSONObject("customization").put("colorSchemePreference",row.getString("scheme"))
            p.source.put(if(landscape) "landscapeCustomization" else "portraitCustomization",JSONObject(local.toString()))
            row.optString("baseline").takeIf { it.isNotEmpty() }?.let {
                p.source.put(if(index%2==0) "skinBaselineCustomization" else if(landscape) "landscapeSkinBaselineCustomization" else "portraitSkinBaselineCustomization",
                    v.getJSONObject("profiles").getJSONObject(it))
            }
            val before=p.source.toString()
            val result=repository.resolve(p,landscape,row.getString("scheme")!="dark")
            assertNull(result.warning);assertNotSame(p,result.profile)
            val expected=JSONObject(row.getJSONObject("expected").toString()).put("colorSchemePreference",row.getString("scheme"))
            assertTrue("Native projection $index",sameSkinJSON(expected,result.profile!!.layout(landscape)))
            assertEquals(before,p.source.toString())
            assertEquals(p.id,result.profile.id)
            assertSame(result,repository.resolve(p,landscape,row.getString("scheme")!="dark"))
            assertSame(result,repository.resolve(p.copy(),landscape,row.getString("scheme")!="dark"))
            assertFalse(result.matches(p,!landscape,row.getString("scheme")!="dark"))
            checked++
        }
        assertTrue(checked>40);assertEquals(1,loads)
    }

    @Test fun missingOrWrongVersionNeverUsesAnotherProfilesSkin() {
        val pkg=packageValue(oracle());var loads=0
        val repo=SkinRenderRepository { loads++;pkg }
        val local=oracle().getJSONObject("profiles").getJSONObject("arcadeStick")
        val valid=profile(local,pkg.reference)
        assertNull(repo.resolve(valid,false,false).warning)
        val missing=profile(local,SkinReference(pkg.reference.identifier,"9.0.0"))
        val unavailable=repo.resolve(missing,false,false)
        assertSame(missing,unavailable.profile);assertNotNull(unavailable.warning)
        assertNull(unavailable.compatibility);assertEquals(2,loads)
        assertNull(repo.resolve(valid,false,false).warning)
    }

    @Test fun installedArchiveRemovalAndReinstallationInvalidateAppearanceWithoutChangingSavedProfile() {
        val root=Files.createTempDirectory("skin-render-test").toFile()
        try {
            val bytes=javaClass.classLoader!!.getResourceAsStream("solar-sumi-1.0.0-edbecde5b708.pocketpad")!!.use { it.readBytes() }
            val library=SkinLibrary(root);val reference=library.install(bytes).reference
            val local=oracle().getJSONObject("profiles").getJSONObject("arcadeStick")
            val p=profile(local,reference);val before=p.source.toString()
            val repo=SkinRenderRepository.fromDirectory(root)
            val rendered=repo.resolve(p,true,true)
            assertNotSame(p,rendered.profile);assertNotNull(rendered.compatibility)
            library.remove(reference);repo.invalidate()
            assertSame(p,repo.resolve(p,true,true).profile)
            library.install(bytes);repo.invalidate()
            assertNotSame(p,repo.resolve(p,true,true).profile)
            assertEquals(before,p.source.toString())
        } finally { root.deleteRecursively() }
    }
}
