package me.zqydev.gamebox

import android.content.Intent
import android.system.ErrnoException
import android.system.Os
import org.godotengine.godot.GodotActivity

internal interface PrivateTicketEnvironment {
    fun replace(value: String): Boolean

    fun clear()
}

private object AndroidPrivateTicketEnvironment : PrivateTicketEnvironment {
    override fun replace(value: String): Boolean =
        try {
            Os.setenv(PrivateCommandLineArgs.PRIVATE_TICKET_ENVIRONMENT, value, true)
            true
        } catch (_: ErrnoException) {
            false
        }

    override fun clear() {
        try {
            Os.unsetenv(PrivateCommandLineArgs.PRIVATE_TICKET_ENVIRONMENT)
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
        retained = incoming?.clone() ?: emptyArray()
        intent.removeExtra(GodotActivity.EXTRA_COMMAND_LINE_PARAMS)
        incoming?.fill(ERASED_VALUE)
        privatizeLaunchTicket()
    }

    @Synchronized
    fun discardFrom(intent: Intent) {
        val incoming = intent.getStringArrayExtra(GodotActivity.EXTRA_COMMAND_LINE_PARAMS)
        intent.removeExtra(GodotActivity.EXTRA_COMMAND_LINE_PARAMS)
        incoming?.fill(ERASED_VALUE)
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

    private fun privatizeLaunchTicket() {
        if (
            retained.contentEquals(HOST_SMOKE_ARGUMENTS) ||
            retained.contentEquals(FLIGHT_CHESS_PREVIEW_ARGUMENTS)
        ) {
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
        retained[ticketIndex] = if (environment.replace(ticket)) {
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
            retained[7] == "--ws-url" &&
            retained[8].isNotBlank()

    private fun eraseRetained() {
        retained.fill(ERASED_VALUE)
        retained = emptyArray()
        environment.clear()
    }

    companion object {
        const val PRIVATE_TICKET_ENVIRONMENT = "GAMEBOX_PRIVATE_LAUNCH_TICKET"
        const val PRIVATE_TICKET_PLACEHOLDER = "__GAMEBOX_PRIVATE_LAUNCH_TICKET__"
        private const val LAUNCH_TICKET_KEY = "--launch-ticket"
        private const val NORMAL_ARGUMENT_COUNT = 9
        private const val NORMAL_TICKET_VALUE_INDEX = 6
        private val HOST_SMOKE_ARGUMENTS =
            arrayOf("--", "--host-smoke", "--auto-exit-ms", "800")
        private val FLIGHT_CHESS_PREVIEW_ARGUMENTS =
            arrayOf("--", "--host-smoke", "--preview-game", "flight_chess")
        const val ERASED_VALUE = ""
    }
}
