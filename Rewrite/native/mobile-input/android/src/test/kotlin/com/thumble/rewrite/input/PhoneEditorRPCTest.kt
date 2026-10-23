package com.thumble.rewrite.input

import java.util.ArrayDeque
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class PhoneEditorRPCTest {
    private val pin = "a".repeat(64)
    private val authority = "11111111-1111-1111-1111-111111111111"
    private val connection = "ab".repeat(16)

    private fun endpoint() = TrustedHostEndpoint("127.0.0.1", 1234, pin, authority)

    private fun intent() =
        EditorLabelIntent(
            EditorHostScope(pin, authority),
            "edit-A-1",
            "7",
            "aaaaaaaa-0000-0000-0000-000000000001",
            "ce000000-0000-0000-0000-000000000001",
            "Move 🦊",
        )

    private fun credential() =
        PhoneCredential(PhoneCredentialMetadata(pin, "phone-a", 1, 100000), ByteArray(32) { 34 })

    private fun hello(version: Int = 12) =
        JSONObject()
            .put("version", 1)
            .put("command", "hello")
            .put("authorityInstanceId", authority)
            .put("controlVersion", version)
            .put("role", "management")
            .put("inputVersion", 1)
            .put("documentVersion", 1)
            .put("capabilitiesVersion", 1)
            .put("inputEnabled", false)

    private fun admission(input: Boolean = false) =
        JSONObject()
            .put("version", 1)
            .put("command", "authenticated")
            .put("authorityInstanceId", authority)
            .put("phoneId", "phone-a")
            .put("credentialEpoch", "1")
            .put("connectionId", connection)
            .put("expiresAt", 60100)
            .put("role", "management")
            .put("inputSessionAvailable", false)
            .put("inputEnabled", input)

    private fun admitted() =
        JSONObject()
            .put("version", 1)
            .put("command", "configuration-set-control-label-result")
            .put("connectionId", connection)
            .put("authorityInstanceId", authority)
            .put("kind", "editor-label-admitted")
            .put("operationId", "edit-A-1")

    private class Frames(fields: List<JSONObject>) : NativeFrameIO {
        val frames =
            ArrayDeque(
                fields.map {
                    ControlTLSFrame(
                        ControlTLSFrame.Kind.CONTROL,
                        it.toString().toByteArray(Charsets.UTF_8),
                    )
                }
            )
        val commands = arrayListOf<String>()
        var closed = false

        override fun send(frame: ControlTLSFrame) {
            check(!closed)
            commands.add(JSONObject(String(frame.payload, Charsets.UTF_8)).getString("command"))
        }

        override fun receive(): ControlTLSFrame {
            check(!closed)
            return frames.removeFirst()
        }

        override fun close() {
            closed = true
        }
    }

    @Test
    fun exactManagementHandshakeOneCommandAndNativeCredentialOrder() {
        val io = Frames(listOf(hello(), admission(), admitted()))
        var loads = 0
        val client =
            PhoneEditorRPC(
                endpoint(),
                { io },
                { _, _ ->
                    loads++
                    credential()
                },
                { 100 },
            )
        val result = client.exchange(EditorRequest.Label(intent()))
        assertEquals("phone-a", result.phoneID)
        assertEquals(1L, result.credentialEpoch)
        assertEquals(EditorReply.Admitted, result.reply)
        assertEquals(1, loads)
        assertEquals(
            listOf("hello", "authenticate", "configuration-set-control-label"),
            io.commands,
        )
        assertTrue(io.closed)
    }

    @Test
    fun wrongRoleHelloExtraFieldOrInputAuthorityFailsBeforeEditOffer() {
        for (bad in
            listOf(
                hello(11),
                hello().put("private", "not-allowed"),
                hello().put("authorityInstanceId", "22222222-2222-2222-2222-222222222222"),
            )) {
            val io = Frames(listOf(bad))
            var loads = 0
            val client =
                PhoneEditorRPC(
                    endpoint(),
                    { io },
                    { _, _ ->
                        loads++
                        credential()
                    },
                    { 100 },
                )
            try {
                client.exchange(EditorRequest.Label(intent()))
                fail("editor_wrong_hello_accepted")
            } catch (_: PhoneEditorException) {}
            assertEquals(0, loads)
            assertEquals(listOf("hello"), io.commands)
            assertTrue(io.closed)
        }
        val io = Frames(listOf(hello(), admission(true)))
        val client = PhoneEditorRPC(endpoint(), { io }, { _, _ -> credential() }, { 100 })
        try {
            client.exchange(EditorRequest.Label(intent()))
            fail("editor_input_authority_accepted")
        } catch (_: PhoneEditorException) {}
        assertEquals(listOf("hello", "authenticate"), io.commands)
    }

    @Test
    fun cancellationDuringCredentialLoadClosesWithoutEditOffer() {
        val io = Frames(listOf(hello(), admission(), admitted()))
        lateinit var client: PhoneEditorRPC
        client =
            PhoneEditorRPC(
                endpoint(),
                { io },
                { _, _ ->
                    client.cancel()
                    credential()
                },
                { 100 },
            )
        try {
            client.exchange(EditorRequest.Label(intent()))
            fail("editor_cancelled_write_offered")
        } catch (_: PhoneEditorException) {}
        assertEquals(listOf("hello"), io.commands)
        assertTrue(io.closed)
    }
}
