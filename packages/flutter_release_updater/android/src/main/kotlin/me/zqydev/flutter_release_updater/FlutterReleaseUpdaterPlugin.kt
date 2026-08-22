package me.zqydev.flutter_release_updater

import android.app.Activity
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class FlutterReleaseUpdaterPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware {
    private lateinit var channel: MethodChannel
    private var activity: Activity? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "installApk") {
            result.notImplemented()
            return
        }
        val path = call.argument<String>("path")
        if (path.isNullOrBlank()) {
            result.error(INVALID_ARGUMENTS_CODE, INVALID_ARGUMENTS_MESSAGE, null)
            return
        }
        val currentActivity = activity
        if (currentActivity == null) {
            result.error(NO_ACTIVITY_CODE, NO_ACTIVITY_MESSAGE, null)
            return
        }
        try {
            val installResult = ApkInstaller(currentActivity).install(path)
            result.success(
                when (installResult) {
                    ApkInstallResult.STARTED -> "started"
                    ApkInstallResult.PERMISSION_REQUIRED -> "permission_required"
                },
            )
        } catch (_: IllegalArgumentException) {
            result.error(INVALID_APK_CODE, INVALID_APK_MESSAGE, null)
        } catch (_: IllegalStateException) {
            result.error(INSTALLER_UNAVAILABLE_CODE, INSTALLER_UNAVAILABLE_MESSAGE, null)
        }
    }

    private companion object {
        const val CHANNEL_NAME = "me.zqydev.flutter_release_updater/app_updater"
        const val INVALID_ARGUMENTS_CODE = "invalid_arguments"
        const val INVALID_ARGUMENTS_MESSAGE = "Invalid APK path."
        const val NO_ACTIVITY_CODE = "no_activity"
        const val NO_ACTIVITY_MESSAGE = "No foreground Android activity."
        const val INVALID_APK_CODE = "invalid_apk"
        const val INVALID_APK_MESSAGE = "Invalid or incompatible update package."
        const val INSTALLER_UNAVAILABLE_CODE = "installer_unavailable"
        const val INSTALLER_UNAVAILABLE_MESSAGE = "Unable to open package installer."
    }
}
