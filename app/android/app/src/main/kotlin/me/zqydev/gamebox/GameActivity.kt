package me.zqydev.gamebox

import android.content.Intent
import android.os.Bundle
import android.util.Log
import org.godotengine.godot.GodotActivity

class GameActivity : GodotActivity() {
    private val privateCommandLineArgs = PrivateCommandLineArgs()
    private var gameProcessLease: GameProcessLease? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        privateCommandLineArgs.consumeFrom(intent)
        gameProcessLease = GameProcessLease.acquire(
            GameProcessLease.lockFile(noBackupFilesDir),
        )
        super.onCreate(savedInstanceState)
    }

    override fun getCommandLine(): MutableList<String> =
        privateCommandLineArgs.combineWith(super.getCommandLine())

    override fun onNewIntent(intent: Intent) {
        privateCommandLineArgs.discardFrom(intent)
        super.onNewIntent(intent)
    }

    override fun onNewGodotInstanceRequested(args: Array<String>): Int {
        args.fill("")
        return NEW_INSTANCE_UNSUPPORTED
    }

    override fun onGodotMainLoopStarted() {
        Log.i(LOG_TAG, MAIN_LOOP_STARTED_MARKER)
        privateCommandLineArgs.clear()
    }

    override fun onDestroy() {
        privateCommandLineArgs.clear()
        try {
            super.onDestroy()
        } finally {
            gameProcessLease?.close()
            gameProcessLease = null
        }
    }

    private companion object {
        const val LOG_TAG = "GameboxGodot"
        const val MAIN_LOOP_STARTED_MARKER = "GAMEBOX_GODOT_MAIN_LOOP_STARTED"
        const val NEW_INSTANCE_UNSUPPORTED = -1
    }
}
