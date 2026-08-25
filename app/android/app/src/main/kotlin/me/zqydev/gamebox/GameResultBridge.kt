package me.zqydev.gamebox

import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.UsedByGodot

class GameResultBridge(
    godot: Godot,
    private val committed: AtomicResultStore,
    private val pending: PendingGameResultStore,
) : GodotPlugin(godot) {
    override fun getPluginName(): String = PLUGIN_NAME

    @UsedByGodot
    fun persistAuthoritativeResult(raw: String): Boolean {
        val validated = GameResultValidator.validate(raw) ?: return false
        if (pending.list().none { it.matchId == validated.matchId }) return false
        return committed.persist(raw)
    }

    companion object {
        const val PLUGIN_NAME = "GameboxResultBridge"
    }
}
