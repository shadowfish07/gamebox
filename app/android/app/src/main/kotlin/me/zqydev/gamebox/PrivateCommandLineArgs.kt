package me.zqydev.gamebox

import android.content.Intent
import android.system.ErrnoException
import android.system.Os
import org.godotengine.godot.GodotActivity

internal interface PrivateTicketEnvironment {
    fun replace(ticket: String, resumeToken: String?): Boolean

    fun clear()
}

private object AndroidPrivateTicketEnvironment : PrivateTicketEnvironment {
    override fun replace(ticket: String, resumeToken: String?): Boolean =
        try {
            Os.setenv(PrivateCommandLineArgs.PRIVATE_TICKET_ENVIRONMENT, ticket, true)
            if (resumeToken == null) {
                Os.unsetenv(PrivateCommandLineArgs.PRIVATE_RESUME_ENVIRONMENT)
            } else {
                Os.setenv(PrivateCommandLineArgs.PRIVATE_RESUME_ENVIRONMENT, resumeToken, true)
            }
            true
        } catch (_: ErrnoException) {
            clear()
            false
        }

    override fun clear() {
        try {
            Os.unsetenv(PrivateCommandLineArgs.PRIVATE_TICKET_ENVIRONMENT)
            Os.unsetenv(PrivateCommandLineArgs.PRIVATE_RESUME_ENVIRONMENT)
        } catch (_: ErrnoException) {
            // Best-effort cleanup; the isolated :game process also exits after play.
        }
    }
}

internal class PrivateCommandLineArgs(
    private val environment: PrivateTicketEnvironment = AndroidPrivateTicketEnvironment,
) {
    private var retained = emptyArray<String>()

    @Synchronized
    fun consumeFrom(intent: Intent) {
        clear()
        val incoming = intent.getStringArrayExtra(GodotActivity.EXTRA_COMMAND_LINE_PARAMS)
        val incomingResume = intent.getStringArrayExtra(PRIVATE_RESUME_EXTRA)
        retained = incoming?.clone() ?: emptyArray()
        intent.removeExtra(GodotActivity.EXTRA_COMMAND_LINE_PARAMS)
        intent.removeExtra(PRIVATE_RESUME_EXTRA)
        incoming?.fill(ERASED_VALUE)
        val resumeToken = incomingResume?.singleOrNull()
        incomingResume?.fill(ERASED_VALUE)
        if (incomingResume != null && resumeToken == null) {
            eraseRetained()
            return
        }
        privatizeLaunchCredentials(resumeToken)
    }

    @Synchronized
    fun discardFrom(intent: Intent) {
        val incoming = intent.getStringArrayExtra(GodotActivity.EXTRA_COMMAND_LINE_PARAMS)
        val incomingResume = intent.getStringArrayExtra(PRIVATE_RESUME_EXTRA)
        intent.removeExtra(GodotActivity.EXTRA_COMMAND_LINE_PARAMS)
        intent.removeExtra(PRIVATE_RESUME_EXTRA)
        incoming?.fill(ERASED_VALUE)
        incomingResume?.fill(ERASED_VALUE)
    }

    @Synchronized
    fun combineWith(base: List<String>): MutableList<String> =
        ArrayList<String>(base.size + retained.size).apply {
            addAll(base)
            addAll(retained)
        }

    @Synchronized
    fun clear() {
        retained.fill(ERASED_VALUE)
        retained = emptyArray()
        environment.clear()
    }

    private fun privatizeLaunchCredentials(resumeToken: String?) {
        if (retained.contentEquals(HOST_SMOKE_ARGUMENTS)) {
            return
        }
        if (!hasNormalLaunchShape()) {
            eraseRetained()
            return
        }
        val ticketIndex = NORMAL_TICKET_VALUE_INDEX
        val ticket = retained[ticketIndex]
        if (ticket.isBlank() || ticket == PRIVATE_TICKET_PLACEHOLDER) {
            eraseRetained()
            return
        }
        if (resumeToken != null && (resumeToken.isBlank() || resumeToken == PRIVATE_RESUME_PLACEHOLDER)) {
            eraseRetained()
            return
        }
        retained[ticketIndex] = if (environment.replace(ticket, resumeToken)) {
            PRIVATE_TICKET_PLACEHOLDER
        } else {
            ERASED_VALUE
        }
        if (retained[ticketIndex] == ERASED_VALUE) {
            eraseRetained()
        }
    }

    private fun hasNormalLaunchShape(): Boolean =
        retained.size == NORMAL_ARGUMENT_COUNT &&
            retained[0] == "--" &&
            retained[1] == "--game-id" &&
            retained[2].isNotBlank() &&
            retained[3] == "--match-id" &&
            retained[4].isNotBlank() &&
            retained[5] == LAUNCH_TICKET_KEY &&
            retained[7] == "--ws-url" && retained[8].isNotBlank()

    private fun eraseRetained() {
        retained.fill(ERASED_VALUE)
        retained = emptyArray()
        environment.clear()
    }

    companion object {
        const val PRIVATE_TICKET_ENVIRONMENT = "GAMEBOX_PRIVATE_LAUNCH_TICKET"
        const val PRIVATE_TICKET_PLACEHOLDER = "__GAMEBOX_PRIVATE_LAUNCH_TICKET__"
        const val PRIVATE_RESUME_ENVIRONMENT = "GAMEBOX_PRIVATE_RESUME_TOKEN"
        const val PRIVATE_RESUME_PLACEHOLDER = "__GAMEBOX_PRIVATE_RESUME_TOKEN__"
        const val PRIVATE_RESUME_EXTRA = "me.zqydev.gamebox.extra.PRIVATE_RESUME_TOKEN"
        private const val LAUNCH_TICKET_KEY = "--launch-ticket"
        private const val NORMAL_ARGUMENT_COUNT = 9
        private const val NORMAL_TICKET_VALUE_INDEX = 6
        private val HOST_SMOKE_ARGUMENTS =
            arrayOf("--", "--host-smoke", "--auto-exit-ms", "800")
        const val ERASED_VALUE = ""
    }
}
