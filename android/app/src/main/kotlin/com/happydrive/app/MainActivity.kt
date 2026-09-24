package com.happydrive.app

import android.os.Handler
import android.os.StatFs
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    /** One conversion at a time: they are heavy, and the uploader queues. */
    private val worker = Executors.newSingleThreadExecutor()

    /** PDF pages are drawn on a thread of their own, as PdfRenderer wants. */
    private val pdfThread = Executors.newSingleThreadExecutor()
    private val pdf = PdfPages()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val main = Handler(Looper.getMainLooper())
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "happy_drive/media")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "transcodeAudio" -> {
                        val input = call.argument<String>("input")
                        val output = call.argument<String>("output")
                        val bits = call.argument<Int>("bitsPerChannel")
                        if (input == null || output == null || bits == null) {
                            result.error("args", "input, output and bitsPerChannel are required", null)
                            return@setMethodCallHandler
                        }
                        worker.execute {
                            val ok = AudioTranscoder.toAac(input, output, bits)
                            main.post { result.success(ok) }
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        val passwords = PasswordVault(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "happy_drive/passwords")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "save" -> {
                        val id = call.argument<String>("id")
                        val password = call.argument<String>("password")
                        if (id == null || password == null) {
                            result.error("args", "id and password are required", null)
                            return@setMethodCallHandler
                        }
                        passwords.save(id, password) { result.success(it) }
                    }
                    "load" -> passwords.load { result.success(it) }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "happy_drive/device")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "storage" -> {
                        val stat = StatFs(filesDir.absolutePath)
                        result.success(mapOf("total" to stat.totalBytes, "free" to stat.availableBytes))
                    }
                    "pdfPageCount", "pdfRenderPage", "pdfClose" -> pdfThread.execute {
                        val reply: Any? = try {
                            when (call.method) {
                                "pdfPageCount" -> pdf.pageCount(call.argument<String>("path")!!)
                                "pdfRenderPage" -> pdf.render(
                                    call.argument<String>("path")!!,
                                    call.argument<Int>("page")!!,
                                    call.argument<Int>("width")!!,
                                )
                                else -> { pdf.close(); null }
                            }
                        } catch (e: Exception) {
                            main.post { result.error("pdf", e.message, null) }
                            return@execute
                        }
                        main.post { result.success(reply) }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        pdfThread.execute { pdf.close() }
        super.onDestroy()
    }
}
