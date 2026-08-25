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
        const val INVALID_ARGUMENTS_CODE = "invalid_arguments"
        const val INVALID_ARGUMENTS_MESSAGE = "Invalid game launch arguments."
        const val GAME_ALREADY_ACTIVE_CODE = "game_already_active"
        const val GAME_ALREADY_ACTIVE_MESSAGE = "A game is already active."
        const val LAUNCH_FAILED_CODE = "launch_failed"
        const val LAUNCH_FAILED_MESSAGE = "Unable to launch game."
        val launchGate = GameLaunchGate()
    }
}
