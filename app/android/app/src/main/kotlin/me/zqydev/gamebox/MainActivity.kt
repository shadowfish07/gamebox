package me.zqydev.gamebox

import android.content.ActivityNotFoundException
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.godotengine.godot.GodotActivity

class MainActivity : FlutterActivity() {
    override fun onResume() {
        super.onResume()
        launchGate.onHostResumed(
            gameProcessRunning = GameProcessLease.isHeld(
                GameProcessLease.lockFile(noBackupFilesDir),
            ),
        )
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            GAME_LAUNCHER_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "launchGame" -> {
                    val parsed = GameLaunchArgs.fromNative(call.arguments)
                    if (parsed !is GameLaunchArgs.ParseResult.Success) {
                        result.error(INVALID_ARGUMENTS_CODE, INVALID_ARGUMENTS_MESSAGE, null)
                        return@setMethodCallHandler
                    }
                    launch(parsed.args, result)
                }

                "launchHostSmoke" -> {
                    if (call.arguments != null) {
                        result.error(INVALID_ARGUMENTS_CODE, INVALID_ARGUMENTS_MESSAGE, null)
                        return@setMethodCallHandler
                    }
                    launch(GameLaunchArgs.hostSmoke(), result)
                }

                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            APP_UPDATER_CHANNEL,
        ).setMethodCallHandler { call, result ->
            if (call.method != "installApk") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val path = call.argument<String>("path")
            if (path.isNullOrBlank()) {
                result.error(INVALID_ARGUMENTS_CODE, INVALID_ARGUMENTS_MESSAGE, null)
                return@setMethodCallHandler
            }
            try {
                val installResult = ApkInstaller(this).install(path)
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
    }

    private fun launch(args: GameLaunchArgs, result: MethodChannel.Result) {
        val gameProcessRunning = GameProcessLease.isHeld(
            GameProcessLease.lockFile(noBackupFilesDir),
        )
        when (launchGate.requestLaunch(gameProcessRunning)) {
            GameLaunchGate.Decision.START_NEW -> startNewGame(args, result)
            GameLaunchGate.Decision.RESUME_ACTIVE -> resumeActiveGame(result)
            GameLaunchGate.Decision.REJECT ->
                result.error(GAME_ALREADY_ACTIVE_CODE, GAME_ALREADY_ACTIVE_MESSAGE, null)
        }
    }

    private fun startNewGame(args: GameLaunchArgs, result: MethodChannel.Result) {
        val intent = Intent(this, GameActivity::class.java).apply {
            putExtra(GodotActivity.EXTRA_COMMAND_LINE_PARAMS, args.commandLineParams)
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP,
            )
        }
        startGameActivity(intent, result, releaseLaunchGateOnFailure = true)
    }

    private fun resumeActiveGame(result: MethodChannel.Result) {
        val intent = Intent(this, GameActivity::class.java).apply {
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP,
            )
        }
        startGameActivity(intent, result, releaseLaunchGateOnFailure = false)
    }

    private fun startGameActivity(
        intent: Intent,
        result: MethodChannel.Result,
        releaseLaunchGateOnFailure: Boolean,
    ) {
        try {
            startActivity(intent)
            result.success(null)
        } catch (_: ActivityNotFoundException) {
            if (releaseLaunchGateOnFailure) launchGate.onLaunchFailed()
            result.error(LAUNCH_FAILED_CODE, LAUNCH_FAILED_MESSAGE, null)
        } catch (_: SecurityException) {
            if (releaseLaunchGateOnFailure) launchGate.onLaunchFailed()
            result.error(LAUNCH_FAILED_CODE, LAUNCH_FAILED_MESSAGE, null)
        }
    }

    private companion object {
        const val GAME_LAUNCHER_CHANNEL = "me.zqydev.gamebox/game_launcher"
        const val APP_UPDATER_CHANNEL = "me.zqydev.gamebox/app_updater"
        const val INVALID_ARGUMENTS_CODE = "invalid_arguments"
        const val INVALID_ARGUMENTS_MESSAGE = "Invalid game launch arguments."
        const val GAME_ALREADY_ACTIVE_CODE = "game_already_active"
        const val GAME_ALREADY_ACTIVE_MESSAGE = "A game is already active."
        const val LAUNCH_FAILED_CODE = "launch_failed"
        const val LAUNCH_FAILED_MESSAGE = "Unable to launch game."
        const val INVALID_APK_CODE = "invalid_apk"
        const val INVALID_APK_MESSAGE = "Invalid or incompatible update package."
        const val INSTALLER_UNAVAILABLE_CODE = "installer_unavailable"
        const val INSTALLER_UNAVAILABLE_MESSAGE = "Unable to open package installer."
        val launchGate = GameLaunchGate()
    }
}
