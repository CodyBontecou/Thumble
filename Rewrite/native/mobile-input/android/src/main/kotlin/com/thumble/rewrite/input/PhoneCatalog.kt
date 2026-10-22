package com.thumble.rewrite.input

import android.annotation.TargetApi
import android.content.Context
import android.os.Looper
import java.io.Closeable
import java.net.InetSocketAddress
import java.util.Collections
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONObject

class PhoneCatalogRejected : Exception("phone_catalog_rejected")

data class PhoneCatalogProfile(val id: String, val name: String, val updatedAt: String)

data class PhoneCatalogPage(
    val revision: String,
    val contentHash: String?,
    val activeProfileID: String?,
    val defaultProfileID: String?,
    val nextOffset: Int?,
    val profiles: List<PhoneCatalogProfile>,
)

sealed class PhoneCatalogResult {
    data class Catalog(val page: PhoneCatalogPage) : PhoneCatalogResult()

    data class Conflict(val currentRevision: String) : PhoneCatalogResult()

    data class Unavailable(val error: String) : PhoneCatalogResult()

    /** Copies only public catalog fields; no native owner or credentials are representable. */
    fun bridgeMetadata(): Map<String, Any?> =
        when (this) {
            is Unavailable -> mapOf("kind" to "error", "error" to error)
            is Conflict -> mapOf("kind" to "conflict", "currentRevision" to currentRevision)
            is Catalog ->
                mutableMapOf<String, Any?>(
                        "kind" to "catalog",
                        "revision" to page.revision,
                        "contentHash" to page.contentHash,
                        "activeProfileId" to page.activeProfileID,
                        "defaultProfileId" to page.defaultProfileID,
                        "nextOffset" to page.nextOffset,
                        "profileCount" to page.profiles.size,
                    )
                    .also { fields ->
                        page.profiles.forEachIndexed { index, profile ->
                            fields["profile${index}Id"] = profile.id
                            fields["profile${index}Name"] = profile.name
                            fields["profile${index}UpdatedAt"] = profile.updatedAt
                        }
                    }
        }
}

/** Dedicated one-page MANAGEMENT connection; has no input/session APIs. */
class PhoneCatalogClient
internal constructor(
    private val endpoint: TrustedHostEndpoint,
    private val connect: () -> NativeFrameIO,
    private val load: (String, Long) -> PhoneCredential?,
    private val now: () -> Long,
    private val requireWorker: Boolean = false,
) : Closeable {
    private val started = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)
    private val gate = Any()
    @Volatile private var io: NativeFrameIO? = null
    private var last = 0L
    private var expires: Long? = null

    @TargetApi(29)
    constructor(
        endpoint: TrustedHostEndpoint,
        context: Context,
    ) : this(
        endpoint,
        {
            val client =
                ControlTLSClient.connect(
                    InetSocketAddress(endpoint.host, endpoint.port),
                    endpoint.certificatePin,
                )
            object : NativeFrameIO {
                override fun send(frame: ControlTLSFrame) = client.send(frame)

                override fun receive() = client.receive()

                override fun close() = client.close()
            }
        },
        PhoneCredentialVault(context)::load,
        System::currentTimeMillis,
        true,
    )

    private fun checkpoint(): Long {
        val time = now()
        if (closed.get() || time < last || expires?.let { time >= it } == true)
            throw PhoneCatalogRejected()
        last = time
        return time
    }

    private fun send(value: JSONObject) {
        checkpoint()
        (io ?: throw PhoneCatalogRejected()).send(
            ControlTLSFrame(
                ControlTLSFrame.Kind.CONTROL,
                value.toString().toByteArray(Charsets.UTF_8),
            )
        )
    }

    private fun receive(): Map<String, EnrollmentJSON.Value> {
        val frame = (io ?: throw PhoneCatalogRejected()).receive()
        checkpoint()
        if (frame.kind != ControlTLSFrame.Kind.CONTROL || frame.payload.size > 32768)
            throw PhoneCatalogRejected()
        return EnrollmentJSON.parse(frame.payload, allowNull = true)
    }

    fun read(expectedRevision: String? = null, offset: Int = 0): PhoneCatalogResult {
        if (
            (requireWorker && Looper.myLooper() == Looper.getMainLooper()) ||
                offset !in 0..255 ||
                (expectedRevision?.let { !counter(it) } ?: (offset != 0)) ||
                !started.compareAndSet(false, true)
        )
            throw PhoneCatalogRejected()
        try {
            checkpoint()
            val channel = connect()
            synchronized(gate) {
                if (closed.get()) {
                    channel.close()
                    throw PhoneCatalogRejected()
                }
                io = channel
            }
            checkpoint()
            send(
                JSONObject()
                    .put("version", 1)
                    .put("command", "hello")
                    .put("controlVersion", 7)
                    .put("role", "management")
                    .put("inputVersion", 1)
                    .put("documentVersion", 1)
                    .put("capabilitiesVersion", 1)
            )
            val hello = receive()
            val expectedHello =
                mapOf(
                    "version" to EnrollmentJSON.Value.Integer(1),
                    "command" to EnrollmentJSON.Value.Text("hello"),
                    "authorityInstanceId" to
                        EnrollmentJSON.Value.Text(endpoint.authorityInstanceID),
                    "controlVersion" to EnrollmentJSON.Value.Integer(7),
                    "role" to EnrollmentJSON.Value.Text("management"),
                    "inputVersion" to EnrollmentJSON.Value.Integer(1),
                    "documentVersion" to EnrollmentJSON.Value.Integer(1),
                    "capabilitiesVersion" to EnrollmentJSON.Value.Integer(1),
                    "inputEnabled" to EnrollmentJSON.Value.BooleanValue(false),
                )
            if (hello != expectedHello) throw PhoneCatalogRejected()
            val credential =
                load(endpoint.certificatePin, checkpoint()) ?: throw PhoneCatalogRejected()
            checkpoint()
            if (
                credential.metadata.hostPin != endpoint.certificatePin ||
                    last >= credential.metadata.expiresAt
            )
                throw PhoneCatalogRejected()
            channel.send(credential.authenticationFrame(endpoint.authorityInstanceID))
            val admission = receive()
            val keys =
                setOf(
                    "version",
                    "command",
                    "authorityInstanceId",
                    "phoneId",
                    "credentialEpoch",
                    "connectionId",
                    "expiresAt",
                    "inputSessionAvailable",
                    "inputEnabled",
                    "role",
                )
            val connection =
                (admission["connectionId"] as? EnrollmentJSON.Value.Text)?.value
                    ?: throw PhoneCatalogRejected()
            val end =
                (admission["expiresAt"] as? EnrollmentJSON.Value.Integer)?.value
                    ?: throw PhoneCatalogRejected()
            if (
                admission.keys != keys ||
                    admission["version"] != EnrollmentJSON.Value.Integer(1) ||
                    admission["command"] != EnrollmentJSON.Value.Text("authenticated") ||
                    admission["authorityInstanceId"] !=
                        EnrollmentJSON.Value.Text(endpoint.authorityInstanceID) ||
                    admission["phoneId"] !=
                        EnrollmentJSON.Value.Text(credential.metadata.phoneID) ||
                    admission["credentialEpoch"] !=
                        EnrollmentJSON.Value.Text(credential.metadata.epoch.toString()) ||
                    admission["inputSessionAvailable"] !=
                        EnrollmentJSON.Value.BooleanValue(false) ||
                    admission["inputEnabled"] != EnrollmentJSON.Value.BooleanValue(false) ||
                    admission["role"] != EnrollmentJSON.Value.Text("management") ||
                    !hex(connection, 32) ||
                    end <= last ||
                    end > credential.metadata.expiresAt
            )
                throw PhoneCatalogRejected()
            // Host absolute expiry and local wall time are different clock domains.
            // The host still enforces its lease; independently cap our local operation.
            val localLimit =
                try {
                    Math.addExact(last, 60_000L)
                } catch (_: ArithmeticException) {
                    throw PhoneCatalogRejected()
                }
            expires = minOf(end, localLimit)
            send(
                JSONObject()
                    .put("version", 1)
                    .put("command", "configuration-list")
                    .put("connectionId", connection)
                    .put("expectedRevision", expectedRevision ?: JSONObject.NULL)
                    .put("offset", offset)
            )
            return decode(receive(), connection, expectedRevision, offset)
        } finally {
            close()
        }
    }

    override fun close() {
        if (closed.compareAndSet(false, true)) {
            synchronized(gate) {
                io?.close()
                io = null
            }
        }
    }

    companion object {
        private fun jsWhitespace(scalar: Int): Boolean =
            scalar in 0x9..0xD ||
                scalar == 0x20 ||
                scalar == 0xA0 ||
                scalar == 0x1680 ||
                scalar in 0x2000..0x200A ||
                scalar == 0x2028 ||
                scalar == 0x2029 ||
                scalar == 0x202F ||
                scalar == 0x205F ||
                scalar == 0x3000 ||
                scalar == 0xFEFF

        internal fun counter(value: String): Boolean =
            value.matches(Regex("0|[1-9][0-9]{0,19}")) &&
                (value.length < 20 || value <= "18446744073709551615")

        internal fun hex(value: String, count: Int) =
            value.length == count && value.all { it in '0'..'9' || it in 'a'..'f' }

        internal fun profileID(value: String) =
            value.matches(Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"))

        internal fun decode(
            fields: Map<String, EnrollmentJSON.Value>,
            connection: String,
            expected: String?,
            offset: Int,
        ): PhoneCatalogResult {
            fun text(key: String) =
                (fields[key] as? EnrollmentJSON.Value.Text)?.value ?: throw PhoneCatalogRejected()
            val envelope = setOf("version", "command", "connectionId", "kind")
            if (
                fields["version"] != EnrollmentJSON.Value.Integer(1) ||
                    fields["command"] != EnrollmentJSON.Value.Text("configuration-result") ||
                    fields["connectionId"] != EnrollmentJSON.Value.Text(connection)
            )
                throw PhoneCatalogRejected()
            when (text("kind")) {
                "error" -> {
                    val error = text("error")
                    if (
                        fields.keys != envelope + "error" ||
                            error !in
                                setOf(
                                    "phone_catalog_busy",
                                    "phone_catalog_timeout",
                                    "phone_catalog_unavailable",
                                )
                    )
                        throw PhoneCatalogRejected()
                    return PhoneCatalogResult.Unavailable(error)
                }
                "conflict" -> {
                    val revision = text("currentRevision")
                    if (
                        fields.keys != envelope + "currentRevision" ||
                            expected == null ||
                            !counter(revision) ||
                            expected == revision
                    )
                        throw PhoneCatalogRejected()
                    return PhoneCatalogResult.Conflict(revision)
                }
                "catalog" -> {
                    val revision = text("revision")
                    val count =
                        (fields["profileCount"] as? EnrollmentJSON.Value.Integer)?.value
                            ?: throw PhoneCatalogRejected()
                    if (
                        !counter(revision) ||
                            (expected != null && expected != revision) ||
                            count !in 0..16
                    )
                        throw PhoneCatalogRejected()
                    val keys =
                        (envelope +
                                setOf(
                                    "revision",
                                    "contentHash",
                                    "activeProfileId",
                                    "defaultProfileId",
                                    "nextOffset",
                                    "profileCount",
                                ))
                            .toMutableSet()
                    val profiles = mutableListOf<PhoneCatalogProfile>()
                    repeat(count.toInt()) { index ->
                        val prefix = "profile$index"
                        keys.addAll(listOf(prefix + "Id", prefix + "Name", prefix + "UpdatedAt"))
                        val id = text(prefix + "Id")
                        val name = text(prefix + "Name")
                        val updated = text(prefix + "UpdatedAt")
                        if (
                            !profileID(id) ||
                                !name.codePoints().anyMatch { !jsWhitespace(it) } ||
                                !EnrollmentInvitation.scalarText(name) ||
                                name.codePointCount(0, name.length) > 256 ||
                                !counter(updated) ||
                                updated.toLongOrNull() == null ||
                                profiles.any { it.id == id }
                        )
                            throw PhoneCatalogRejected()
                        profiles.add(PhoneCatalogProfile(id, name, updated))
                    }
                    fun nullable(key: String, valid: (String) -> Boolean): String? {
                        if (fields[key] === EnrollmentJSON.Value.Null) return null
                        val value = text(key)
                        if (!valid(value)) throw PhoneCatalogRejected()
                        return value
                    }
                    val hash = nullable("contentHash") { hex(it, 64) }
                    val active = nullable("activeProfileId", ::profileID)
                    val standard = nullable("defaultProfileId", ::profileID)
                    val next =
                        if (fields["nextOffset"] === EnrollmentJSON.Value.Null) null
                        else {
                            val value =
                                (fields["nextOffset"] as? EnrollmentJSON.Value.Integer)?.value
                                    ?: throw PhoneCatalogRejected()
                            if (value !in 0..255 || count != 16L || value != offset + count)
                                throw PhoneCatalogRejected()
                            value.toInt()
                        }
                    if (
                        fields.keys != keys ||
                            if (revision == "0") {
                                hash != null ||
                                    profiles.isNotEmpty() ||
                                    active != null ||
                                    standard != null ||
                                    next != null
                            } else hash == null
                    )
                        throw PhoneCatalogRejected()
                    return PhoneCatalogResult.Catalog(
                        PhoneCatalogPage(
                            revision,
                            hash,
                            active,
                            standard,
                            next,
                            Collections.unmodifiableList(profiles.toList()),
                        )
                    )
                }
                else -> throw PhoneCatalogRejected()
            }
        }
    }
}
