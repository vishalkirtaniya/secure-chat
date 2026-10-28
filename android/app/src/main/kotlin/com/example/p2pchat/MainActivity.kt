package com.example.p2pchat // keep the package line your existing MainActivity.kt already has

import android.app.PictureInPictureParams
import android.content.res.Configuration
import android.os.Build
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var inCall = false

    private fun params(): PictureInPictureParams {
        val b = PictureInPictureParams.Builder().setAspectRatio(Rational(9, 16))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) b.setAutoEnterEnabled(inCall)
        return b.build()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pip")
        channel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "call" -> {
                    inCall = (call.arguments as? Boolean) ?: false
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) setPictureInPictureParams(params())
                    result.success(null)
                }
                "enter" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) enterPictureInPictureMode(params())
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    // Android 8-11: enter PiP when the user presses Home during a video call (Android 12+ does it automatically)
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (inCall && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && Build.VERSION.SDK_INT < Build.VERSION_CODES.S)
            enterPictureInPictureMode(params())
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        channel?.invokeMethod("changed", isInPictureInPictureMode)
    }
}