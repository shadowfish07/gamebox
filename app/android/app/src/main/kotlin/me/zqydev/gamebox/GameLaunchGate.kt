package me.zqydev.gamebox

internal class GameLaunchGate {
    private var state = State.IDLE

    val isActive: Boolean
        @Synchronized get() = state != State.IDLE

    @Synchronized
    fun requestLaunch(gameProcessRunning: Boolean): Decision {
        if (gameProcessRunning) {
            state = State.ACTIVE
            return Decision.RESUME_ACTIVE
        }
        if (state == State.STARTING) {
            return Decision.REJECT
        }
        state = State.STARTING
        return Decision.START_NEW
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

    enum class Decision {
        START_NEW,
        RESUME_ACTIVE,
        REJECT,
    }
}
