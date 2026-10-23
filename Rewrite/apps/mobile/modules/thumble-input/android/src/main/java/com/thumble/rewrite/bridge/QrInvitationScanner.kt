package com.thumble.rewrite.bridge

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.content.pm.PackageManager
import android.os.Looper
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import com.facebook.react.modules.core.PermissionAwareActivity
import com.facebook.react.modules.core.PermissionListener
import com.google.zxing.BarcodeFormat
import com.journeyapps.barcodescanner.BarcodeCallback
import com.journeyapps.barcodescanner.BarcodeResult
import com.journeyapps.barcodescanner.CameraPreview
import com.journeyapps.barcodescanner.DecoratedBarcodeView
import com.journeyapps.barcodescanner.DefaultDecoderFactory
import com.thumble.rewrite.input.EnrollmentInvitation
import java.io.Closeable

/** A native, one-result camera owner. Invitation text never crosses the React boundary. */
internal class QrInvitationScanner(
    private val activity: Activity,
    private val accepted: (EnrollmentInvitation) -> Unit,
) : Closeable {
    var awaitingPermission = false
        private set

    private var finished = false
    private var dialog: AlertDialog? = null
    private var preview: DecoratedBarcodeView? = null

    fun start() {
        try {
            requestCamera()
        } catch (_: Exception) {
            unavailable()
        }
    }

    private fun requestCamera() {
        check(Looper.myLooper() == Looper.getMainLooper())
        if (finished) return
        if (
            activity.checkSelfPermission(Manifest.permission.CAMERA) ==
                PackageManager.PERMISSION_GRANTED
        ) {
            showCamera()
            return
        }
        val owner = activity as? PermissionAwareActivity
        if (owner == null) {
            unavailable()
            return
        }
        awaitingPermission = true
        owner.requestPermissions(
            arrayOf(Manifest.permission.CAMERA),
            REQUEST_CODE,
            PermissionListener { requestCode, _, results ->
                if (requestCode != REQUEST_CODE) false
                else {
                    awaitingPermission = false
                    if (
                        !finished &&
                            results.size == 1 &&
                            results[0] == PackageManager.PERMISSION_GRANTED
                    )
                        try {
                            showCamera()
                        } catch (_: Exception) {
                            unavailable()
                        }
                    else unavailable()
                    true
                }
            },
        )
    }

    private fun showCamera() {
        if (finished || activity.isFinishing || activity.isDestroyed) return close()
        val hint =
            TextView(activity).apply {
                text = "Point your camera at the pairing code on your Mac."
                setPadding(24, 16, 24, 16)
            }
        val camera =
            DecoratedBarcodeView(activity).apply {
                contentDescription = "Pairing code camera"
                barcodeView.decoderFactory = DefaultDecoderFactory(listOf(BarcodeFormat.QR_CODE))
                setStatusText("")
            }
        camera.barcodeView.addStateListener(
            object : CameraPreview.StateListener {
                override fun previewSized() {}

                override fun previewStarted() {}

                override fun previewStopped() {}

                override fun cameraClosed() {}

                override fun cameraError(error: Exception) {
                    if (!finished) unavailable()
                }
            }
        )
        preview = camera
        val content =
            LinearLayout(activity).apply {
                orientation = LinearLayout.VERTICAL
                addView(hint)
                addView(
                    camera,
                    LinearLayout.LayoutParams(-1, (140 * resources.displayMetrics.density).toInt()),
                )
            }
        val alert =
            AlertDialog.Builder(activity)
                .setTitle("Scan pairing code")
                .setView(content)
                .setNegativeButton("Enter manually") { _, _ -> close() }
                .create()
        dialog = alert
        alert.setOnDismissListener { close() }
        alert.show()
        alert.window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        camera.decodeContinuous(
            object : BarcodeCallback {
                override fun barcodeResult(result: BarcodeResult) {
                    if (finished) return
                    val text = result.text ?: return
                    val invitation = QrInvitationCandidate.decode(text)
                    if (invitation == null) {
                        hint.text =
                            "This is not a valid Thumble pairing code. Try again or enter it manually."
                        return
                    }
                    close()
                    accepted(invitation)
                }
            }
        )
        camera.resume()
    }

    private fun unavailable() {
        if (finished) return
        close()
        Toast.makeText(
                activity,
                "Camera unavailable. You can enter the pairing invitation manually.",
                Toast.LENGTH_LONG,
            )
            .show()
    }

    override fun close() {
        check(Looper.myLooper() == Looper.getMainLooper())
        if (finished) return
        finished = true
        awaitingPermission = false
        preview?.pause()
        preview = null
        val old = dialog
        dialog = null
        old?.dismiss()
    }

    companion object {
        private const val REQUEST_CODE = 0x5448
    }
}
