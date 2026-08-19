package me.zqydev.gamebox

internal class GameLaunchGate {
    private var launchActive = false

    val isActive: Boolean
        @Synchronized get() = launchActive

    @Synchronized
    fun tryBeginLaunch(): Boolean {
        if (launchActive) {
            return false
        }
        launchActive = true
        return true
    }

    @Synchronized
    fun onLaunchFailed() {
        launchActive = false
    }

    @Synchronized
    fun onHostResumed(gameProcessRunning: Boolean) {
        if (!gameProcessRunning) {
            launchActive = false
        }
    }
}
