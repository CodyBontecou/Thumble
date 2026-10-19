package com.thumble.android

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID
import java.nio.ByteBuffer
import java.nio.ByteOrder

class ProtocolTest {
    private val id = UUID.fromString("66FA21C9-4D00-4B11-8890-97D157F7881A")
    @Test fun `input matches shared Swift and Rust vectors including unsigned fields`() {
        val root = JSONObject(javaClass.getResource("/wire/vectors.json")!!.readText())
        val vectors = root.getJSONArray("vectors")
        var checked = 0
        for (i in 0 until vectors.length()) {
            val vector = vectors.getJSONObject(i)
            if (vector.optString("kind") != "compact") continue
            val m = vector.getJSONObject("message")
            if (m.getString("type") !in setOf("button", "element_input")) continue
            val flags = (if (m.has("pressIdentifier")) 1 else 0) or (if (m.has("inputGeneration")) 2 else 0) or
                (if (m.has("inputSequence")) 4 else 0) or (if (m.has("inputProtocolVersion")) 8 else 0)
            val part = listOf("primary", "joystick_up", "joystick_down", "joystick_left", "joystick_right", "trigger_digital")
                .indexOf(m.optString("elementPart", "primary"))
            fun long(key: String) = if (m.has(key)) java.math.BigInteger(m.get(key).toString()).toLong() else 0L
            val bytes = WireCodec.compactInput(UUID.fromString(m.optString("button", m.optString("elementID"))),
                m.getString("state") == "down", long("inputGeneration"), long("inputSequence"), long("pressIdentifier"),
                flags, m.getLong("timestamp"), if (m.getString("type") == "button") 1 else 6, part)
            val hex = bytes.joinToString("") { "%02x".format(it.toInt() and 255) }
            assertEquals(vector.getString("name"), vector.getString("hex"), hex)
            checked++
        }
        assertTrue(checked >= 3)
    }
    @Test fun `starter defaults distribute controls across the canvas and mirror southpaw`() {
        fun control(n: Int) = UUID.fromString("00000000-0000-0000-0000-%012X".format(0x100 + n))
        val centers = (1..10).map { defaultCenter(control(it), false, 393.0, 700.0, 78.0, 78.0) }
        assertEquals(10, centers.distinct().size)
        assertTrue(centers[0].second < centers[1].second)
        assertTrue(centers[2].first < centers[3].first)
        val left = defaultCenter(control(1), false, 852.0, 393.0, 78.0, 78.0)
        val right = defaultCenter(control(1), true, 852.0, 393.0, 78.0, 78.0)
        assertEquals(1.0, left.first + right.first, .0001)
    }
    @Test fun `production button encoder uses all four v3 fields`() {
        val data = WireCodec.button(id, true, 91, 42, 7)
        assertEquals("5050030166fa21c94d004b11889097d157f7881a00010f005b000000000000002a0000000000000007000000000000000000000000000000",
            data.joinToString("") { "%02x".format(it.toInt() and 255) })
    }
    @Test fun `compact ping responds with exact signed timestamp`() {
        val data = byteArrayOf(80, 80, 1, 4) + ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putLong(-42).array() + byteArrayOf(-1, -1)
        val ping = WireCodec.decode(data)
        assertEquals("ping", ping.getString("type")); assertEquals(-42L, ping.getLong("timestamp"))
    }
    @Test fun `pairing rejects unrelated QR and credential URLs`() {
        for (bad in listOf("{}", """{"type":"pocketpad-pair","urls":["https://example.com"]}""",
            """{"type":"pocketpad-pair","urls":["ws://user:password@host:8765"]}""")) {
            assertTrue(runCatching { PairingTarget.parse(bad) }.isFailure)
        }
        val qr = PairingTarget.parse("""{"type":"pocketpad-pair","urls":["ws://192.168.1.2:8765"],"pairingCode":"123456","serverID":"test"}""")
        assertEquals("123456", qr.code); assertEquals("test", qr.serverID)
    }
    @Test fun `two fingers on same button have independent physical press IDs`() {
        val events = mutableListOf<Triple<UUID, Boolean, Long>>()
        val router = TouchRouter { key, down, press -> events.add(Triple(key, down, press)) }
        router.move(3, id); router.move(8, id); router.move(3, null)
        assertEquals(setOf(id), router.pressedIDs())
        assertEquals(events[0].third, events[2].third)
        assertNotEquals(events[0].third, events[1].third)
        router.cancel()
        assertTrue(router.pressedIDs().isEmpty())
        assertEquals(events[1].third, events[3].third)
    }
    @Test fun `sliding releases old button before pressing neighbor and cancel is idempotent`() {
        val other = UUID.randomUUID()
        val events = mutableListOf<Pair<UUID, Boolean>>()
        val router = TouchRouter { key, down, _ -> events.add(key to down) }
        router.move(1, id); router.move(1, id); router.move(1, other); router.cancel(); router.cancel()
        assertEquals(listOf(id to true, id to false, other to true, other to false), events)
    }
    @Test fun `refresh advances sequence preserves press and release clears holds in new generation`() {
        val packets = mutableListOf<ByteArray>()
        val session = InputSession({ packets.add(it) }, 91)
        session.edge(id, true, 7); session.edge(id, true, 7); session.heartbeat()
        val frames = packets.filter { it.size == 56 }
        assertEquals(2, frames.size)
        fun field(frame: ByteArray, offset: Int) = ByteBuffer.wrap(frame, offset, 8).order(ByteOrder.LITTLE_ENDIAN).long
        assertEquals(1L, field(frames[0], 32)); assertEquals(2L, field(frames[1], 32))
        assertEquals(7L, field(frames[1], 40))
        session.releaseAll(); session.heartbeat(); session.edge(id, false, 7)
        assertEquals(2, packets.count { it.size == 56 })
        assertEquals(92L, session.generation)
        session.edge(id, true, 8)
        assertEquals(1L, field(packets.last(), 32)); assertEquals(92L, field(packets.last(), 24))
    }
    @Test fun `service-only pairing requires a specific supported Mac advertisement`() {
        val target = PairingTarget.parse("""{"type":"pocketpad-pair","urls":[],"serverID":"fixture","bonjourServiceType":"_pocketpad._tcp.","pairingCode":"123456"}""")
        assertTrue(target.urls.isEmpty())
        assertEquals("fixture", target.serverID)
        assertFalse(target.toString().contains("123456"))
        for (bad in listOf(
            """{"type":"pocketpad-pair","urls":[]}""",
            """{"type":"pocketpad-pair","urls":[],"serverID":"fixture","bonjourServiceType":"_ssh._tcp"}""",
            """{"type":"pocketpad-pair","urls":[],"serverID":"fixture","bonjourServiceDomain":"example.com"}"""
        )) assertTrue(runCatching { PairingTarget.parse(bad) }.isFailure)
    }

}
