package me.zqydev.gamebox.release_smoke

import android.content.Intent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ReleaseGodotSmokeTest {
    @Test
    fun launchPackagedGodotHostSmoke() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val intent = Intent().apply {
            setClassName(APP_PACKAGE, GAME_ACTIVITY)
            putExtra(
                GODOT_COMMAND_LINE_PARAMS_EXTRA,
                arrayOf("--", "--host-smoke", "--auto-exit-ms", "800"),
            )
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }

        context.startActivity(intent)

        // The host smoke exits itself after 800 ms. Keep the target instrumentation
        // alive long enough for the shell-side gate to observe initialization, clean
        // termination, and any release-only native crash in logcat.
        Thread.sleep(5_000)
    }

    private companion object {
        const val APP_PACKAGE = "me.zqydev.gamebox"
        const val GAME_ACTIVITY = "$APP_PACKAGE.GameActivity"
        // GodotActivity.EXTRA_COMMAND_LINE_PARAMS. Keeping the helper independent
        // from the Godot AAR avoids packaging a duplicate runtime into the test APK;
        // the runtime smoke itself detects any future contract change.
        const val GODOT_COMMAND_LINE_PARAMS_EXTRA = "command_line_params"
    }
}
