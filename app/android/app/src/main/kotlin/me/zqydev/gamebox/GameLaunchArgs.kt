package me.zqydev.gamebox

class GameLaunchArgs private constructor(
    private val params: Array<String>,
    val gameId: String,
    val matchId: String,
    val source: String,
    val endpointKind: String,
    val localUserId: String?,
    internal val privateResumeToken: String?,
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
        private val approvedKeys = setOf("gameId", "matchId", "launchTicket", "wsUrl", "source", "resumeToken", "localUserId")
        private val canonicalUuid = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
        private val canonicalCredential = Regex("^[A-Za-z0-9_-]{43}$")

        fun fromNative(arguments: Any?): ParseResult {
            if (arguments !is Map<*, *> || arguments.keys != approvedKeys) {
                return ParseResult.Invalid
            }

            val requiredKeys = approvedKeys - setOf("resumeToken", "localUserId")
            val values = requiredKeys.associateWith { key ->
                (arguments[key] as? String)?.takeUnless(String::isBlank)
                    ?: return ParseResult.Invalid
            }
            if (values.getValue("launchTicket") == PrivateCommandLineArgs.PRIVATE_TICKET_PLACEHOLDER) {
                return ParseResult.Invalid
            }
            val source = values.getValue("source")
            if (source !in setOf("public", "lan") || !canonicalUuid.matches(values.getValue("matchId"))) return ParseResult.Invalid
            val resumeToken = arguments["resumeToken"]
            val localUserId = arguments["localUserId"]
            if (source == "public" && resumeToken != null) return ParseResult.Invalid
            if (source == "public" && localUserId != null) return ParseResult.Invalid
            if (source == "lan" &&
                (resumeToken !is String || !canonicalCredential.matches(resumeToken) ||
                    resumeToken == PrivateCommandLineArgs.PRIVATE_RESUME_PLACEHOLDER ||
                    localUserId !is String || !canonicalUuid.matches(localUserId))
            ) return ParseResult.Invalid

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
                    localUserId as? String,
                    resumeToken as? String,
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
                null,
                null,
            )
    }
}
