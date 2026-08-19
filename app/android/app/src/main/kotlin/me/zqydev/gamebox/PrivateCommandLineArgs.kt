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
        val ticketKeyIndex = retained.indexOf(LAUNCH_TICKET_KEY)
        if (ticketKeyIndex < 0 || ticketKeyIndex + 1 >= retained.size) {
            return
        }
        val ticketIndex = ticketKeyIndex + 1
        val ticket = retained[ticketIndex]
        retained[ticketIndex] = if (environment.replace(ticket)) {
            PRIVATE_TICKET_PLACEHOLDER
        } else {
            ERASED_VALUE
        }
    }

    companion object {
        const val PRIVATE_TICKET_ENVIRONMENT = "GAMEBOX_PRIVATE_LAUNCH_TICKET"
        const val PRIVATE_TICKET_PLACEHOLDER = "__GAMEBOX_PRIVATE_LAUNCH_TICKET__"
        private const val LAUNCH_TICKET_KEY = "--launch-ticket"
        const val ERASED_VALUE = ""
    }
}
