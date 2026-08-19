package me.zqydev.gamebox

import android.content.Intent
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.godotengine.godot.GodotActivity
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PrivateCommandLineArgsTest {
    @Test
    fun consumesAndClonesSecretArgsBeforeGodotSeesIntent() {
        val source = arrayOf("--", "--launch-ticket", "canary-secret")
        val intent = Intent().putExtra(GodotActivity.EXTRA_COMMAND_LINE_PARAMS, source)
        val environment = FakePrivateTicketEnvironment()
        val privateArgs = PrivateCommandLineArgs(environment)

        privateArgs.consumeFrom(intent)
        source[2] = "mutated"

        assertNull(intent.getStringArrayExtra(GodotActivity.EXTRA_COMMAND_LINE_PARAMS))
        assertArrayEquals(
            arrayOf(
                "project.godot",
                "--",
                "--launch-ticket",
                PrivateCommandLineArgs.PRIVATE_TICKET_PLACEHOLDER,
            ),
            privateArgs.combineWith(listOf("project.godot")).toTypedArray(),
        )
        assertEquals("canary-secret", environment.value)
        val mutatedRead = privateArgs.combineWith(emptyList())
        mutatedRead[2] = "changed"
        assertArrayEquals(
            arrayOf(
                "--",
                "--launch-ticket",
                PrivateCommandLineArgs.PRIVATE_TICKET_PLACEHOLDER,
            ),
            privateArgs.combineWith(emptyList()).toTypedArray(),
        )

        privateArgs.clear()
        assertFalse(privateArgs.combineWith(emptyList()).isNotEmpty())
        assertNull(environment.value)
    }

    @Test
    fun discardsSecretArgsFromReplacementIntent() {
        val intent = Intent().putExtra(
            GodotActivity.EXTRA_COMMAND_LINE_PARAMS,
            arrayOf("--launch-ticket", "replacement-secret"),
        )
        val privateArgs = PrivateCommandLineArgs()

        privateArgs.discardFrom(intent)

        assertNull(intent.getStringArrayExtra(GodotActivity.EXTRA_COMMAND_LINE_PARAMS))
        assertFalse(privateArgs.combineWith(emptyList()).isNotEmpty())
    }

    private class FakePrivateTicketEnvironment : PrivateTicketEnvironment {
        var value: String? = null

        override fun replace(value: String): Boolean {
            this.value = value
            return true
        }

        override fun clear() {
            value = null
        }
    }
}
