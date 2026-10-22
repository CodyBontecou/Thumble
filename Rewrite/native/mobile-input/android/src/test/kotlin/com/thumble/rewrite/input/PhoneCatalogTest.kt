package com.thumble.rewrite.input

import java.util.ArrayDeque
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class PhoneCatalogTest {
    private val binding = "a".repeat(32)

    private fun endpoint() = TrustedHostEndpoint("127.0.0.1", 1234, "11".repeat(32), "authority-a")

    private fun credential() =
        PhoneCredential(
            PhoneCredentialMetadata("11".repeat(32), "phone-a", 1, 100000),
            ByteArray(32) { 34 },
        )

    private fun hello(role: String = "management") =
        JSONObject()
            .put("version", 1)
            .put("command", "hello")
            .put("authorityInstanceId", "authority-a")
            .put("controlVersion", 7)
            .put("role", role)
            .put("inputVersion", 1)
            .put("documentVersion", 1)
            .put("capabilitiesVersion", 1)
            .put("inputEnabled", false)

    private fun admission(input: Boolean = false) =
        JSONObject()
            .put("version", 1)
            .put("command", "authenticated")
            .put("authorityInstanceId", "authority-a")
            .put("phoneId", "phone-a")
            .put("credentialEpoch", "1")
            .put("connectionId", binding)
            .put("expiresAt", 60100)
            .put("role", "management")
            .put("inputSessionAvailable", input)
            .put("inputEnabled", false)

    private fun page() =
        JSONObject()
            .put("version", 1)
            .put("command", "configuration-result")
            .put("connectionId", binding)
            .put("kind", "catalog")
            .put("revision", "18446744073709551615")
            .put("contentHash", "b".repeat(64))
            .put("activeProfileId", JSONObject.NULL)
            .put("defaultProfileId", JSONObject.NULL)
            .put("nextOffset", JSONObject.NULL)
            .put("profileCount", 1)
            .put("profile0Id", "00000000-0000-0000-0000-000000000001")
            .put("profile0Name", "Synthetic 😀")
            .put("profile0UpdatedAt", "9223372036854775807")

    private class IO(fields: List<JSONObject>) : NativeFrameIO {
        val frames =
            ArrayDeque(
                fields.map {
                    ControlTLSFrame(
                        ControlTLSFrame.Kind.CONTROL,
                        it.toString().toByteArray(Charsets.UTF_8),
                    )
                }
            )
        val sent = mutableListOf<Map<String, EnrollmentJSON.Value>>()
        var closed = false

        override fun send(frame: ControlTLSFrame) {
            check(!closed)
            sent.add(EnrollmentJSON.parse(frame.payload, allowNull = true))
        }

        override fun receive(): ControlTLSFrame {
            check(!closed)
            return frames.removeFirst()
        }

        override fun close() {
            closed = true
        }
    }

    private fun rejects(action: () -> Unit) {
        try {
            action()
            fail("catalog accepted")
        } catch (_: PhoneCatalogRejected) {}
    }

    @Test
    fun dedicatedManagementReadProjectsOnlyPublicMetadata() {
        val io = IO(listOf(hello(), admission(), page()))
        var loads = 0
        val client =
            PhoneCatalogClient(
                endpoint(),
                { io },
                { _, _ ->
                    loads++
                    credential()
                },
                { 100 },
            )
        val result = client.read() as PhoneCatalogResult.Catalog
        assertEquals("18446744073709551615", result.page.revision)
        assertEquals("Synthetic 😀", result.page.profiles.single().name)
        assertEquals(
            listOf("hello", "authenticate", "configuration-list"),
            io.sent.map { (it["command"] as EnrollmentJSON.Value.Text).value },
        )
        assertEquals(EnrollmentJSON.Value.Text("management"), io.sent.first()["role"])
        assertEquals(1, loads)
        assertTrue(io.closed)
        assertFalse(
            result.bridgeMetadata().keys.any {
                it in setOf("credential", "connectionId", "host", "phoneId")
            }
        )
        rejects { client.read() }
    }

    @Test
    fun downgradeInputCapabilityAndMalformedResultsAreRejected() {
        for (role in listOf("input", "")) {
            val io = IO(listOf(hello(role)))
            var loads = 0
            rejects {
                PhoneCatalogClient(
                        endpoint(),
                        { io },
                        { _, _ ->
                            loads++
                            credential()
                        },
                        { 100 },
                    )
                    .read()
            }
            assertEquals(0, loads)
            assertTrue(io.closed)
        }
        val input = IO(listOf(hello(), admission(true)))
        rejects {
            PhoneCatalogClient(endpoint(), { input }, { _, _ -> credential() }, { 100 }).read()
        }
        assertEquals(2, input.sent.size)
        for ((key, value) in
            listOf(
                "connectionId" to "c".repeat(32),
                "revision" to "01",
                "profileCount" to 17,
                "profile0Id" to "bad",
                "profile0UpdatedAt" to "9223372036854775808",
                "nextOffset" to 1,
                "profile0Name" to "😀".repeat(257),
                "credential" to "secret",
            )) {
            val io = IO(listOf(hello(), admission(), page().put(key, value)))
            rejects {
                PhoneCatalogClient(endpoint(), { io }, { _, _ -> credential() }, { 100 }).read()
            }
            assertTrue(io.closed)
        }
    }

    @Test
    fun closeDuringNativeCredentialLoadPreventsAuthenticationAndClosesConnection() {
        val io = IO(listOf(hello(), admission(), page()))
        val entered = CountDownLatch(1)
        val resume = CountDownLatch(1)
        val client =
            PhoneCatalogClient(
                endpoint(),
                { io },
                { _, _ ->
                    entered.countDown()
                    check(resume.await(2, TimeUnit.SECONDS))
                    credential()
                },
                { 100 },
            )
        val executor = Executors.newSingleThreadExecutor()
        try {
            val task = executor.submit { rejects { client.read() } }
            assertTrue(entered.await(1, TimeUnit.SECONDS))
            client.close()
            resume.countDown()
            task.get(2, TimeUnit.SECONDS)
            assertEquals(1, io.sent.size)
            assertTrue(io.closed)
        } finally {
            resume.countDown()
            client.close()
            executor.shutdownNow()
        }
    }

    @Test
    fun paginationUnicodeAndDuplicateIDsMatchSavedCatalogContract() {
        fun full(): JSONObject {
            val result = page().put("profileCount", 16).put("nextOffset", 16)
            for (index in 0..15) {
                result.put("profile${index}Id", "00000000-0000-0000-0000-%012d".format(index + 1))
                result.put("profile${index}Name", if (index == 0) "\u0085" else "😀".repeat(256))
                result.put("profile${index}UpdatedAt", "0")
            }
            return result
        }
        fun read(result: JSONObject): PhoneCatalogResult {
            val io = IO(listOf(hello(), admission(), result))
            return PhoneCatalogClient(endpoint(), { io }, { _, _ -> credential() }, { 100 }).read()
        }
        val result = read(full()) as PhoneCatalogResult.Catalog
        assertEquals(16, result.page.nextOffset)
        assertEquals(16, result.page.profiles.size)
        assertEquals("\u0085", result.page.profiles[0].name)
        rejects { read(full().put("profile0Name", "\uFEFF\u2000\n")) }
        rejects { read(full().put("profile1Id", "00000000-0000-0000-0000-000000000001")) }
        rejects { read(full().put("nextOffset", 32)) }
    }
}
