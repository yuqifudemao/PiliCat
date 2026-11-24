package com.example.pilinara

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
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

internal fun readFrameCaption(source: MediaMetadataRetriever, recognizer: TextRecognizer, ms: Long): String {
    val mode = MediaMetadataRetriever.OPTION_CLOSEST
    val frame = if (Build.VERSION.SDK_INT >= 27) {
        source.getScaledFrameAtTime(ms * 1000, mode, 1280, 1280)
    } else {
        source.getFrameAtTime(ms * 1000, mode)
    } ?: return ""

    try {
        val top = frame.height / 2
        val crop = Bitmap.createBitmap(frame, 0, top, frame.width, frame.height - top)
        try {
            val text = Tasks.await(recognizer.process(InputImage.fromBitmap(crop, 0)))
            return text.textBlocks.flatMap { block -> block.lines }
                .joinToString(" ") { line -> line.text.trim() }.trim()
        } finally {
            if (crop !== frame) crop.recycle()
        }
    } finally {
        frame.recycle()
    }
}

internal class FrameCaptionChannel(messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "PiliCat/frameCaptions")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var activeId: Long? = null
    @Volatile private var detached = false

    // Only the worker thread touches the decoder and the recognizer.
    private var sessionId: Long? = null
    private var source: MediaMetadataRetriever? = null
    private var recognizer: TextRecognizer? = null

    init { channel.setMethodCallHandler(::handle) }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<Number>("id")?.toLong() ?: return result.error("id", "缺少识别任务", null)
        if (call.method == "close") {
            if (activeId == id) activeId = null
            worker.execute { if (sessionId == id) release() }
            result.success(null)
            return
        }
        if (call.method == "open") activeId = id
        if (call.method != "open" && call.method != "frame") return result.notImplemented()
        worker.execute {
            try {
                check(activeId == id)
                val value: Any = if (call.method == "open") {
                    open(id, call.argument<List<String>>("urls").orEmpty(), call.argument<Map<String, String>>("headers").orEmpty())
                } else {
                    check(sessionId == id)
                    readFrameCaption(checkNotNull(source), checkNotNull(recognizer),
                        call.argument<Number>("ms")!!.toLong())
                }
                main.post { if (!detached) result.success(value) }
            } catch (_: Exception) {
                main.post {
                    if (!detached) result.error("read", if (activeId == id)
                        "无法读取该视频的画面，请重试或仅使用视频简介" else "识别已停止", null)
                }
            }
        }
    }

    private fun open(id: Long, urls: List<String>, headers: Map<String, String>): Long {
        release()
        for (url in urls) {
            check(activeId == id)
            val uri = Uri.parse(url)
            if (uri.scheme != "https" || uri.host.isNullOrEmpty()) continue
            val reader = MediaMetadataRetriever()
            try {
                reader.setDataSource(url, headers)
                val duration = reader.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()
                if (duration == null || duration <= 0) continue
                val probe = if (Build.VERSION.SDK_INT >= 27) {
                    reader.getScaledFrameAtTime(0L, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, 64, 64)
                } else {
                    reader.getFrameAtTime(0L, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                } ?: continue
                probe.recycle()
                check(activeId == id)
                recognizer = TextRecognition.getClient(ChineseTextRecognizerOptions.Builder().build())
                source = reader
                sessionId = id
                return duration
            } catch (_: Exception) {
                // Try another URL issued for the same video.
            } finally {
                if (source !== reader) runCatching { reader.release() }
            }
        }
        throw IllegalStateException("Could not decode the current video")
    }

    private fun release() {
        runCatching { source?.release() }
        recognizer?.close()
        source = null
        recognizer = null
        sessionId = null
    }

    fun dispose() {
        detached = true
        activeId = null
        channel.setMethodCallHandler(null)
        worker.execute { release() }
        worker.shutdown()
    }
}
