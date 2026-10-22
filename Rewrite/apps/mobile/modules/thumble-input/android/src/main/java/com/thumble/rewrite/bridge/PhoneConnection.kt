package com.thumble.rewrite.bridge

import android.app.Activity
import android.app.AlertDialog
import android.app.Application
import android.content.Context
import android.content.ContextWrapper
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.InputFilter
import android.text.InputType
import android.view.View
import android.view.WindowManager
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.Switch
import com.thumble.rewrite.contracts.GamepadStateV1
import com.thumble.rewrite.input.*
import java.io.Closeable
import java.util.UUID
import java.util.concurrent.Executors
import org.json.JSONObject

/** Native bootstrap and channel owner. Neither invitation text nor vault material enters React. */
internal class PhoneConnection(
    private val anchor: View,
    private val feedback: (GamepadStateV1) -> Unit,
    private val install: (InputEngine) -> Unit,
    private val status: (String) -> Unit,
    private val catalogResult: (Map<String, Any?>) -> Unit = {},
    private val installedMap: (Map<String, Any>) -> Unit = {},
    private val testOnlyMapProvider: ((PhoneInputConfiguration, Double, Double) -> ControlMap)? =
        null,
) : Closeable {
    private val gate = Any()
    @Volatile private var closed = false
    private var prompt: AlertDialog? = null
    private var field: EditText? = null
    private var enrollment: PhoneEnrollmentClient? = null
    private var control: PhoneControlClient? = null
    private var catalogClient: PhoneCatalogClient? = null
    private var savedMapClient: SavedControllerClient? = null
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor { task ->
        Thread(task, "ThumblePhoneBootstrap").apply { isDaemon = true }
    }
    private val preferences =
        anchor.context.getSharedPreferences("rewrite.phone.v1", Context.MODE_PRIVATE)

    private val application = anchor.context.applicationContext as Application
    private val lifecycle =
        object : Application.ActivityLifecycleCallbacks {
            override fun onActivityPaused(activity: Activity) {
                var context: Context = anchor.context
                while (context is ContextWrapper && context !== activity) {
                    val next = context.baseContext
                    if (next === context) break
                    context = next
                }
                if (context === activity && !closed) {
                    close()
                    status("disconnected")
                }
            }

            override fun onActivityStopped(activity: Activity) {}

            override fun onActivityDestroyed(activity: Activity) {}

            override fun onActivityCreated(activity: Activity, state: Bundle?) {}

            override fun onActivityStarted(activity: Activity) {}

            override fun onActivityResumed(activity: Activity) {}

            override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) {}
        }

    init {
        application.registerActivityLifecycleCallbacks(lifecycle)
    }

    fun start(template: ControlMap? = null) {
        check(Looper.myLooper() == Looper.getMainLooper())
        if (closed || !anchor.isAttachedToWindow) return
        var context: Context = anchor.context
        while (context is ContextWrapper && context !is Activity) context = context.baseContext
        val activity = context as? Activity ?: return fail()
        val input =
            EditText(activity).apply {
                hint = "Pairing invitation"
                contentDescription = "Pairing invitation"
                inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
                filters = arrayOf(InputFilter.LengthFilter(4096))
                importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
                importantForContentCapture =
                    View.IMPORTANT_FOR_CONTENT_CAPTURE_NO_EXCLUDE_DESCENDANTS
                isSaveEnabled = false
            }
        field = input
        val touchFeedback =
            Switch(activity).apply {
                text = "Touch feedback"
                minimumHeight = (48 * resources.displayMetrics.density).toInt()
                contentDescription = "Touch feedback"
                isChecked = TouchHapticPreferences.intensity(activity) > 0
                setOnCheckedChangeListener { _, enabled ->
                    TouchHapticPreferences.setEnabled(activity, enabled)
                }
            }
        val content =
            LinearLayout(activity).apply {
                orientation = LinearLayout.VERTICAL
                addView(input)
                addView(touchFeedback)
            }
        val builder =
            AlertDialog.Builder(activity)
                .setTitle("Connect to your computer")
                .setMessage("Paste the pairing invitation from your agent. It stays on this phone.")
                .setView(content)
                .setNegativeButton("Cancel") { _, _ ->
                    close()
                    status("cancelled")
                }
                .setPositiveButton("Pair") { _, _ ->
                    val text = input.text.toString()
                    input.text.clear()
                    val invitation = runCatching {
                        EnrollmentInvitation.decode(text.toByteArray(Charsets.UTF_8))
                    }
                        .getOrNull()
                    if (invitation == null) fail() else launch(template, invitation, null)
                }
        savedEndpoint()?.let { endpoint ->
            builder.setNeutralButton("Reconnect") { _, _ ->
                input.text.clear()
                launch(template, null, endpoint)
            }
        }
        val alert = builder.create()
        alert.setOnCancelListener {
            if (!closed) {
                close()
                status("cancelled")
            }
        }
        alert.setOnDismissListener {
            input.text.clear()
            field = null
            prompt = null
        }
        prompt = alert
        alert.window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        status("waiting")
        alert.show()
        alert.window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    private fun launch(
        template: ControlMap?,
        invitation: EnrollmentInvitation?,
        saved: TrustedHostEndpoint?,
    ) {
        if (closed || !anchor.isAttachedToWindow) return
        status(if (invitation != null) "pairing" else "connecting")
        val viewportWidth = anchor.width
        val viewportHeight = anchor.height
        val density = anchor.resources.displayMetrics.density.toDouble()
        worker.execute {
            try {
                val endpoint =
                    if (invitation != null) {
                        val client =
                            PhoneEnrollmentClient(invitation, anchor.context.applicationContext)
                        synchronized(gate) {
                            check(!closed)
                            enrollment = client
                        }
                        val phoneID =
                            preferences.getString("phoneID", null) ?: UUID.randomUUID().toString()
                        check(preferences.edit().putString("phoneID", phoneID).commit())
                        client.enroll(phoneID, "Thumble Android")
                        client.close()
                        synchronized(gate) {
                            enrollment = null
                            check(!closed)
                        }
                        TrustedHostEndpoint(
                                invitation.host,
                                invitation.port,
                                invitation.certificatePin,
                                invitation.authorityInstanceID,
                            )
                            .also {
                                check(
                                    preferences
                                        .edit()
                                        .putString(
                                            "endpoint",
                                            JSONObject()
                                                .put("host", it.host)
                                                .put("port", it.port)
                                                .put("pin", it.certificatePin)
                                                .put("authority", it.authorityInstanceID)
                                                .toString(),
                                        )
                                        .commit()
                                )
                            }
                    } else checkNotNull(saved)
                val client =
                    PhoneControlClient(
                        endpoint,
                        anchor.context.applicationContext,
                        inputSessions = true,
                        datagrams = true,
                        renewals = true,
                    )
                synchronized(gate) {
                    check(!closed)
                    control = client
                }
                main.post { if (!closed) status("connecting") }
                check(client.authenticate().inputSessionAvailable)
                val metadata = client.inputConfiguration()
                check(metadata.active)
                val map: ControlMap
                var delivered: SavedControllerMap? = null
                var catalogMetadata: Map<String, Any?>? = null
                if (testOnlyMapProvider != null) {
                    map =
                        testOnlyMapProvider.invoke(
                            metadata,
                            viewportWidth / density,
                            viewportHeight / density,
                        )
                    check(
                        map.generation == metadata.generation && map.revision == metadata.revision
                    )
                    // prepareInput below validates the full map before granting ownership.
                } else {
                    val catalog = PhoneCatalogClient(endpoint, anchor.context.applicationContext)
                    synchronized(gate) {
                        check(!closed)
                        catalogClient = catalog
                    }
                    val pageResult = catalog.read()
                    synchronized(gate) {
                        catalogClient = null
                        check(!closed)
                    }
                    val page =
                        (pageResult as? PhoneCatalogResult.Catalog)?.page
                            ?: throw SavedControllerRejected()
                    val request =
                        SavedControllerRequest(
                            page.revision,
                            page.contentHash ?: throw SavedControllerRejected(),
                            page.activeProfileID ?: throw SavedControllerRejected(),
                            metadata.generation,
                            metadata.revision,
                            (viewportWidth / density).toString(),
                            (viewportHeight / density).toString(),
                        )
                    val maps = SavedControllerClient(endpoint, anchor.context.applicationContext)
                    synchronized(gate) {
                        check(!closed)
                        savedMapClient = maps
                    }
                    val resultMap = maps.read(request)
                    synchronized(gate) {
                        savedMapClient = null
                        check(!closed)
                    }
                    delivered = resultMap
                    map = resultMap.map
                    catalogMetadata = pageResult.bridgeMetadata()
                }
                val admission = client.prepareInput(map)
                main.post {
                    if (
                        closed ||
                            !anchor.isAttachedToWindow ||
                            !anchor.hasWindowFocus() ||
                            anchor.width != viewportWidth ||
                            anchor.height != viewportHeight ||
                            anchor.resources.displayMetrics.density.toDouble() != density
                    ) {
                        admission.close()
                        fail()
                    } else
                        try {
                            install(admission.bind(feedback))
                            delivered?.let { installedMap(it.bridgeMap) }
                            catalogMetadata?.let(catalogResult)
                        } catch (_: Exception) {
                            admission.close()
                            fail()
                        }
                }
            } catch (_: Exception) {
                main.post { fail() }
            }
        }
    }

    private fun fail() {
        if (closed) return
        close()
        status("unavailable")
    }

    override fun close() {
        check(Looper.myLooper() == Looper.getMainLooper())
        synchronized(gate) {
            if (closed) return
            closed = true
            catalogClient?.close()
            catalogClient = null
            savedMapClient?.close()
            savedMapClient = null
            enrollment?.close()
            enrollment = null
            control?.close()
            control = null
        }
        application.unregisterActivityLifecycleCallbacks(lifecycle)
        worker.shutdownNow()
        field?.text?.clear()
        field = null
        prompt?.dismiss()
        prompt = null
    }

    private fun savedEndpoint(): TrustedHostEndpoint? = runCatching {
        val text = preferences.getString("endpoint", null) ?: return null
        check(text.toByteArray(Charsets.UTF_8).size <= 1024)
        val value = JSONObject(text)
        check(value.keys().asSequence().toSet() == setOf("host", "port", "pin", "authority"))
        TrustedHostEndpoint(
            value.getString("host"),
            value.getInt("port"),
            value.getString("pin"),
            value.getString("authority"),
        )
    }
        .getOrNull()
}
