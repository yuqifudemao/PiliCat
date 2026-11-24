package com.example.pilinara

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/** Receives only the subtitle band of a decoded frame. Networking and seeking
 * are handled by the same mpv library as the foreground player. */
internal class FrameCaptionChannel(messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "PiliCat/frameCaptions")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var activeId: Long? = null // Main thread only.
    private var recognizer: TextRecognizer? = null // Worker thread only.
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
                        val reader = recognizer ?: TextRecognition.getClient(
                            ChineseTextRecognizerOptions.Builder().build()
                        ).also { recognizer = it }
                        val text = Tasks.await(reader.process(InputImage.fromBitmap(bitmap, 0)))
                            .textBlocks.flatMap { it.lines }.joinToString(" ") { it.text.trim() }.trim()
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

    private fun release() {
        recognizer?.close()
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
