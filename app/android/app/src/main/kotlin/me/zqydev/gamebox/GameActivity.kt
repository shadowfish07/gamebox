package me.zqydev.gamebox

import android.content.Intent
import android.os.Bundle
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
        const val NEW_INSTANCE_UNSUPPORTED = -1
    }
}
