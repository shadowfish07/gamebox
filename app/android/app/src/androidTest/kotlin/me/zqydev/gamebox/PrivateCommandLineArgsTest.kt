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
        val source = arrayOf(
            "--",
            "--game-id",
            "gomoku",
            "--match-id",
            "11111111-1111-4111-8111-111111111111",
            "--launch-ticket",
            "canary-secret",
            "--ws-url",
            "ws://127.0.0.1/canary",
        )
        val resumeSource = arrayOf("resume-canary-secret")
        val intent = Intent()
            .putExtra(GodotActivity.EXTRA_COMMAND_LINE_PARAMS, source)
            .putExtra(PrivateCommandLineArgs.PRIVATE_RESUME_EXTRA, resumeSource)
        val environment = FakePrivateTicketEnvironment()
        val privateArgs = PrivateCommandLineArgs(environment)

        privateArgs.consumeFrom(intent)
        source[6] = "mutated"

        assertNull(intent.getStringArrayExtra(GodotActivity.EXTRA_COMMAND_LINE_PARAMS))
        assertNull(intent.getStringArrayExtra(PrivateCommandLineArgs.PRIVATE_RESUME_EXTRA))
        assertArrayEquals(
            arrayOf(
                "project.godot",
                "--",
                "--game-id",
                "gomoku",
                "--match-id",
                "11111111-1111-4111-8111-111111111111",
                "--launch-ticket",
                PrivateCommandLineArgs.PRIVATE_TICKET_PLACEHOLDER,
                "--ws-url",
                "ws://127.0.0.1/canary",
            ),
            privateArgs.combineWith(listOf("project.godot")).toTypedArray(),
        )
        assertEquals("canary-secret", environment.ticket)
        assertEquals("resume-canary-secret", environment.resumeToken)
        val mutatedRead = privateArgs.combineWith(emptyList())
        mutatedRead[6] = "changed"
        assertArrayEquals(
            arrayOf(
                "--",
                "--game-id",
                "gomoku",
                "--match-id",
                "11111111-1111-4111-8111-111111111111",
                "--launch-ticket",
                PrivateCommandLineArgs.PRIVATE_TICKET_PLACEHOLDER,
                "--ws-url",
                "ws://127.0.0.1/canary",
            ),
            privateArgs.combineWith(emptyList()).toTypedArray(),
        )

        privateArgs.clear()
        assertFalse(privateArgs.combineWith(emptyList()).isNotEmpty())
        assertNull(environment.ticket)
    }

    @Test
    fun discardsSecretArgsFromReplacementIntent() {
        val intent = Intent()
            .putExtra(
                GodotActivity.EXTRA_COMMAND_LINE_PARAMS,
                arrayOf("--launch-ticket", "replacement-secret"),
            )
            .putExtra(PrivateCommandLineArgs.PRIVATE_RESUME_EXTRA, arrayOf("replacement-resume"))
        val privateArgs = PrivateCommandLineArgs()

        privateArgs.discardFrom(intent)

        assertNull(intent.getStringArrayExtra(GodotActivity.EXTRA_COMMAND_LINE_PARAMS))
        assertNull(intent.getStringArrayExtra(PrivateCommandLineArgs.PRIVATE_RESUME_EXTRA))
        assertFalse(privateArgs.combineWith(emptyList()).isNotEmpty())
    }

    @Test
    fun fixedNormalShapeHandlesAValueThatEqualsTheTicketKey() {
        val source = arrayOf(
            "--",
            "--game-id",
            "--launch-ticket",
            "--match-id",
            "11111111-1111-4111-8111-111111111111",
            "--launch-ticket",
            "collision-canary-secret",
            "--ws-url",
            "ws://127.0.0.1:65535/canary",
        )
        val intent = Intent().putExtra(GodotActivity.EXTRA_COMMAND_LINE_PARAMS, source)
        val environment = FakePrivateTicketEnvironment()
        val privateArgs = PrivateCommandLineArgs(environment)

        privateArgs.consumeFrom(intent)

        assertArrayEquals(
            arrayOf(
                "--",
                "--game-id",
                "--launch-ticket",
                "--match-id",
                "11111111-1111-4111-8111-111111111111",
                "--launch-ticket",
                PrivateCommandLineArgs.PRIVATE_TICKET_PLACEHOLDER,
                "--ws-url",
                "ws://127.0.0.1:65535/canary",
            ),
            privateArgs.combineWith(emptyList()).toTypedArray(),
        )
        assertEquals("collision-canary-secret", environment.ticket)
    }

    @Test
    fun malformedDuplicateAndReservedTicketInputsFailClosed() {
        val malformedInputs = listOf(
            arrayOf("--", "--launch-ticket", "malformed-secret"),
            arrayOf(
                "--",
                "--game-id",
                "gomoku",
                "--launch-ticket",
                "decoy-secret",
                "--launch-ticket",
                "real-secret",
                "--ws-url",
                "ws://127.0.0.1/canary",
            ),
            arrayOf(
                "--",
                "--game-id",
                "gomoku",
                "--match-id",
                "11111111-1111-4111-8111-111111111111",
                "--launch-ticket",
                PrivateCommandLineArgs.PRIVATE_TICKET_PLACEHOLDER,
                "--ws-url",
                "ws://127.0.0.1/canary",
            ),
        )

        malformedInputs.forEach { source ->
            val environment = FakePrivateTicketEnvironment()
            val privateArgs = PrivateCommandLineArgs(environment)
            val intent = Intent().putExtra(GodotActivity.EXTRA_COMMAND_LINE_PARAMS, source)

            privateArgs.consumeFrom(intent)

            assertFalse(privateArgs.combineWith(emptyList()).isNotEmpty())
            assertNull(environment.ticket)
            assertNull(intent.getStringArrayExtra(GodotActivity.EXTRA_COMMAND_LINE_PARAMS))
        }
    }

    private class FakePrivateTicketEnvironment : PrivateTicketEnvironment {
        var ticket: String? = null
        var resumeToken: String? = null

        override fun replace(ticket: String, resumeToken: String?): Boolean {
            this.ticket = ticket
            this.resumeToken = resumeToken
            return true
        }

        override fun clear() {
            ticket = null
            resumeToken = null
        }
    }
}
