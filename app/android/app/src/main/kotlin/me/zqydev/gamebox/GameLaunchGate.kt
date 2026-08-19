package me.zqydev.gamebox

internal class GameLaunchGate {
    private var state = State.IDLE

    val isActive: Boolean
        @Synchronized get() = state != State.IDLE

    @Synchronized
    fun tryBeginLaunch(gameProcessRunning: Boolean): Boolean {
        if (gameProcessRunning) {
            state = State.ACTIVE
            return false
        }
        if (state == State.STARTING) {
            return false
        }
        state = State.STARTING
        return true
    }

    @Synchronized
    fun onLaunchFailed() {
        state = State.IDLE
    }

    @Synchronized
    fun onHostResumed(gameProcessRunning: Boolean) {
        state = if (gameProcessRunning) State.ACTIVE else State.IDLE
    }

    private enum class State {
        IDLE,
        STARTING,
        ACTIVE,
    }
}
