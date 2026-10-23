package com.thumble.rewrite.input

import java.io.EOFException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLException
import org.junit.Assert.*
import org.junit.Test

class NativeTLSDiagnosticTest {
    private fun until(condition: () -> Boolean) {
        val end = System.nanoTime() + TimeUnit.SECONDS.toNanos(3)
        while (System.nanoTime() < end) {
            if (condition()) return
            Thread.sleep(1)
        }
        fail("diagnostic_condition_timeout")
    }

    @Test
    fun terminalReadClassifiesOnlyFixedCategoriesAndCleanupCannotReplaceFirstCause() {
        val errors =
            listOf(
                SocketTimeoutException() to NativeTLSExceptionCategory.TIMEOUT,
                EOFException() to NativeTLSExceptionCategory.EOF,
                SocketException() to NativeTLSExceptionCategory.SOCKET,
                SSLException("") to NativeTLSExceptionCategory.TLS,
                ControlTLSRejected() to NativeTLSExceptionCategory.REJECTED,
                IllegalStateException() to NativeTLSExceptionCategory.OTHER,
            )
        for ((error, category) in errors) {
            val delivery =
                NativeTLSDelivery(
                    object : NativeFrameIO {
                        override fun send(frame: ControlTLSFrame) {}

                        override fun receive(): ControlTLSFrame = throw error

                        override fun close() {}
                    }
                )
            until { delivery.state == NativeTLSDelivery.State.CLOSED }
            val expected = NativeTLSTerminalDiagnostic(NativeTLSCloseCause.READ_FAILED, category)
            assertEquals(expected, delivery.terminalDiagnostic)
            repeat(3) { delivery.close() }
            assertEquals(expected, delivery.terminalDiagnostic)
            assertNull(delivery.pollControl())
            assertFalse(delivery.offerControl(byteArrayOf(1)))
        }
    }

    @Test
    fun explicitCloseWinsBeforeInterruptedReaderAndWriterErrors() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val delivery =
            NativeTLSDelivery(
                object : NativeFrameIO {
                    override fun send(frame: ControlTLSFrame) {}

                    override fun receive(): ControlTLSFrame {
                        entered.countDown()
                        check(release.await(3, TimeUnit.SECONDS))
                        throw SocketException()
                    }

                    override fun close() {
                        release.countDown()
                    }
                }
            )
        assertTrue(entered.await(3, TimeUnit.SECONDS))
        delivery.close()
        val expected =
            NativeTLSTerminalDiagnostic(
                NativeTLSCloseCause.EXPLICIT_CLOSE,
                NativeTLSExceptionCategory.NONE,
            )
        assertEquals(expected, delivery.terminalDiagnostic)
        assertTrue(release.await(3, TimeUnit.SECONDS))
        assertEquals(expected, delivery.terminalDiagnostic)
    }

    @Test
    fun connectAndWriteFailuresRemainDifferentFromReaderAndExplicitClose() {
        val failed = NativeTLSDelivery { throw SocketException() }
        until { failed.state == NativeTLSDelivery.State.CLOSED }
        assertEquals(NativeTLSCloseCause.CONNECT_FAILED, failed.terminalDiagnostic?.cause)
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val delivery =
            NativeTLSDelivery(
                object : NativeFrameIO {
                    override fun send(frame: ControlTLSFrame) {
                        throw SocketException()
                    }

                    override fun receive(): ControlTLSFrame {
                        entered.countDown()
                        check(release.await(3, TimeUnit.SECONDS))
                        throw SocketException()
                    }

                    override fun close() {
                        release.countDown()
                    }
                }
            )
        assertTrue(entered.await(3, TimeUnit.SECONDS))
        assertTrue(delivery.offerControl(byteArrayOf(1)))
        until { delivery.state == NativeTLSDelivery.State.CLOSED }
        assertEquals(
            NativeTLSTerminalDiagnostic(
                NativeTLSCloseCause.WRITE_FAILED,
                NativeTLSExceptionCategory.SOCKET,
            ),
            delivery.terminalDiagnostic,
        )
    }

    @Test
    fun malformedDirectionHasASeparateFixedCause() {
        val delivery =
            NativeTLSDelivery(
                object : NativeFrameIO {
                    override fun send(frame: ControlTLSFrame) {}

                    override fun receive() =
                        ControlTLSFrame(ControlTLSFrame.Kind.INPUT, ByteArray(108))

                    override fun close() {}
                }
            )
        until { delivery.state == NativeTLSDelivery.State.CLOSED }
        assertEquals(
            NativeTLSTerminalDiagnostic(
                NativeTLSCloseCause.INVALID_DIRECTION,
                NativeTLSExceptionCategory.REJECTED,
            ),
            delivery.terminalDiagnostic,
        )
    }

    @Test
    fun invalidClockRejectsBeforeTransportAndCleanupPreservesTheCheckpointReason() {
        var connected = false
        val client =
            PhoneControlClient(
                TrustedHostEndpoint("127.0.0.1", 1234, "11".repeat(32), "authority-a"),
                {
                    connected = true
                    throw IllegalStateException()
                },
                { _, _ -> null },
                { -1L },
            )
        try {
            client.authenticate()
            fail("invalid_clock_accepted")
        } catch (_: PhoneControlRejected) {}
        assertFalse(connected)
        assertEquals(PhoneCheckpointFailure.INVALID_TIME, client.checkpointFailure)
        client.close()
        try {
            client.status()
            fail("closed_status_accepted")
        } catch (_: PhoneControlRejected) {}
        assertEquals(PhoneCheckpointFailure.INVALID_TIME, client.checkpointFailure)
    }

    /**
     * Exercises the production operation/exact-reader/nativeFrames adapter, without pretending this
     * synthetic socket performs certificate or TLS acceptance.
     */
    private class SyntheticSocket(
        private val input: java.io.InputStream,
        private val released: CountDownLatch,
        private val output: java.io.OutputStream,
    ) : javax.net.ssl.SSLSocket() {
        override fun getInputStream() = input

        override fun getOutputStream() = output

        override fun close() {
            released.countDown()
        }

        override fun getSupportedCipherSuites() = emptyArray<String>()

        override fun getEnabledCipherSuites() = emptyArray<String>()

        override fun setEnabledCipherSuites(values: Array<String>) {}

        override fun getSupportedProtocols() = emptyArray<String>()

        override fun getEnabledProtocols() = emptyArray<String>()

        override fun setEnabledProtocols(values: Array<String>) {}

        override fun getSession(): javax.net.ssl.SSLSession = throw UnsupportedOperationException()

        override fun addHandshakeCompletedListener(
            value: javax.net.ssl.HandshakeCompletedListener
        ) {}

        override fun removeHandshakeCompletedListener(
            value: javax.net.ssl.HandshakeCompletedListener
        ) {}

        override fun startHandshake() {}

        override fun setUseClientMode(value: Boolean) {}

        override fun getUseClientMode() = true

        override fun setNeedClientAuth(value: Boolean) {}

        override fun getNeedClientAuth() = false

        override fun setWantClientAuth(value: Boolean) {}

        override fun getWantClientAuth() = false

        override fun setEnableSessionCreation(value: Boolean) {}

        override fun getEnableSessionCreation() = false
    }

    private fun client(
        input: java.io.InputStream,
        released: CountDownLatch,
        output: java.io.OutputStream = java.io.ByteArrayOutputStream(),
    ): ControlTLSClient {
        val constructor =
            ControlTLSClient::class
                .java
                .getDeclaredConstructor(
                    javax.net.ssl.SSLSocket::class.java,
                    java.net.Socket::class.java,
                )
        constructor.isAccessible = true
        return constructor.newInstance(
            SyntheticSocket(input, released, output),
            object : java.net.Socket() {
                override fun close() {
                    released.countDown()
                }
            },
        )
    }

    @Test
    fun productionAdapterPreservesEofAndTimeoutAfterPublicRejectionErasesTheException() {
        for ((input, category) in
            listOf(
                java.io.ByteArrayInputStream(byteArrayOf()) to NativeTLSExceptionCategory.EOF,
                object : java.io.InputStream() {
                    override fun read(): Int = throw SocketTimeoutException()
                } to NativeTLSExceptionCategory.TIMEOUT,
                object : java.io.InputStream() {
                    override fun read(): Int = throw SSLException("")
                } to NativeTLSExceptionCategory.TLS,
            )) {
            val client = client(input, CountDownLatch(1))
            val delivery = NativeTLSDelivery(client.nativeFrames())
            until { delivery.state == NativeTLSDelivery.State.CLOSED }
            assertEquals(
                NativeTLSTerminalDiagnostic(
                    NativeTLSCloseCause.READ_FAILED,
                    category,
                    NativeTLSOperationFailure(
                        NativeTLSOperationDirection.RECEIVE,
                        NativeTLSOperationFailureKind.IO,
                        category,
                    ),
                ),
                delivery.terminalDiagnostic,
            )
            try {
                client.receive()
                fail("closed_transport_read_accepted")
            } catch (_: ControlTLSRejected) {}
            assertEquals(category, client.failureCategory)
        }
    }

    @Test
    fun productionWatchdogCauseSurvivesItsOwnSocketCloseException() {
        val released = CountDownLatch(1)
        val entered = CountDownLatch(1)
        val input =
            object : java.io.InputStream() {
                override fun read(): Int {
                    entered.countDown()
                    check(released.await(3, TimeUnit.SECONDS))
                    throw SocketException()
                }
            }
        val client = client(input, released)
        val delivery = NativeTLSDelivery(client.nativeFrames())
        assertTrue(entered.await(1, TimeUnit.SECONDS))
        until { delivery.state == NativeTLSDelivery.State.CLOSED }
        assertEquals(
            NativeTLSTerminalDiagnostic(
                NativeTLSCloseCause.READ_FAILED,
                NativeTLSExceptionCategory.TIMEOUT,
                NativeTLSOperationFailure(
                    NativeTLSOperationDirection.RECEIVE,
                    NativeTLSOperationFailureKind.DEADLINE,
                    NativeTLSExceptionCategory.TIMEOUT,
                ),
            ),
            delivery.terminalDiagnostic,
        )
        client.close()
        delivery.close()
        assertEquals(NativeTLSExceptionCategory.TIMEOUT, client.failureCategory)
    }

    @Test
    fun productionWriterDeadlineRetainsSendDirectionDespitePublicRejection() {
        val released = CountDownLatch(1)
        val output =
            object : java.io.OutputStream() {
                override fun write(value: Int) {
                    check(released.await(3, TimeUnit.SECONDS))
                    throw SocketException()
                }
            }
        val client = client(java.io.ByteArrayInputStream(byteArrayOf()), released, output)
        try {
            client.send(ControlTLSFrame(ControlTLSFrame.Kind.CONTROL, byteArrayOf(1)))
            fail("stalled_writer_accepted")
        } catch (_: ControlTLSRejected) {}
        assertEquals(
            NativeTLSOperationFailure(
                NativeTLSOperationDirection.SEND,
                NativeTLSOperationFailureKind.DEADLINE,
                NativeTLSExceptionCategory.TIMEOUT,
            ),
            client.operationFailure,
        )
    }

    @Test
    fun terminalControlActivityDistinguishesQueuedStartedAndCompletedWrites() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val delivery =
            NativeTLSDelivery(
                object : NativeFrameIO {
                    override fun send(frame: ControlTLSFrame) {
                        entered.countDown()
                        check(release.await(3, TimeUnit.SECONDS))
                    }

                    override fun receive(): ControlTLSFrame {
                        check(release.await(3, TimeUnit.SECONDS))
                        throw SocketException()
                    }

                    override fun close() {
                        release.countDown()
                    }
                }
            )
        assertTrue(delivery.offerControl(byteArrayOf(1)))
        assertTrue(entered.await(1, TimeUnit.SECONDS))
        delivery.close()
        val activity = requireNotNull(delivery.terminalActivity)
        assertEquals(1L, activity.queued)
        assertEquals(1L, activity.writeStarted)
        assertEquals(0L, activity.writeCompleted)
        assertEquals(0L, activity.received)
        assertTrue(requireNotNull(activity.queuedAgeMs) in 0..86_400_000L)
        assertTrue(requireNotNull(activity.writeStartedAgeMs) in 0..86_400_000L)
        assertNull(activity.writeCompletedAgeMs)
        assertNull(activity.receivedAgeMs)
        assertEquals(0, activity.queueDepth)
        assertEquals(activity, delivery.terminalActivity)
    }
}
