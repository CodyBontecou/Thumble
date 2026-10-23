package com.thumble.rewrite.input

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

class PhoneAuthorityResolverTest {
    private fun endpoint() = TrustedHostEndpoint("127.0.0.1", 1234, "aa".repeat(32), "old-owner")

    private fun hello(id: String = "new-owner") =
        """{"version":1,"command":"hello","authorityInstanceId":"$id","controlVersion":3,"inputVersion":1,"documentVersion":1,"capabilitiesVersion":1,"inputEnabled":false}"""

    private class IO(val text: String, val hang: Boolean = false) : NativeFrameIO {
        var sent = 0
        @Volatile var closed = false
        val release = CountDownLatch(1)

        override fun send(frame: ControlTLSFrame) {
            check(!closed)
            sent++
        }

        override fun receive(): ControlTLSFrame {
            if (hang) {
                check(release.await(2, TimeUnit.SECONDS))
                throw PhoneAuthorityResolutionRejected()
            }
            return ControlTLSFrame(ControlTLSFrame.Kind.CONTROL, text.toByteArray(Charsets.UTF_8))
        }

        override fun close() {
            closed = true
            release.countDown()
        }
    }

    private fun rejected(action: () -> Unit) {
        try {
            action()
            fail("accepted invalid resolution")
        } catch (error: Exception) {}
    }

    @Test
    fun preservesPinOneShotAndStrictAuthenticationRejectsRestart() {
        val old = endpoint()
        val io = IO(hello())
        val resolver = PhoneAuthorityResolver(old, { io })
        val result = resolver.resolve()
        assertEquals(old.host, result.host)
        assertEquals(old.port, result.port)
        assertEquals(old.certificatePin, result.certificatePin)
        assertEquals("new-owner", result.authorityInstanceID)
        assertTrue(io.closed)
        assertEquals(1, io.sent)
        rejected { resolver.resolve() }
        var loads = 0
        val next = IO(hello("another-owner"))
        val client =
            PhoneControlClient(
                result,
                { next },
                { _, _ ->
                    loads++
                    null
                },
                { 100 },
            )
        try {
            rejected { client.authenticate() }
        } finally {
            client.close()
        }
        assertEquals(0, loads)
        assertEquals(1, next.sent)
        assertTrue(next.release.await(2, TimeUnit.SECONDS))
        assertTrue(next.closed)
    }

    @Test
    fun rejectsMalformedSecretDuplicateWrongVersionAndOversize() {
        val good = hello()
        for (bad in
            listOf(
                good.replace("false", "true"),
                good.replace("\"controlVersion\":3", "\"controlVersion\":9"),
                good.replace(
                    "\"authorityInstanceId\":\"new-owner\"",
                    "\"authorityInstanceId\":null",
                ),
                good.dropLast(1) + ",\"token\":\"secret\"}",
                good.dropLast(1) + ",\"version\":1}",
                " ".repeat(4097) + good,
            )) {
            val io = IO(bad)
            rejected { PhoneAuthorityResolver(endpoint(), { io }).resolve() }
            assertTrue(io.closed)
            assertEquals(1, io.sent)
        }
    }

    @Test
    fun timeoutAndCanceledLateConnectCannotPublish() {
        val io = IO(hello(), true)
        rejected { PhoneAuthorityResolver(endpoint(), { io }, timeoutMillis = 20).resolve() }
        assertTrue(io.closed)
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val late = IO(hello())
        val resolver =
            PhoneAuthorityResolver(
                endpoint(),
                {
                    entered.countDown()
                    check(release.await(2, TimeUnit.SECONDS))
                    late
                },
            )
        val worker = Executors.newSingleThreadExecutor()
        try {
            val result =
                worker.submit<Boolean> {
                    try {
                        resolver.resolve()
                        false
                    } catch (error: Exception) {
                        true
                    }
                }
            assertTrue(entered.await(2, TimeUnit.SECONDS))
            resolver.close()
            release.countDown()
            assertTrue(result.get(2, TimeUnit.SECONDS))
            assertTrue(late.closed)
            assertEquals(0, late.sent)
        } finally {
            release.countDown()
            worker.shutdownNow()
        }
    }
}
