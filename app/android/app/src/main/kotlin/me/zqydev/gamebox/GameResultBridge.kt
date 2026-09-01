package me.zqydev.gamebox

import android.content.pm.ApplicationInfo
import android.util.Log
import java.io.File
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.UsedByGodot

class GameResultBridge(
    godot: Godot,
    private val committed: AtomicResultStore,
    private val pending: PendingGameResultStore,
) : GodotPlugin(godot) {
    private val rejectedDiagnostic = File(godot.context.cacheDir, REJECTED_DIAGNOSTIC_FILE)
    private val debuggable = godot.context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0

    override fun getPluginName(): String = PLUGIN_NAME

    @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
    override fun getPluginMethods(): List<String> = listOf(PERSIST_METHOD)

    @UsedByGodot
    fun persistAuthoritativeResult(raw: String): String {
        val validated = GameResultValidator.validate(raw)
        if (validated == null) {
            Log.w(LOG_TAG, "GAMEBOX_RESULT_PERSIST status=invalid bytes=${raw.toByteArray().size}")
            if (debuggable) runCatching { rejectedDiagnostic.writeText(raw, Charsets.UTF_8) }
            return REJECTED_RESULT
        }
        if (pending.list().none { it.matchId == validated.matchId }) {
            Log.w(LOG_TAG, "GAMEBOX_RESULT_PERSIST status=pending_missing match=${validated.matchId}")
            return REJECTED_RESULT
        }
        val persisted = committed.persist(raw)
        Log.i(LOG_TAG, "GAMEBOX_RESULT_PERSIST status=${if (persisted) "persisted" else "storage_rejected"} match=${validated.matchId}")
        if (persisted && debuggable) rejectedDiagnostic.delete()
        return if (persisted) PERSISTED_RESULT else REJECTED_RESULT
    }

    companion object {
        const val PLUGIN_NAME = "GameboxResultBridge"
        const val REJECTED_DIAGNOSTIC_FILE = "gamebox-rejected-result.json"
        private const val PERSIST_METHOD = "persistAuthoritativeResult"
        private const val PERSISTED_RESULT = "persisted"
        private const val REJECTED_RESULT = "rejected"
        private const val LOG_TAG = "GameboxResultBridge"
    }
}
