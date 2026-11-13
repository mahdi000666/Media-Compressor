package dev.local.media_compressor

import io.flutter.embedding.android.FlutterActivity
import android.content.Intent
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var encoder: AndroidFfmpegBridge? = null
    private var files: AndroidMediaBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        encoder = AndroidFfmpegBridge(flutterEngine.dartExecutor.binaryMessenger)
        files = AndroidMediaBridge(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (files?.onActivityResult(requestCode, resultCode, data) != true) {
            super.onActivityResult(requestCode, resultCode, data)
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        encoder?.close()
        encoder = null
        files?.close()
        files = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
