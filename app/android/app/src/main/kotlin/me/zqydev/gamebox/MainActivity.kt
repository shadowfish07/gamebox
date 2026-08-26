package me.zqydev.gamebox

import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import org.godotengine.godot.GodotActivity

class MainActivity : FlutterActivity() {
    private var appProfileChannel: AppProfileChannel? = null
    private var lanHostChannel: LanHostChannel? = null
    private var lanHostWorker: ExecutorService? = null
    private var localNetworkPermissionRequested = false
    private lateinit var resultStore: AtomicResultStore
    private lateinit var pendingResultStore: PendingGameResultStore

    override fun onResume() {
        super.onResume()
        launchGate.onHostResumed(
            gameProcessRunning = GameProcessLease.isHeld(
                GameProcessLease.lockFile(noBackupFilesDir),
            ),
        )
        recoverLanHostIfNeeded()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        resultStore = AtomicResultStore(java.io.File(filesDir, "game_results"))
        pendingResultStore = PendingGameResultStore(java.io.File(filesDir, "pending_game_results"))
        appProfileChannel = AppProfileChannel(
            flutterEngine.dartExecutor.binaryMessenger,
        )
        val worker = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "lan-host-command")
        }
        lanHostWorker = worker
        lanHostChannel = LanHostChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            LanHostService.serviceReady,
            { startLanHostCommand() },
            { LanSecretStore(this).hasStoredBlob() },
            worker,
            { runnable -> runOnUiThread(runnable) },
        )
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
            GAME_RESULTS_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "listCommitted" -> if (call.arguments == null) {
                    result.success(resultStore.list().map(StoredGameResult::toMap))
                } else {
                    result.error(INVALID_RESULT_CODE, INVALID_RESULT_MESSAGE, null)
                }
                "listPending" -> if (call.arguments == null) {
                    result.success(pendingResultStore.list().map(PendingGameResult::toMap))
                } else {
                    result.error(INVALID_RESULT_CODE, INVALID_RESULT_MESSAGE, null)
                }
                "persistRecovered" -> {
                    if (!hasExactArguments(call.arguments, setOf("result"))) {
                        result.error(INVALID_RESULT_CODE, INVALID_RESULT_MESSAGE, null)
                        return@setMethodCallHandler
                    }
                    val raw = call.argument<String>("result")
                    val validated = raw?.let(GameResultValidator::validate)
                    if (validated == null || pendingResultStore.list().none { it.matchId == validated.matchId }) {
                        result.error(INVALID_RESULT_CODE, INVALID_RESULT_MESSAGE, null)
                    } else if (!resultStore.persist(raw)) {
                        result.error(RESULT_STORAGE_CODE, RESULT_STORAGE_MESSAGE, null)
                    } else {
                        result.success(resultStore.get(validated.matchId)?.sha256)
                    }
                }
                "completePending" -> {
                    if (!hasExactArguments(call.arguments, setOf("matchId", "expectedSha256"))) {
                        result.error(INVALID_RESULT_CODE, INVALID_RESULT_MESSAGE, null)
                        return@setMethodCallHandler
                    }
                    val matchId = call.argument<String>("matchId")
                    val expectedSha256 = call.argument<String>("expectedSha256")
                    val stored = matchId?.let(resultStore::get)
                    if (stored == null || expectedSha256 == null || stored.sha256 != expectedSha256) {
                        result.error(INVALID_RESULT_CODE, INVALID_RESULT_MESSAGE, null)
                    } else if (!pendingResultStore.remove(matchId)) {
                        result.error(RESULT_STORAGE_CODE, RESULT_STORAGE_MESSAGE, null)
                    } else {
                        result.success(null)
                    }
                }
                "quarantine" -> {
                    if (!hasExactArguments(call.arguments, setOf("matchId"))) {
                        result.error(INVALID_RESULT_CODE, INVALID_RESULT_MESSAGE, null)
                        return@setMethodCallHandler
                    }
                    val matchId = call.argument<String>("matchId")
                    result.success(matchId != null && pendingResultStore.quarantine(matchId))
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        appProfileChannel?.close()
        appProfileChannel = null
        lanHostChannel?.close()
        lanHostChannel = null
        lanHostWorker?.shutdownNow()
        lanHostWorker = null
        super.onDestroy()
    }

    private fun recoverLanHostIfNeeded() {
        val worker = lanHostWorker ?: return
        worker.execute {
            val hasRecovery = try {
                LanSecretStore(this).hasStoredBlob()
            } catch (_: RuntimeException) {
                false
            }
            if (hasRecovery) {
                runOnUiThread {
                    if (!isFinishing && !isDestroyed) {
                        startLanHostRecoveryIfPermitted()
                    }
                }
            }
        }
    }

    private fun startLanHostCommand() {
        if (!ensureLocalNetworkPermission()) {
            throw IllegalStateException("Local-network permission is required")
        }
        ContextCompat.startForegroundService(this, LanHostService.commandIntent(this))
    }

    private fun startLanHostRecoveryIfPermitted() {
        if (!ensureLocalNetworkPermission()) return
        LanHostService.serviceReady.prepareStart()
        ContextCompat.startForegroundService(this, LanHostService.recoverIntent(this))
    }

    private fun ensureLocalNetworkPermission(): Boolean {
        val permission = LanLocalNetworkPermissionPolicy.permissionToRequest(
            applicationInfo.targetSdkVersion,
            ContextCompat.checkSelfPermission(
                this,
                LanLocalNetworkPermissionPolicy.ACCESS_LOCAL_NETWORK,
            ) == PackageManager.PERMISSION_GRANTED,
        ) ?: return true
        if (!localNetworkPermissionRequested) {
            localNetworkPermissionRequested = true
            requestPermissions(arrayOf(permission), LOCAL_NETWORK_PERMISSION_REQUEST)
        }
        return false
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
        if (args.requiresResultTracking && !pendingResultStore.persist(args)) {
            launchGate.onLaunchFailed()
            result.error(RESULT_TRACKING_CODE, RESULT_TRACKING_MESSAGE, null)
            return
        }
        val intent = Intent(this, GameActivity::class.java).apply {
            putExtra(GodotActivity.EXTRA_COMMAND_LINE_PARAMS, args.commandLineParams)
            args.privateResumeToken?.let { resumeToken ->
                putExtra(PrivateCommandLineArgs.PRIVATE_RESUME_EXTRA, arrayOf(resumeToken))
            }
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
        fun hasExactArguments(arguments: Any?, expected: Set<String>): Boolean =
            arguments is Map<*, *> && arguments.keys == expected

        const val LOCAL_NETWORK_PERMISSION_REQUEST = 0x4c41
        const val GAME_LAUNCHER_CHANNEL = "me.zqydev.gamebox/game_launcher"
        const val GAME_RESULTS_CHANNEL = "me.zqydev.gamebox/game_results"
        const val INVALID_ARGUMENTS_CODE = "invalid_arguments"
        const val INVALID_ARGUMENTS_MESSAGE = "Invalid game launch arguments."
        const val GAME_ALREADY_ACTIVE_CODE = "game_already_active"
        const val GAME_ALREADY_ACTIVE_MESSAGE = "A game is already active."
        const val LAUNCH_FAILED_CODE = "launch_failed"
        const val LAUNCH_FAILED_MESSAGE = "Unable to launch game."
        const val RESULT_TRACKING_CODE = "result_tracking_unavailable"
        const val RESULT_TRACKING_MESSAGE = "Unable to track the game result."
        const val INVALID_RESULT_CODE = "invalid_result"
        const val INVALID_RESULT_MESSAGE = "Invalid authoritative game result."
        const val RESULT_STORAGE_CODE = "result_storage_unavailable"
        const val RESULT_STORAGE_MESSAGE = "Unable to store the game result."
        val launchGate = GameLaunchGate()
    }
}
