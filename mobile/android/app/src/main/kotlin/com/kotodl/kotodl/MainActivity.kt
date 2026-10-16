package com.kotodl.kotodl

import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "kotodl/native").setMethodCallHandler { call, result ->
            when (call.method) {
                "sdkInt" -> result.success(Build.VERSION.SDK_INT)
                "storageRoot" -> result.success(Environment.getExternalStorageDirectory().absolutePath)
                "remux" -> {
                    val src = call.argument<String>("src")!!
                    val dest = call.argument<String>("dest")!!
                    thread(name = "remux") {
                        try {
                            Remuxer.remux(src, dest)
                            main.post { result.success(dest) }
                        } catch (e: Exception) {
                            main.post { result.error("remux", e.message ?: e.javaClass.simpleName, null) }
                        }
                    }
                }
                "scan" -> {
                    MediaScannerConnection.scanFile(applicationContext, arrayOf(call.argument<String>("path")!!), null, null)
                    result.success(null)
                }
                "serviceStart" -> {
                    DownloadService.start(this, call.argument<String>("text") ?: "")
                    result.success(null)
                }
                "serviceUpdate" -> {
                    DownloadService.update(this, call.argument<String>("text") ?: "", call.argument<Int>("progress"))
                    result.success(null)
                }
                "serviceStop" -> {
                    DownloadService.stop(this, call.argument<String>("text"))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
