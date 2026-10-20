// mob_scanner plugin — Android bridge (QR/barcode scanner).
//
// Extracted from mob-core's MobBridge scanner_scan / handleScanResult
// (MobBridge.kt.eex:1359-1375) plus MainActivity's scannerLauncher /
// launchQrScanner (MainActivity.kt.eex:51-64). Lives in the plugin's own
// package; MobPluginBootstrap.registerAll() calls register() at startup and
// hands it the Activity (MobActivityAware). It is NOT a
// MobPermissionProvider — the :camera runtime permission is owned by the
// mob_camera plugin (activate mob_camera alongside mob_scanner).
//
// The native thunks (nativeRegister + the two deliver hooks) are exported
// directly from the sibling zig NIF mob_scanner_nif.zig.
//
// DESIGN NOTE vs core: core pre-registered the scanner launcher in
// MainActivity's onCreate via registerForActivityResult
// (MainActivity.kt.eex:54-59) and the bridge delegated to
// MainActivity.launchQrScanner() (MobBridge.kt.eex:1363), with the result
// handed back through the static MobBridge.handleScanResult
// (MainActivity.kt.eex:58). A late-bound plugin can't reference the
// generated MainActivity class, and registerForActivityResult must run
// before the host reaches STARTED — so this bridge registers directly on
// the ComponentActivity's ActivityResultRegistry (register(key, contract,
// callback) is callable any time), launches the plugin-owned
// MobScannerActivity Intent itself, handles the Intent extras in the
// callback, and unregisters — self-contained, no host MainActivity changes.
// (Same pattern as mob_camera's MobCameraBridge / mob_photos'
// MobPhotosBridge.) The pid travels through the closure instead of core's
// pendingScanPid static (MobBridge.kt.eex:1362).
package io.mob.scanner

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.ActivityResultRegistryOwner
import androidx.activity.result.contract.ActivityResultContract
import androidx.activity.result.contract.ActivityResultContracts
import java.lang.ref.WeakReference
import java.util.concurrent.atomic.AtomicLong
import android.os.Bundle
import android.util.Size
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageButton
import androidx.annotation.OptIn
import androidx.appcompat.app.AppCompatActivity
import androidx.camera.core.CameraSelector
import androidx.camera.core.ExperimentalGetImage
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import java.util.concurrent.Executors
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

// TESTABLE_WIRE_START
// Kept in the manifest's one shipping Kotlin source so the host build and the
// JVM regression harness exercise the same serializer, limits, and format map.
internal object ScannerWire {
    const val MAX_VALUE_UTF8_BYTES = 16 * 1024
    const val MAX_TYPE_UTF8_BYTES = 64
    const val FORMATS_EXTRA = "mob_scanner_formats"

    // Bound untrusted JNI input before JSON parsing. Duplicates inside this
    // request-size limit are ignored rather than counting toward format count.
    private const val MAX_FORMATS_JSON_CHARS = 16 * 1024

    private val supportedFormats = linkedMapOf(
        "qr" to Barcode.FORMAT_QR_CODE,
        "ean13" to Barcode.FORMAT_EAN_13,
        "ean8" to Barcode.FORMAT_EAN_8,
        "code128" to Barcode.FORMAT_CODE_128,
        "code39" to Barcode.FORMAT_CODE_39,
        "upca" to Barcode.FORMAT_UPC_A,
        "upce" to Barcode.FORMAT_UPC_E,
        "pdf417" to Barcode.FORMAT_PDF417,
        "aztec" to Barcode.FORMAT_AZTEC,
        "data_matrix" to Barcode.FORMAT_DATA_MATRIX,
    )

    fun encodeResult(
        value: String,
        type: String,
    ): ByteArray? {
        if (!fitsUtf8(value, MAX_VALUE_UTF8_BYTES) || !fitsUtf8(type, MAX_TYPE_UTF8_BYTES)) {
            return null
        }

        val item = JSONObject()
            .put("type", type)
            .put("value", value)
        return JSONArray().put(item).toString().toByteArray(Charsets.UTF_8)
    }

    fun barcodeFormats(formatsJson: String): IntArray? {
        if (formatsJson.length > MAX_FORMATS_JSON_CHARS) return null

        val requested = try {
            JSONArray(formatsJson)
        } catch (_: JSONException) {
            return null
        }
        if (requested.length() == 0) return null

        val selected = linkedSetOf<Int>()
        for (index in 0 until requested.length()) {
            val name = requested.opt(index) as? String ?: return null
            selected += supportedFormats[name] ?: return null
        }
        return selected.toIntArray()
    }

    fun scannerOptions(formats: IntArray): BarcodeScannerOptions? {
        if (formats.isEmpty()) return null
        return BarcodeScannerOptions.Builder()
            .setBarcodeFormats(formats.first(), *formats.drop(1).toIntArray())
            .build()
    }

    fun formatName(format: Int): String? =
        supportedFormats.entries.firstOrNull { it.value == format }?.key

    private fun fitsUtf8(
        value: String,
        limit: Int,
    ): Boolean = value.length <= limit && value.toByteArray(Charsets.UTF_8).size <= limit
}
// TESTABLE_WIRE_END

object MobScannerBridge : io.mob.plugin.MobActivityAware {
    private const val TAG = "MobScanner"

    private var activityRef: WeakReference<Activity>? = null

    @JvmStatic external fun nativeRegister()

    // {:scan, :cancelled}
    @JvmStatic external fun nativeDeliverScanCancelled(pid: Long)

    // {:scan, :not_available} — the scanner Activity could not be launched.
    @JvmStatic external fun nativeDeliverScanNotAvailable(pid: Long)

    // {:scan, :permission_denied} — :camera refused.
    @JvmStatic external fun nativeDeliverScanPermissionDenied(pid: Long)

    // {:mob_file_result, "scan", "result", json} — decoded by core
    // Mob.Screen into {:scan, :result, %{type: atom, value: binary}}
    // (lib/mob/screen.ex:382-384)
    @JvmStatic external fun nativeDeliverScanResult(
        pid: Long,
        jsonUtf8: ByteArray,
    )

    @JvmStatic fun register() = nativeRegister()

    override fun setActivity(activity: Activity) {
        activityRef = WeakReference(activity)
    }

    private val scanSeq = AtomicLong(0L)

    // ── Readiness probe (MOB-418) ─────────────────────────────────────────
    // Signature matches what the zig NIF calls: ()I. Side-effect free: no
    // camera is opened, nothing is launched or registered. Answers the codes
    // nif_scanner_available maps to atoms (0 is reserved: it is what the NIF
    // sees when this method throws):
    //   1 available, 2 no camera, 3 no Activity handed over by the bootstrap,
    //   4 MobScannerActivity not declared in the host manifest (a scan would
    //   end in {:scan, :not_available}), 5 the PackageManager query threw.
    // Resolving the explicit Intent is the same lookup launch() does, so 1/2
    // mean the manifest snippet was spliced into the host.
    @JvmStatic
    fun scanner_available(): Int {
        val activity = activityRef?.get() ?: return 3
        return try {
            val pm = activity.packageManager
            when {
                Intent(activity, MobScannerActivity::class.java).resolveActivity(pm) == null -> 4
                !pm.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY) -> 2
                else -> 1
            }
        } catch (e: RuntimeException) {
            Log.e(TAG, "scanner_available: PackageManager query failed", e)
            5
        }
    }

    // ── Scan ──────────────────────────────────────────────────────────────
    // Signature matches what the zig NIF calls: (JLjava/lang/String;)V.
    // The requested list is decoded before any UI opens. Empty, malformed, or
    // unsupported lists end in {:scan, :not_available}; valid names are
    // de-duplicated in request order and become ML Kit's exact format set.
    //
    // Called on a BEAM scheduler thread. Everything past the activity lookup
    // hops to the UI thread: ActivityResultRegistry.register()/launch() belong
    // there (same as mob_camera's launchCapture), and an exception thrown on
    // the NIF thread is uncaught and kills the whole process (MOB-293).
    @JvmStatic
    fun scanner_scan(
        pid: Long,
        formatsJson: String,
    ) {
        val formats = ScannerWire.barcodeFormats(formatsJson)
        if (formats == null) {
            Log.w(TAG, "scan: invalid or unsupported formats, delivering {:scan, :not_available}")
            nativeDeliverScanNotAvailable(pid)
            return
        }
        val activity =
            activityRef?.get() ?: run {
                nativeDeliverScanCancelled(pid)
                return
            }
        activity.runOnUiThread {
            val owner =
                activity as? ActivityResultRegistryOwner ?: run {
                    nativeDeliverScanCancelled(pid)
                    return@runOnUiThread
                }
            val granted =
                ContextCompat.checkSelfPermission(activity, Manifest.permission.CAMERA) ==
                    PackageManager.PERMISSION_GRANTED
            if (granted) {
                launchScanner(activity, owner, pid, formats)
            } else {
                requestCameraThenScan(activity, owner, pid, formats)
            }
        }
    }

    // MOB-292 parity with iOS: an undecided :camera permission is requested
    // here instead of opening a preview CameraX can't feed. A permanently
    // denied permission resolves to granted=false without showing a dialog.
    private fun requestCameraThenScan(
        activity: Activity,
        owner: ActivityResultRegistryOwner,
        pid: Long,
        formats: IntArray,
    ) {
        launchForResult(
            activity,
            owner,
            pid,
            ActivityResultContracts.RequestPermission(),
            Manifest.permission.CAMERA,
        ) { granted ->
            if (granted) {
                launchScanner(activity, owner, pid, formats)
            } else {
                Log.w(TAG, "scan: android.permission.CAMERA denied")
                nativeDeliverScanPermissionDenied(pid)
            }
        }
    }

    private fun launchScanner(
        activity: Activity,
        owner: ActivityResultRegistryOwner,
        pid: Long,
        formats: IntArray,
    ) {
        launchForResult(
            activity,
            owner,
            pid,
            ActivityResultContracts.StartActivityForResult(),
            Intent(activity, MobScannerActivity::class.java).putExtra(ScannerWire.FORMATS_EXTRA, formats),
        ) { result ->
            // Same extras contract as core (MainActivity.kt.eex:55-58):
            // MobScannerActivity returns scan_value/scan_type Intent
            // extras on RESULT_OK, nothing on RESULT_CANCELED.
            val value = result.data?.getStringExtra("scan_value")
            val type = result.data?.getStringExtra("scan_type") ?: "qr"
            handleScanResult(pid, value, type)
        }
    }

    // Registers a one-shot launcher, launches it, and unregisters it after the
    // result has been dispatched. Unregistering inline from the callback would
    // run inside ActivityResultRegistry.doDispatch, before the key leaves
    // mLaunchedKeys, and unregister() then keeps the request-code/key mapping
    // (it lingers in the registry and its saved state) — so the unregister is
    // posted to run once dispatch has unwound. A launch that throws
    // (ActivityNotFoundException when the
    // <activity> isn't in the host manifest, IllegalStateException, a
    // SecurityException, ...) is terminal for this scan, never for the app:
    // the launcher is unregistered, the cause goes to logcat, and the caller
    // gets {:scan, :not_available} (MOB-293).
    //
    // The launch runs from a posted UI-thread block (or a result callback), so
    // the Activity captured at scanner_scan time may be finishing, destroyed,
    // or replaced by then. Its registry would never dispatch a result — the
    // scan would get no terminal message — so it is rejected before anything
    // is registered, with the same {:scan, :not_available}.
    private fun <I, O> launchForResult(
        activity: Activity,
        owner: ActivityResultRegistryOwner,
        pid: Long,
        contract: ActivityResultContract<I, O>,
        input: I,
        onResult: (O) -> Unit,
    ) {
        if (activity.isFinishing || activity.isDestroyed || activityRef?.get() !== activity) {
            Log.w(TAG, "scan: host Activity finishing/destroyed/replaced, delivering {:scan, :not_available}")
            nativeDeliverScanNotAvailable(pid)
            return
        }
        val key = "mob_scanner_${scanSeq.incrementAndGet()}"
        var launcher: ActivityResultLauncher<I>? = null
        try {
            launcher =
                owner.activityResultRegistry.register(key, contract) { output ->
                    val done = launcher
                    Handler(Looper.getMainLooper()).post { done?.unregister() }
                    onResult(output)
                }
            launcher.launch(input)
        } catch (e: RuntimeException) {
            launcher?.unregister()
            Log.e(TAG, "scan: launching $key failed, delivering {:scan, :not_available}", e)
            nativeDeliverScanNotAvailable(pid)
        }
    }

    // A null value is cancellation. Results are size-checked before Android's
    // platform JSON implementation serializes them. Oversized values are not
    // truncated or delivered as malformed partial results: they end in the
    // API's controlled {:scan, :not_available} terminal state.
    internal fun handleScanResult(
        pid: Long,
        value: String?,
        type: String?,
    ) {
        if (value == null) {
            nativeDeliverScanCancelled(pid)
            return
        }
        val jsonUtf8 = ScannerWire.encodeResult(value, type ?: "qr")
        if (jsonUtf8 == null) {
            Log.w(
                TAG,
                "scan: decoded result exceeds ${ScannerWire.MAX_VALUE_UTF8_BYTES}-byte value or " +
                    "${ScannerWire.MAX_TYPE_UTF8_BYTES}-byte type limit; delivering {:scan, :not_available}",
            )
            nativeDeliverScanNotAvailable(pid)
            return
        }
        nativeDeliverScanResult(pid, jsonUtf8)
    }
}

// ── MobScannerActivity ─────────────────────────────────────────────────
// Lives in this file because the build's bridge_kt channel copies exactly
// ONE Kotlin file per plugin into the host sourceSet — Kotlin allows
// multiple top-level classes per file. (A multi-file `android.kotlin_files`
// manifest capability is the systemic alternative if a plugin ever
// genuinely needs separate files.)
//
// This is the single authoritative shipping source; there is no second
// activity template in this repo. MobScannerBridge launches it via an explicit
// Intent; it returns the scanned value/type as scan_value / scan_type Intent
// extras (RESULT_OK) or RESULT_CANCELED.
//
// The AndroidManifest declaration comes from this plugin's manifest
// (android.manifest_application_snippets in priv/mob_plugin.exs), spliced
// into the host <application> by `mix mob.deploy --native`. The AppCompat
// theme it sets is required: this extends AppCompatActivity (CameraX + ML
// Kit need it), which throws IllegalStateException at setContentView when
// the activity's theme isn't AppCompat-derived.
class MobScannerActivity : AppCompatActivity() {
    private val executor = Executors.newSingleThreadExecutor()
    private var scanHandled = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val scannerOptions =
            ScannerWire.scannerOptions(
                intent.getIntArrayExtra(ScannerWire.FORMATS_EXTRA) ?: intArrayOf(),
            ) ?: run {
                Log.e("MobScanner", "scan: Activity received no valid format configuration")
                setResult(Activity.RESULT_CANCELED)
                finish()
                return
            }

        val container = FrameLayout(this)
        setContentView(container)

        val previewView = PreviewView(this).also {
            it.layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
            container.addView(it)
        }

        // Cancel button
        val cancelBtn = ImageButton(this).also {
            it.setImageResource(android.R.drawable.ic_menu_close_clear_cancel)
            it.layoutParams = FrameLayout.LayoutParams(128, 128).apply { setMargins(32, 80, 0, 0) }
            it.setOnClickListener { setResult(Activity.RESULT_CANCELED); finish() }
            container.addView(it)
        }

        val cameraProviderFuture = ProcessCameraProvider.getInstance(this)
        cameraProviderFuture.addListener({
            val cameraProvider = cameraProviderFuture.get()
            val preview = Preview.Builder().build().also {
                it.setSurfaceProvider(previewView.surfaceProvider)
            }
            val imageAnalyzer = ImageAnalysis.Builder()
                .setTargetResolution(Size(1280, 720))
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
                .also { analysis ->
                    val scanner = BarcodeScanning.getClient(scannerOptions)
                    analysis.setAnalyzer(executor) { imageProxy ->
                        @OptIn(ExperimentalGetImage::class)
                        val mediaImage = imageProxy.image
                        if (mediaImage != null && !scanHandled) {
                            val image = InputImage.fromMediaImage(mediaImage, imageProxy.imageInfo.rotationDegrees)
                            scanner.process(image)
                                .addOnSuccessListener { barcodes ->
                                    barcodes.firstOrNull()?.rawValue?.let { value ->
                                        if (!scanHandled) {
                                            scanHandled = true
                                            val type = ScannerWire.formatName(barcodes.first().format) ?: "qr"
                                            val result = Intent().apply {
                                                putExtra("scan_value", value)
                                                putExtra("scan_type", type)
                                            }
                                            setResult(Activity.RESULT_OK, result)
                                            finish()
                                        }
                                    }
                                }
                                .addOnCompleteListener { imageProxy.close() }
                        } else {
                            imageProxy.close()
                        }
                    }
                }
            try {
                cameraProvider.unbindAll()
                cameraProvider.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, preview, imageAnalyzer)
            } catch (e: Exception) {
                setResult(Activity.RESULT_CANCELED); finish()
            }
        }, ContextCompat.getMainExecutor(this))
    }

    override fun onDestroy() {
        super.onDestroy()
        executor.shutdown()
    }
}
