// mob_scanner plugin — full-screen barcode/QR scanner activity.
//
// Copied faithfully from the mob_new template
// (priv/templates/mob.new/android/app/src/main/java/MobScannerActivity.kt.eex),
// repackaged from the generated app package into the plugin-owned
// io.mob.scanner. Launched by MobScannerBridge via an explicit Intent;
// returns the scanned value/type as scan_value / scan_type Intent extras
// (RESULT_OK) or RESULT_CANCELED.
//
// NOTE: as an Activity this class still needs an AndroidManifest
// declaration the plugin manifest can't contribute — see host_requirements
// in priv/mob_plugin.exs:
//   <activity android:name="io.mob.scanner.MobScannerActivity"
//       android:exported="false"
//       android:theme="@style/Theme.AppCompat.NoActionBar" />
// The AppCompat theme override is required: this extends AppCompatActivity
// (CameraX + ML Kit need it), which throws IllegalStateException at
// setContentView when the activity's theme isn't AppCompat-derived
// (mob_new AndroidManifest.xml.eex:78-87).
package io.mob.scanner

import android.app.Activity
import android.content.Intent
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
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import java.util.concurrent.Executors

/**
 * Full-screen barcode/QR scanner activity.
 *
 * Uses CameraX + ML Kit BarcodeScanning.
 *
 * Required build.gradle dependencies (declared in this plugin's
 * manifest gradle_deps):
 *   implementation 'androidx.appcompat:appcompat:1.6.1'
 *   implementation 'androidx.camera:camera-camera2:1.3.4'
 *   implementation 'androidx.camera:camera-lifecycle:1.3.4'
 *   implementation 'androidx.camera:camera-view:1.3.4'
 *   implementation 'com.google.mlkit:barcode-scanning:17.2.0'
 *
 * Required AndroidManifest.xml entry (host_requirements):
 *   <activity android:name="io.mob.scanner.MobScannerActivity"
 *       android:exported="false"
 *       android:theme="@style/Theme.AppCompat.NoActionBar" />
 */
class MobScannerActivity : AppCompatActivity() {
    private val executor = Executors.newSingleThreadExecutor()
    private var scanHandled = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

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
                    val scanner = BarcodeScanning.getClient()
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
                                            val type = when (barcodes.first().format) {
                                                Barcode.FORMAT_QR_CODE -> "qr"
                                                Barcode.FORMAT_EAN_13 -> "ean13"
                                                Barcode.FORMAT_EAN_8 -> "ean8"
                                                Barcode.FORMAT_CODE_128 -> "code128"
                                                Barcode.FORMAT_CODE_39 -> "code39"
                                                Barcode.FORMAT_PDF417 -> "pdf417"
                                                Barcode.FORMAT_AZTEC -> "aztec"
                                                Barcode.FORMAT_DATA_MATRIX -> "data_matrix"
                                                else -> "qr"
                                            }
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
