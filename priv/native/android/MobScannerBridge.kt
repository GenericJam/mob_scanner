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

import android.app.Activity
import android.content.Intent
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.ActivityResultRegistryOwner
import androidx.activity.result.contract.ActivityResultContracts
import java.lang.ref.WeakReference
import java.util.concurrent.atomic.AtomicLong

object MobScannerBridge : io.mob.plugin.MobActivityAware {
    private var activityRef: WeakReference<Activity>? = null

    @JvmStatic external fun nativeRegister()

    // {:scan, :cancelled}
    @JvmStatic external fun nativeDeliverScanCancelled(pid: Long)

    // {:mob_file_result, "scan", "result", json} — decoded by core
    // Mob.Screen into {:scan, :result, %{type: atom, value: binary}}
    // (lib/mob/screen.ex:382-384)
    @JvmStatic external fun nativeDeliverScanResult(
        pid: Long,
        json: String,
    )

    @JvmStatic fun register() = nativeRegister()

    override fun setActivity(activity: Activity) {
        activityRef = WeakReference(activity)
    }

    private val scanSeq = AtomicLong(0L)

    // ── Scan ──────────────────────────────────────────────────────────────
    // Signature matches what the zig NIF calls: (JLjava/lang/String;)V.
    // PARITY: formatsJson is accepted but ignored, exactly like core
    // (MobBridge.kt.eex:1361-1365) — MobScannerActivity scans all ML Kit
    // formats regardless.
    @JvmStatic
    fun scanner_scan(
        pid: Long,
        formatsJson: String,
    ) {
        val activity =
            activityRef?.get() ?: run {
                nativeDeliverScanCancelled(pid)
                return
            }
        val owner =
            activity as? ActivityResultRegistryOwner ?: run {
                nativeDeliverScanCancelled(pid)
                return
            }
        val key = "mob_scanner_${scanSeq.incrementAndGet()}"
        var launcher: ActivityResultLauncher<Intent>? = null
        launcher =
            owner.activityResultRegistry.register(
                key,
                ActivityResultContracts.StartActivityForResult(),
            ) { result ->
                // Same extras contract as core (MainActivity.kt.eex:55-58):
                // MobScannerActivity returns scan_value/scan_type Intent
                // extras on RESULT_OK, nothing on RESULT_CANCELED.
                val value = result.data?.getStringExtra("scan_value")
                val type = result.data?.getStringExtra("scan_type") ?: "qr"
                handleScanResult(pid, value, type)
                launcher?.unregister()
            }
        launcher.launch(Intent(activity, MobScannerActivity::class.java))
    }

    // Result processing copied from core MobBridge.handleScanResult
    // (MobBridge.kt.eex:1368-1375): null value -> cancelled; otherwise a
    // single-item JSON array [{"type","value"}] with quote escaping,
    // delivered through the {:mob_file_result, ...} path.
    internal fun handleScanResult(
        pid: Long,
        value: String?,
        type: String?,
    ) {
        if (value == null) {
            nativeDeliverScanCancelled(pid)
            return
        }
        val safeValue = value.replace("\"", "\\\"")
        val safeType = (type ?: "qr").replace("\"", "\\\"")
        val json = """[{"type":"$safeType","value":"$safeValue"}]"""
        nativeDeliverScanResult(pid, json)
    }
}
