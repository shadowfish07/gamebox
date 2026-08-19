package me.zqydev.gamebox

import android.app.ActivityManager
import android.content.ActivityNotFoundException
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.godotengine.godot.GodotActivity

class MainActivity : FlutterActivity() {
    override fun onResume() {
        super.onResume()
        launchGate.onHostResumed(gameProcessRunning = isGameProcessRunning())
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
    }

    private fun launch(args: GameLaunchArgs, result: MethodChannel.Result) {
        if (!launchGate.tryBeginLaunch()) {
            result.error(GAME_ALREADY_ACTIVE_CODE, GAME_ALREADY_ACTIVE_MESSAGE, null)
            return
        }
        val intent = Intent(this, GameActivity::class.java).apply {
            putExtra(GodotActivity.EXTRA_COMMAND_LINE_PARAMS, args.commandLineParams)
            addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        try {
            startActivity(intent)
            result.success(null)
        } catch (_: ActivityNotFoundException) {
            launchGate.onLaunchFailed()
            result.error(LAUNCH_FAILED_CODE, LAUNCH_FAILED_MESSAGE, null)
        } catch (_: SecurityException) {
            launchGate.onLaunchFailed()
            result.error(LAUNCH_FAILED_CODE, LAUNCH_FAILED_MESSAGE, null)
        }
    }

    private fun isGameProcessRunning(): Boolean {
        val activityManager = getSystemService(ActivityManager::class.java)
        val gameProcessName = "$packageName:game"
        return activityManager.runningAppProcesses.orEmpty().any { process ->
            process.processName == gameProcessName
        }
    }

    private companion object {
        const val GAME_LAUNCHER_CHANNEL = "me.zqydev.gamebox/game_launcher"
        const val INVALID_ARGUMENTS_CODE = "invalid_arguments"
        const val INVALID_ARGUMENTS_MESSAGE = "Invalid game launch arguments."
        const val GAME_ALREADY_ACTIVE_CODE = "game_already_active"
        const val GAME_ALREADY_ACTIVE_MESSAGE = "A game is already active."
        const val LAUNCH_FAILED_CODE = "launch_failed"
        const val LAUNCH_FAILED_MESSAGE = "Unable to launch game."
        val launchGate = GameLaunchGate()
    }
}
