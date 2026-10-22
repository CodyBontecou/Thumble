package com.thumble.rewrite.input

import java.net.InetSocketAddress
import java.util.ArrayDeque
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

class PhoneEnrollmentTest {
    private fun fixture() =
        javaClass.classLoader!!.getResourceAsStream("enrollment-control-v2.json")!!.use {
            JSONObject(it.readBytes().toString(Charsets.UTF_8))
        }

    private fun invitationFixture() =
        javaClass.classLoader!!.getResourceAsStream("pairing-invitation-v1.json")!!.use {
            JSONObject(it.readBytes().toString(Charsets.UTF_8))
        }

    private fun invitation() =
        EnrollmentInvitation.decode(
            invitationFixture()
                .getJSONArray("valid")
                .getJSONObject(0)
                .toString()
                .toByteArray(Charsets.UTF_8)
        )

    @Test
    fun nativeInvitationIntakeUsesTheExactBoundedSharedOffer() {
        val fixture =
            javaClass.classLoader!!.getResourceAsStream("pairing-invitation-v1.json")!!.use {
                JSONObject(it.readBytes().toString(Charsets.UTF_8))
            }
        val valid = fixture.getJSONArray("valid")
        for (i in 0 until valid.length()) {
            val raw = valid.getJSONObject(i)
            val decoded = EnrollmentInvitation.decode(raw.toString().toByteArray(Charsets.UTF_8))
            assertEquals(raw.getString("host"), decoded.host)
            assertEquals(raw.getInt("port"), decoded.port)
            assertEquals(raw.getString("certificatePin"), decoded.certificatePin)
            assertEquals(raw.getString("authorityInstanceId"), decoded.authorityInstanceID)
            assertEquals(raw.getString("windowId"), decoded.windowID)
            assertEquals(raw.getLong("expiresAt"), decoded.expiresAt)
            assertFalse(decoded.toString().contains("44".repeat(32)))
        }
        val invalid = fixture.getJSONArray("invalidJSON")
        for (i in 0 until invalid.length()) rejects {
            EnrollmentInvitation.decode(invalid.getString(i).toByteArray(Charsets.UTF_8))
        }
        rejects { EnrollmentInvitation.decode(ByteArray(4097) { 32 }) }
        rejects {
            EnrollmentInvitation.decode(
                byteArrayOf(123, 34, 97, 34, 58, 34, (-1).toByte(), 34, 125)
            )
        }
    }

    private class FakeIO(objects: List<JSONObject>, val events: MutableList<String>) :
        NativeFrameIO {
        val frames =
            ArrayDeque(
                objects.map {
                    ControlTLSFrame(
                        ControlTLSFrame.Kind.CONTROL,
                        it.toString().toByteArray(Charsets.UTF_8),
                    )
                }
            )
        val closed = CountDownLatch(1)

        override fun send(frame: ControlTLSFrame) {
            val values = EnrollmentJSON.parse(frame.payload)
            events.add((values["command"] as EnrollmentJSON.Value.Text).value)
        }

        override fun receive() = frames.pollFirst() ?: throw PhoneEnrollmentRejected()

        override fun close() {
            closed.countDown()
        }
    }

    private fun rejects(block: () -> Unit) {
        try {
            block()
            fail("enrollment was accepted")
        } catch (_: PhoneEnrollmentRejected) {}
    }

    @Test
    fun sharedStrictJsonRejectsDuplicateDecodedKeysAndCoercions() {
        val f = fixture()
        val cases = f.getJSONArray("invalidJSON")
        for (i in 0 until cases.length()) {
            try {
                EnrollmentJSON.parse(cases.getString(i).toByteArray(Charsets.UTF_8))
                fail("invalid JSON accepted")
            } catch (_: Exception) {}
        }
        try {
            EnrollmentJSON.parse(byteArrayOf(123, 34, 97, 34, 58, 34, (-1).toByte(), 34, 125))
            fail("lossy UTF-8 accepted")
        } catch (_: Exception) {}
        val valid =
            EnrollmentJSON.parse(
                """{"label":"brace } comma , colon : and emoji \uD83D\uDE00","x":false,"n":0}"""
                    .toByteArray()
            )
        assertEquals(
            EnrollmentJSON.Value.Text("brace } comma , colon : and emoji 😀"),
            valid["label"],
        )
        assertEquals(EnrollmentJSON.Value.BooleanValue(false), valid["x"])
        assertEquals(EnrollmentJSON.Value.Integer(0), valid["n"])
    }

    @Test
    fun sendsAckOnlyAfterSaveAndRequiresHostCompletion() {
        val f = fixture()
        val events = CopyOnWriteArrayList<String>()
        val io =
            FakeIO(
                listOf(
                    f.getJSONObject("hello"),
                    f.getJSONObject("enrolled"),
                    f.getJSONObject("complete"),
                ),
                events,
            )
        var saved: PhoneCredentialMetadata? = null
        val client =
            PhoneEnrollmentClient(
                invitation(),
                { io },
                {
                    saved = it.metadata
                    events.add("saved")
                },
                { 1000 },
            )
        val result = client.enroll("phone-a", "Controller")
        assertEquals(saved, result)
        assertEquals(listOf("hello", "enroll", "saved", "enrollment-stored"), events.toList())
        rejects { client.enroll("phone-a", "Controller") }
        client.close()
        assertTrue(io.closed.await(2, TimeUnit.SECONDS))
        assertEquals("EnrollmentInvitation([redacted])", invitation().toString())
    }

    @Test
    fun rejectsHostMismatchOrUnsupportedVersionsBeforeSendingProof() {
        for (field in
            listOf(
                "authorityInstanceId",
                "controlVersion",
                "inputVersion",
                "documentVersion",
                "capabilitiesVersion",
                "inputEnabled",
                "extra",
            )) {
            val f = fixture()
            val hello =
                f.getJSONObject("hello")
                    .put(
                        field,
                        if (field == "authorityInstanceId") "wrong"
                        else if (field == "controlVersion") 1 else 99,
                    )
            val events = CopyOnWriteArrayList<String>()
            val io = FakeIO(listOf(hello), events)
            val client =
                PhoneEnrollmentClient(
                    invitation(),
                    { io },
                    { fail("unnegotiated host reached storage") },
                    { 1000 },
                )
            rejects { client.enroll("phone-a", "Controller") }
            assertFalse(events.contains("enroll"))
            assertTrue(io.closed.await(2, TimeUnit.SECONDS))
        }
    }

    @Test
    fun rejectsMalformedCredentialMetadataBeforeStorageOrAck() {
        for (field in listOf("phoneId", "credentialEpoch", "credential", "expiresAt", "extra")) {
            val f = fixture()
            val reply = f.getJSONObject("enrolled")
            reply.put(
                field,
                when (field) {
                    "phoneId" -> "other"
                    "credentialEpoch" -> "07"
                    "credential" -> "AA".repeat(32)
                    "expiresAt" -> 1000
                    else -> true
                },
            )
            val events = CopyOnWriteArrayList<String>()
            val io = FakeIO(listOf(f.getJSONObject("hello"), reply), events)
            val client =
                PhoneEnrollmentClient(
                    invitation(),
                    { io },
                    { fail("malformed credential reached storage") },
                    { 1000 },
                )
            rejects { client.enroll("phone-a", "Controller") }
            assertFalse(events.contains("enrollment-stored"))
            assertTrue(io.closed.await(2, TimeUnit.SECONDS))
        }
    }

    @Test
    fun storageFailureCannotAcknowledgeAndCompletionFailurePreservesStorage() {
        val f = fixture()
        val events = CopyOnWriteArrayList<String>()
        val io = FakeIO(listOf(f.getJSONObject("hello"), f.getJSONObject("enrolled")), events)
        val failed =
            PhoneEnrollmentClient(
                invitation(),
                { io },
                { throw PhoneCredentialRejected("unavailable") },
                { 1000 },
            )
        rejects { failed.enroll("phone-a", "Controller") }
        assertFalse(events.contains("enrollment-stored"))
        assertTrue(io.closed.await(2, TimeUnit.SECONDS))
        for (missing in listOf(false, true)) {
            val fresh = fixture()
            val trace = CopyOnWriteArrayList<String>()
            val replies =
                mutableListOf(fresh.getJSONObject("hello"), fresh.getJSONObject("enrolled"))
            if (!missing) replies.add(fresh.getJSONObject("complete").put("credentialEpoch", "8"))
            val transport = FakeIO(replies, trace)
            var saved: PhoneCredentialMetadata? = null
            val client =
                PhoneEnrollmentClient(
                    invitation(),
                    { transport },
                    { saved = it.metadata },
                    { 1000 },
                )
            rejects { client.enroll("phone-a", "Controller") }
            assertEquals(7L, saved!!.epoch)
            assertTrue(trace.contains("enrollment-stored"))
            assertTrue(transport.closed.await(2, TimeUnit.SECONDS))
        }
    }

    @Test
    fun cancellationDuringStorageAndLateConnectAreTerminal() {
        for (inStorage in listOf(false, true)) {
            val f = fixture()
            val events = CopyOnWriteArrayList<String>()
            val io = FakeIO(listOf(f.getJSONObject("hello"), f.getJSONObject("enrolled")), events)
            val entered = CountDownLatch(1)
            val release = CountDownLatch(1)
            val saved = AtomicReference<PhoneCredentialMetadata?>()
            val failure = AtomicReference<Throwable?>()
            val client =
                PhoneEnrollmentClient(
                    invitation(),
                    {
                        if (!inStorage) {
                            entered.countDown()
                            check(release.await(3, TimeUnit.SECONDS))
                        }
                        io
                    },
                    {
                        saved.set(it.metadata)
                        entered.countDown()
                        check(release.await(3, TimeUnit.SECONDS))
                    },
                    { 1000 },
                )
            val worker = Thread {
                try {
                    client.enroll("phone-a", "Controller")
                    failure.set(AssertionError("canceled enrollment succeeded"))
                } catch (e: PhoneEnrollmentRejected) {
                    failure.set(e)
                }
            }
            worker.start()
            assertTrue(entered.await(3, TimeUnit.SECONDS))
            client.close()
            release.countDown()
            worker.join(3000)
            assertFalse(worker.isAlive)
            assertTrue(failure.get() is PhoneEnrollmentRejected)
            assertFalse(events.contains("enrollment-stored"))
            assertTrue(io.closed.await(2, TimeUnit.SECONDS))
            if (inStorage) assertEquals(7L, saved.get()!!.epoch) else assertNull(saved.get())
        }
    }

    @Test
    fun expiryAndClockRollbackNeverSendProof() {
        for (rollback in listOf(false, true)) {
            val f = fixture()
            val events = CopyOnWriteArrayList<String>()
            val io = FakeIO(listOf(f.getJSONObject("hello")), events)
            val calls = AtomicInteger()
            val client =
                PhoneEnrollmentClient(
                    invitation(),
                    { io },
                    { fail("invalid clock reached storage") },
                    {
                        if (rollback) {
                            if (calls.incrementAndGet() < 3) 1000 else 999
                        } else 10000
                    },
                )
            rejects { client.enroll("phone-a", "Controller") }
            assertFalse(events.contains("enroll"))
        }
    }

    @Test
    fun realNativePhoneEnrollsThroughPinnedTlsToRustTrustLedger() {
        val path = System.getenv("THUMBLE_NATIVE_ENROLLMENT_PROBE")
        assumeTrue("native enrollment probe must be explicitly provided", path != null)
        val process = ProcessBuilder(path!!).start()
        val reader = process.inputStream.bufferedReader()
        val reads = Executors.newSingleThreadExecutor { r ->
            Thread(r, "enrollment-probe-read").apply { isDaemon = true }
        }
        var client: PhoneEnrollmentClient? = null
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
            var saved: PhoneCredentialMetadata? = null
            client =
                PhoneEnrollmentClient(
                    target,
                    {
                        val transport =
                            ControlTLSClient.connect(
                                InetSocketAddress(target.host, target.port),
                                target.certificatePin,
                            )
                        object : NativeFrameIO {
                            override fun send(frame: ControlTLSFrame) = transport.send(frame)

                            override fun receive() = transport.receive()

                            override fun close() = transport.close()
                        }
                    },
                    { saved = it.metadata },
                    System::currentTimeMillis,
                )
            val result = client.enroll("phone-a", "Native controller")
            assertEquals(saved, result)
            assertEquals(1L, result.epoch)
            val completed = line()
            assertTrue(completed.getBoolean("completed"))
            assertFalse(completed.getBoolean("inputEnabled"))
            assertTrue(process.waitFor(5, TimeUnit.SECONDS))
            assertEquals(0, process.exitValue())
        } finally {
            client?.close()
            process.destroy()
            reader.close()
            reads.shutdownNow()
        }
    }

    @Test
    fun malformedUtf16LabelsAndHostsNeverBecomeLossyUtf8ProofRequests() {
        val events = CopyOnWriteArrayList<String>()
        val io = FakeIO(emptyList(), events)
        val client =
            PhoneEnrollmentClient(
                invitation(),
                {
                    events.add("connect")
                    io
                },
                { fail("invalid label reached storage") },
                { 1000 },
            )
        rejects { client.enroll("phone-a", "\uD800") }
        assertTrue(events.isEmpty())
        rejects {
            EnrollmentInvitation(
                "\uD800",
                1234,
                "11".repeat(32),
                "authority-a",
                "window-a",
                "44".repeat(32),
                10000,
            )
        }
        assertTrue(EnrollmentInvitation.scalarText("Native 😀"))
    }
}
