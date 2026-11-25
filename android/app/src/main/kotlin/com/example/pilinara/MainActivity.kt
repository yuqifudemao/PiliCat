package com.example.pilinara

import android.content.res.Configuration
import android.net.TrafficStats
import android.os.Build
import android.os.Bundle
import android.os.Process
import android.view.WindowManager.LayoutParams
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private var frameCaptions: FrameCaptionChannel? = null
    private lateinit var methodChannel: MethodChannel

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        frameCaptions = FrameCaptionChannel(applicationContext, flutterEngine.dartExecutor.binaryMessenger)

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "PiliNara")
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getAppRxBytes" -> {
                    val bytes = TrafficStats.getUidRxBytes(Process.myUid())
                    result.success(bytes.takeIf { it >= 0 })
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        frameCaptions?.dispose()
        frameCaptions = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (AndroidHelper.isFoldable) {
            AndroidHelper.ToDart.onConfigurationChanged?.run()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode =
                LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        AndroidHelper.ToDart.onUserLeaveHint?.run()
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration?
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        AndroidHelper.isPipMode = isInPictureInPictureMode
        methodChannel.invokeMethod("onPipChanged", isInPictureInPictureMode)
    }
}
