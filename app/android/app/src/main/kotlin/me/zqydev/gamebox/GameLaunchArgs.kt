package me.zqydev.gamebox

class GameLaunchArgs private constructor(private val params: Array<String>) {
    val commandLineParams: Array<String>
        get() = params.clone()

    override fun toString(): String = "GameLaunchArgs(redacted)"

    sealed interface ParseResult {
        class Success(val args: GameLaunchArgs) : ParseResult {
            override fun toString(): String = "Success($args)"
        }

        data object Invalid : ParseResult
    }

    companion object {
        private val approvedKeys = setOf("gameId", "matchId", "launchTicket", "wsUrl")

        fun fromNative(arguments: Any?): ParseResult {
            if (arguments !is Map<*, *> || arguments.keys != approvedKeys) {
                return ParseResult.Invalid
            }

            val values = approvedKeys.associateWith { key ->
                (arguments[key] as? String)?.takeUnless(String::isBlank)
                    ?: return ParseResult.Invalid
            }

            return ParseResult.Success(
                GameLaunchArgs(
                    arrayOf(
                        "--",
                        "--game-id",
                        values.getValue("gameId"),
                        "--match-id",
                        values.getValue("matchId"),
                        "--launch-ticket",
                        values.getValue("launchTicket"),
                        "--ws-url",
                        values.getValue("wsUrl"),
                    ),
                ),
            )
        }

        fun hostSmoke(): GameLaunchArgs =
            GameLaunchArgs(arrayOf("--", "--host-smoke", "--auto-exit-ms", "800"))
    }
}
