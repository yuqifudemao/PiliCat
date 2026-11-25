package com.example.pilinara

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import android.content.Context
import com.googlecode.tesseract.android.TessBaseAPI
import java.io.File
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/** Receives only the subtitle band of a decoded frame. Networking and seeking
 * are handled by the same mpv library as the foreground player. */
internal class FrameCaptionChannel(private val context: Context, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "PiliCat/frameCaptions")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var activeId: Long? = null // Main thread only.
    private var recognizer: TessBaseAPI? = null // Worker thread only.
    private var attached = true

    init { channel.setMethodCallHandler(::handle) }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<Number>("id")?.toLong()
            ?: return result.error("session", "缺少字幕识别任务", null)
        when (call.method) {
            "start" -> {
                activeId = id
                result.success(null)
            }
            "close" -> {
                if (activeId == id) {
                    activeId = null
                    worker.execute { release() }
                }
                result.success(null)
            }
            "recognize" -> {
                if (activeId != id) return result.error("cancelled", "字幕识别已停止", null)
                val bytes = call.argument<ByteArray>("png")
                    ?: return result.error("image", "播放器没有输出字幕图像", null)
                worker.execute {
                    var image: Bitmap? = null
                    try {
                        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                        if (bitmap == null) {
                            main.post { if (attached) result.error("image", "无法解码播放器输出的字幕图像", null) }
                            return@execute
                        }
                        image = bitmap
                        val reader = recognizer ?: createReader().also { recognizer = it }
                        reader.setImage(bitmap)
                        val text = reader.getUTF8Text().orEmpty().trim()
                        reader.clear()
                        main.post {
                            if (attached) {
                                if (activeId == id) result.success(text)
                                else result.error("cancelled", "字幕识别已停止", null)
                            }
                        }
                    } catch (_: Exception) {
                        main.post { if (attached) result.error("ocr", "手机上的文字识别模型未能处理这帧画面", null) }
                    } finally {
                        image?.recycle()
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun createReader(): TessBaseAPI {
        val root = File(context.filesDir, "caption-ocr-v1")
        val model = File(root, "tessdata/chi_sim.traineddata")
        if (!model.exists()) {
            model.parentFile!!.mkdirs()
            val tmp = File.createTempFile("model", ".tmp", model.parentFile)
            try {
                context.assets.open("chi_sim.traineddata").use { input ->
                    tmp.outputStream().use { output -> input.copyTo(output) }
                }
                check(tmp.renameTo(model) || model.exists())
            } finally {
                tmp.delete()
            }
        }
        val reader = TessBaseAPI()
        if (!reader.init(root.absolutePath, "chi_sim")) {
            reader.recycle()
            error("OCR initialization failed")
        }
        reader.setPageSegMode(TessBaseAPI.PageSegMode.PSM_SPARSE_TEXT)
        return reader
    }

    private fun release() {
        recognizer?.recycle()
        recognizer = null
    }

    fun dispose() {
        attached = false
        activeId = null
        channel.setMethodCallHandler(null)
        worker.execute { release() }
        worker.shutdown()
    }
}
