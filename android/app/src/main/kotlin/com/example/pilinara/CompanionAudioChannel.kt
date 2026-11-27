package com.example.pilinara

import android.content.Context
import android.media.MediaMetadataRetriever
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** Short microphone notes only. All paths are private temporary files chosen here. */
class CompanionAudioChannel(private val context: Context, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "pilicat/companion_audio")
    private val handler = Handler(Looper.getMainLooper())
    private var recorder: MediaRecorder? = null
    private var recording: File? = null
    private var recordingOwner: String? = null
    private var player: MediaPlayer? = null
    private var playingOwner: String? = null
    private var playingResult: MethodChannel.Result? = null
    private val limitRecording = Runnable { finishRecording() }

    init {
        channel.setMethodCallHandler { call, reply ->
            val owner = call.argument<String>("owner")
            if (owner.isNullOrBlank()) {
                reply.error("owner", "伴看会话已结束", null)
                return@setMethodCallHandler
            }
            try {
                when (call.method) {
                    "record" -> {
                        check(recordingOwner == null) { "另一条语音正在录制" }
                        stopPlayback()
                        startRecording(owner)
                        reply.success(null)
                    }
                    "finish" -> {
                        check(owner == recordingOwner) { "录音已中断，请重新录制" }
                        finishRecording()
                        val file = recording
                        try {
                            check(file != null && file.length() in 1L..1048576L) { "未取得录音，请稍后重试" }
                            val metadata = MediaMetadataRetriever()
                            val duration = try {
                                metadata.setDataSource(file.absolutePath)
                                metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toIntOrNull()
                            } finally {
                                metadata.release()
                            }
                            check(duration != null && duration in 1..31000) { "请录制 30 秒以内的语音" }
                            reply.success(mapOf("audio" to file.readBytes(), "duration" to duration))
                        } finally {
                            cancelRecording()
                        }
                    }
                    "cancel" -> {
                        if (owner == recordingOwner) cancelRecording()
                        reply.success(null)
                    }
                    "play", "playSpeech" -> {
                        val speech = call.method == "playSpeech"
                        val data = requireNotNull(call.argument<ByteArray>("audio"))
                        require(data.size in 1..(if (speech) 8388608 else 1048576)) { "语音文件过大" }
                        check(recordingOwner == null) { "正在录音" }
                        stopPlayback()
                        startPlayback(owner, data, reply, if (speech) 300000 else 31000)
                    }
                    "stop" -> {
                        if (owner == playingOwner) stopPlayback()
                        reply.success(null)
                    }
                    else -> reply.notImplemented()
                }
            } catch (e: Exception) {
                reply.error("companion_audio", e.message ?: "伴看音频操作失败", null)
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun startRecording(owner: String) {
        recordingOwner = owner
        try {
            val file = File.createTempFile("companion-record-", ".m4a", context.cacheDir)
            recording = file
            val mic = MediaRecorder()
            recorder = mic
            mic.setAudioSource(MediaRecorder.AudioSource.MIC)
            mic.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            mic.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            mic.setAudioSamplingRate(44100)
            mic.setAudioEncodingBitRate(64000)
            mic.setOutputFile(file.absolutePath)
            mic.prepare()
            mic.start()
            handler.postDelayed(limitRecording, 30000)
        } catch (e: Exception) {
            cancelRecording()
            throw e
        }
    }

    private fun finishRecording() {
        handler.removeCallbacks(limitRecording)
        val mic = recorder ?: return
        recorder = null
        try {
            mic.stop()
        } catch (_: RuntimeException) {
            recording?.delete()
        } finally {
            mic.release()
        }
    }

    private fun cancelRecording() {
        finishRecording()
        recording?.delete()
        recording = null
        recordingOwner = null
    }

    private fun startPlayback(owner: String, bytes: ByteArray, reply: MethodChannel.Result, maxDuration: Int) {
        val file = File.createTempFile("companion-play-", ".m4a", context.cacheDir)
        val media = MediaPlayer()
        try {
            file.writeBytes(bytes)
            file.inputStream().use { media.setDataSource(it.fd) }
            media.setOnPreparedListener {
                if (media === player) {
                    if (media.duration in 1..maxDuration) media.start() else stopPlayback("无效的语音时长")
                }
            }
            media.setOnCompletionListener { if (media === player) stopPlayback() }
            media.setOnErrorListener { _, _, _ ->
                if (media === player) stopPlayback("无法解码这条伴看语音")
                true
            }
            media.prepareAsync()
            player = media
            playingOwner = owner
            playingResult = reply
        } catch (e: Exception) {
            media.release()
            throw e
        } finally {
            file.delete()
        }
    }

    private fun stopPlayback(error: String? = null) {
        val media = player
        player = null
        playingOwner = null
        media?.release()
        val reply = playingResult
        playingResult = null
        if (error == null) reply?.success(null) else reply?.error("play", error, null)
    }

    fun stopAll() {
        cancelRecording()
        stopPlayback()
    }

    fun dispose() {
        stopAll()
        channel.setMethodCallHandler(null)
    }
}
