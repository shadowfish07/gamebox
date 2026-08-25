package me.zqydev.gamebox

class GameLaunchArgs private constructor(
    private val params: Array<String>,
    val gameId: String,
    val matchId: String,
    val source: String,
    val endpointKind: String,
) {
    val requiresResultTracking: Boolean
        get() = gameId != "host-smoke"

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
        private val approvedKeys = setOf("gameId", "matchId", "launchTicket", "wsUrl", "source")
        private val canonicalUuid = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")

        fun fromNative(arguments: Any?): ParseResult {
            if (arguments !is Map<*, *> || arguments.keys != approvedKeys) {
                return ParseResult.Invalid
            }

            val values = approvedKeys.associateWith { key ->
                (arguments[key] as? String)?.takeUnless(String::isBlank)
                    ?: return ParseResult.Invalid
            }
            if (values.getValue("launchTicket") == PrivateCommandLineArgs.PRIVATE_TICKET_PLACEHOLDER) {
                return ParseResult.Invalid
            }
            val source = values.getValue("source")
            if (source !in setOf("public", "lan") || !canonicalUuid.matches(values.getValue("matchId"))) return ParseResult.Invalid

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
                    values.getValue("gameId"),
                    values.getValue("matchId"),
                    source,
                    source,
                ),
            )
        }

        fun hostSmoke(): GameLaunchArgs =
            GameLaunchArgs(
                arrayOf("--", "--host-smoke", "--auto-exit-ms", "800"),
                "host-smoke",
                "host-smoke",
                "public",
                "public",
            )
    }
}
