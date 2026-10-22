package com.thumble.rewrite.input

import java.net.InetSocketAddress
import java.util.ArrayDeque
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

class PhoneControlTest {
    private fun fixture() =
        javaClass.classLoader!!.getResourceAsStream("authenticated-control-v3.json")!!.use {
            JSONObject(it.readBytes().toString(Charsets.UTF_8))
        }

    private fun endpoint() = TrustedHostEndpoint("127.0.0.1", 1234, "11".repeat(32), "authority-a")

    private fun credential(pin: String = "11".repeat(32), expires: Long = 100000) =
        PhoneCredential(PhoneCredentialMetadata(pin, "phone-a", 1, expires), ByteArray(32) { 34 })

    private class FakeIO(values: List<JSONObject>) : NativeFrameIO {
        val frames =
            ArrayDeque(
                values.map {
                    ControlTLSFrame(
                        ControlTLSFrame.Kind.CONTROL,
                        it.toString().toByteArray(Charsets.UTF_8),
                    )
                }
            )
        val sent = CopyOnWriteArrayList<String>()
        val closed = CountDownLatch(1)
        var pauseNext = false
        val paused = CountDownLatch(1)
        val resume = CountDownLatch(1)

        override fun send(frame: ControlTLSFrame) {
            if (closed.count == 0L) throw PhoneControlRejected()
            sent.add(
                (EnrollmentJSON.parse(frame.payload)["command"] as EnrollmentJSON.Value.Text).value
            )
        }

        override fun receive(): ControlTLSFrame {
            if (pauseNext) {
                pauseNext = false
                paused.countDown()
                check(resume.await(2, TimeUnit.SECONDS))
            }
            return frames.pollFirst() ?: throw PhoneControlRejected()
        }

        override fun close() {
            closed.countDown()
        }
    }

    private fun rejects(action: () -> Unit) {
        try {
            action()
            fail("control accepted")
        } catch (_: PhoneControlRejected) {}
    }

    @Test
    fun authenticatesStatusAndDisconnectWithoutExposingBearer() {
        val f = fixture()
        val io =
            FakeIO(
                listOf("hello", "authenticated", "status", "disconnected").map {
                    f.getJSONObject(it)
                }
            )
        var loads = 0
        val client =
            PhoneControlClient(
                endpoint(),
                { io },
                { _, _ ->
                    loads++
                    credential()
                },
                { 1000 },
            )
        rejects { client.status() }
        val receipt = client.authenticate()
        rejects { client.authenticate() }
        assertEquals("phone-a", receipt.phoneID)
        assertFalse(receipt.inputSessionAvailable)
        assertEquals(receipt, client.status())
        client.disconnect()
        assertTrue(io.closed.await(1, TimeUnit.SECONDS))
        assertEquals(listOf("hello", "authenticate", "control-status", "disconnect"), io.sent)
        assertEquals(1, loads)
        rejects { client.authenticate() }
        rejects { client.status() }
    }

    @Test
    fun wrongHelloNeverReadsVaultOrSendsBearer() {
        for ((key, value) in
            listOf(
                "controlVersion" to 2,
                "authorityInstanceId" to "other",
                "inputEnabled" to true,
                "credential" to "unexpected",
            )) {
            val io = FakeIO(listOf(fixture().getJSONObject("hello").put(key, value)))
            var loads = 0
            val client =
                PhoneControlClient(
                    endpoint(),
                    { io },
                    { _, _ ->
                        loads++
                        credential()
                    },
                    { 1000 },
                )
            rejects { client.authenticate() }
            assertEquals(0, loads)
            assertEquals(listOf("hello"), io.sent)
            assertTrue(io.closed.await(1, TimeUnit.SECONDS))
        }
    }

    @Test
    fun missingExpiredAndForeignCredentialsNeverAuthenticate() {
        for (value in listOf(null, credential("22".repeat(32)), credential(expires = 1000))) {
            val io = FakeIO(listOf(fixture().getJSONObject("hello")))
            val client = PhoneControlClient(endpoint(), { io }, { _, _ -> value }, { 1000 })
            rejects { client.authenticate() }
            assertEquals(listOf("hello"), io.sent)
            assertTrue(io.closed.await(1, TimeUnit.SECONDS))
        }
    }

    @Test
    fun malformedAdmissionAndChangingConnectionFailTerminally() {
        for ((key, value) in
            listOf(
                "credentialEpoch" to "01",
                "credentialEpoch" to "2",
                "phoneId" to "other",
                "connectionId" to "A".repeat(32),
                "expiresAt" to 1000,
                "expiresAt" to 100001,
                "inputSessionAvailable" to true,
                "inputEnabled" to true,
                "credential" to "leak",
            )) {
            val f = fixture()
            val io =
                FakeIO(
                    listOf(
                        f.getJSONObject("hello"),
                        f.getJSONObject("authenticated").put(key, value),
                    )
                )
            val client = PhoneControlClient(endpoint(), { io }, { _, _ -> credential() }, { 1000 })
            rejects { client.authenticate() }
            assertTrue(io.closed.await(1, TimeUnit.SECONDS))
        }
        val f = fixture()
        val io =
            FakeIO(
                listOf(
                    f.getJSONObject("hello"),
                    f.getJSONObject("authenticated"),
                    f.getJSONObject("status").put("connectionId", "b".repeat(32)),
                )
            )
        val client = PhoneControlClient(endpoint(), { io }, { _, _ -> credential() }, { 1000 })
        client.authenticate()
        rejects { client.status() }
        assertTrue(io.closed.await(1, TimeUnit.SECONDS))
    }

    @Test
    fun lateVaultReadAndConnectCannotAuthenticateAfterClose() {
        val workers = Executors.newSingleThreadExecutor()
        try {
            for (pauseConnect in listOf(false, true)) {
                val entered = CountDownLatch(1)
                val resume = CountDownLatch(1)
                val io = FakeIO(listOf(fixture().getJSONObject("hello")))
                val client =
                    PhoneControlClient(
                        endpoint(),
                        {
                            if (pauseConnect) {
                                entered.countDown()
                                assertTrue(resume.await(2, TimeUnit.SECONDS))
                            }
                            io
                        },
                        { _, _ ->
                            if (!pauseConnect) {
                                entered.countDown()
                                assertTrue(resume.await(2, TimeUnit.SECONDS))
                            }
                            credential()
                        },
                        { 1000 },
                    )
                val pending = workers.submit { rejects { client.authenticate() } }
                assertTrue(entered.await(2, TimeUnit.SECONDS))
                client.close()
                resume.countDown()
                pending.get(2, TimeUnit.SECONDS)
                assertTrue(io.closed.await(1, TimeUnit.SECONDS))
                assertFalse(io.sent.contains("authenticate"))
            }
        } finally {
            workers.shutdownNow()
        }
    }

    @Test
    fun clockRollbackAndLeaseExpiryNeverSendAgain() {
        for (time in listOf(999L, 61000L)) {
            var now = 1000L
            val f = fixture()
            val io = FakeIO(listOf(f.getJSONObject("hello"), f.getJSONObject("authenticated")))
            val client = PhoneControlClient(endpoint(), { io }, { _, _ -> credential() }, { now })
            client.authenticate()
            now = time
            rejects { client.status() }
            assertEquals(listOf("hello", "authenticate"), io.sent)
            assertTrue(io.closed.await(1, TimeUnit.SECONDS))
        }
    }

    @Test
    fun concurrentStatusNeverQueuesAndCloseFencesLateReply() {
        val workers = Executors.newSingleThreadExecutor()
        try {
            for (close in listOf(false, true)) {
                val f = fixture()
                val io =
                    FakeIO(
                        listOf(
                            f.getJSONObject("hello"),
                            f.getJSONObject("authenticated"),
                            f.getJSONObject("status"),
                        )
                    )
                val client =
                    PhoneControlClient(endpoint(), { io }, { _, _ -> credential() }, { 1000 })
                val receipt = client.authenticate()
                io.pauseNext = true
                val pending =
                    workers.submit<PhoneControlMetadata?> {
                        if (close) {
                            rejects { client.status() }
                            null
                        } else client.status()
                    }
                assertTrue(io.paused.await(2, TimeUnit.SECONDS))
                rejects { client.status() }
                assertEquals(listOf("hello", "authenticate", "control-status"), io.sent)
                if (close) client.close()
                io.resume.countDown()
                val result = pending.get(2, TimeUnit.SECONDS)
                if (!close) assertEquals(receipt, result)
                client.close()
                assertTrue(io.closed.await(1, TimeUnit.SECONDS))
            }
        } finally {
            workers.shutdownNow()
        }
    }

    @Test
    fun localLeaseCannotBeExtendedByLongerHostExpiry() {
        var now = 1000L
        val f = fixture()
        val io =
            FakeIO(
                listOf(
                    f.getJSONObject("hello"),
                    f.getJSONObject("authenticated").put("expiresAt", 90000),
                )
            )
        val client = PhoneControlClient(endpoint(), { io }, { _, _ -> credential() }, { now })
        client.authenticate()
        now = 61000
        rejects { client.status() }
        assertEquals(listOf("hello", "authenticate"), io.sent)
        assertTrue(io.closed.await(1, TimeUnit.SECONDS))
    }

    @Test
    fun actualNativePhoneEnrollsAndAuthenticatesThroughPinnedTls() {
        val path = System.getenv("THUMBLE_NATIVE_AUTH_PROBE")
        assumeTrue(path != null)
        val process = ProcessBuilder(path!!).start()
        val reader = process.inputStream.bufferedReader()
        val reads = Executors.newSingleThreadExecutor()
        var enrollment: PhoneEnrollmentClient? = null
        var control: PhoneControlClient? = null
        try {
            fun line() =
                JSONObject(
                    reads
                        .submit<String> { reader.readLine() ?: error("probe closed") }
                        .get(5, TimeUnit.SECONDS)
                )
            val offer = line()
            val target =
                EnrollmentInvitation(
                    "127.0.0.1",
                    offer.getInt("port"),
                    offer.getString("pin"),
                    offer.getString("authorityInstanceId"),
                    offer.getString("windowId"),
                    offer.getString("secret"),
                    offer.getLong("expiresAt"),
                )
            fun connect(): NativeFrameIO {
                val socket =
                    ControlTLSClient.connect(
                        InetSocketAddress(target.host, target.port),
                        target.certificatePin,
                    )
                return object : NativeFrameIO {
                    override fun send(frame: ControlTLSFrame) = socket.send(frame)

                    override fun receive() = socket.receive()

                    override fun close() = socket.close()
                }
            }
            var saved: PhoneCredential? = null
            enrollment =
                PhoneEnrollmentClient(target, ::connect, { saved = it }, System::currentTimeMillis)
            val metadata = enrollment.enroll("phone-a", "Native control")
            enrollment.close()
            control =
                PhoneControlClient(
                    TrustedHostEndpoint(
                        target.host,
                        target.port,
                        target.certificatePin,
                        target.authorityInstanceID,
                    ),
                    ::connect,
                    { _, _ -> saved },
                    System::currentTimeMillis,
                )
            val receipt = control.authenticate()
            assertEquals(metadata.phoneID, receipt.phoneID)
            assertEquals(metadata.epoch, receipt.credentialEpoch)
            assertFalse(receipt.inputSessionAvailable)
            assertEquals(receipt, control.status())
            control.disconnect()
            process.outputStream.write(102)
            process.outputStream.flush()
            assertTrue(line().getBoolean("completed"))
            assertTrue(process.waitFor(5, TimeUnit.SECONDS))
            assertEquals(0, process.exitValue())
        } finally {
            enrollment?.close()
            control?.close()
            process.destroy()
            reader.close()
            reads.shutdownNow()
        }
    }
}
