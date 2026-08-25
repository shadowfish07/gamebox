package me.zqydev.gamebox

import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

object GameResultValidator {
    private val uuid = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
    private val resultKeys = setOf(
        "schemaVersion", "matchId", "gameId", "players", "winnerUserId", "result",
        "startedAt", "finishedAt", "finalRevision", "events",
    )
    private val playerKeys = setOf("userId", "nickname", "seat", "color")
    private val eventKeys = setOf("revision", "type", "actionId", "actorId", "payload", "committedAt")

    data class Validated(val matchId: String, val canonical: String)

    fun validateMatchId(value: String): Boolean = uuid.matches(value)

    fun validate(raw: String): Validated? {
        if (raw.toByteArray().size !in 2..(512 * 1024) || hasDuplicateObjectKey(raw)) return null
        val root = try {
            JSONObject(raw)
        } catch (_: JSONException) {
            return null
        }
        if (!root.exactKeys(resultKeys) || root.optInt("schemaVersion", -1) != 1 || root.optString("gameId") != "gomoku") return null
        val matchId = root.optString("matchId")
        val startedAt = root.strictLong("startedAt") ?: return null
        val finishedAt = root.strictLong("finishedAt") ?: return null
        val finalRevision = root.strictLong("finalRevision") ?: return null
        if (!uuid.matches(matchId) || startedAt <= 0 || finishedAt < startedAt || finalRevision <= 0 || finalRevision > 226) return null

        val players = root.optJSONArray("players") ?: return null
        if (players.length() != 2) return null
        val users = mutableSetOf<String>()
        val seats = mutableSetOf<Int>()
        val colors = mutableSetOf<String>()
        for (index in 0 until players.length()) {
            val player = players.optJSONObject(index) ?: return null
            if (!player.exactKeys(playerKeys)) return null
            val userId = player.optString("userId")
            val nickname = player.optString("nickname")
            val seat = player.strictInt("seat") ?: return null
            val color = player.optString("color")
            if (!uuid.matches(userId) || nickname.isEmpty() || nickname.toByteArray().size > 80 || seat !in 0..1 || color !in setOf("black", "white")) return null
            users += userId
            seats += seat
            colors += color
        }
        if (users.size != 2 || seats != setOf(0, 1) || colors != setOf("black", "white")) return null

        val result = root.optString("result")
        val winner = if (root.isNull("winnerUserId")) null else root.optString("winnerUserId")
        if (result !in setOf("five", "resignation", "draw") || (result == "draw") != (winner == null) || winner != null && winner !in users) return null

        val events = root.optJSONArray("events") ?: return null
        if (events.length().toLong() != finalRevision) return null
        val actions = mutableSetOf<String>()
        var previousTime = startedAt
        for (index in 0 until events.length()) {
            val event = events.optJSONObject(index) ?: return null
            if (!event.exactKeys(eventKeys) || event.strictLong("revision") != index.toLong() + 1) return null
            val type = event.optString("type")
            val committedAt = event.strictLong("committedAt") ?: return null
            if (type.isEmpty() || type.length > 128 || committedAt < previousTime || committedAt > finishedAt || event.optJSONObject("payload") == null) return null
            previousTime = committedAt
            for (key in listOf("actionId", "actorId")) {
                if (event.isNull(key)) continue
                val value = event.optString(key)
                if (!uuid.matches(value) || key == "actorId" && value !in users || key == "actionId" && !actions.add(value)) return null
            }
        }
        if (previousTime != finishedAt) return null
        return Validated(matchId, raw)
    }

    private fun JSONObject.exactKeys(expected: Set<String>): Boolean = keys().asSequence().toSet() == expected

    private fun JSONObject.strictLong(key: String): Long? {
        val value = opt(key)
        if (value is Int) return value.toLong()
        if (value is Long) return value
        return null
    }

    private fun JSONObject.strictInt(key: String): Int? = (opt(key) as? Int)

    // org.json accepts duplicate keys. This scanner rejects them before parsing,
    // while understanding JSON strings and nested object/array boundaries.
    private fun hasDuplicateObjectKey(text: String): Boolean {
        data class Frame(val objectKeys: MutableSet<String>?, var expectingKey: Boolean)
        val stack = ArrayDeque<Frame>()
        var index = 0
        while (index < text.length) {
            when (val char = text[index]) {
                '{' -> stack.addLast(Frame(mutableSetOf(), true))
                '[' -> stack.addLast(Frame(null, false))
                '}', ']' -> if (stack.isEmpty()) return true else stack.removeLast()
                ',' -> stack.lastOrNull()?.let { if (it.objectKeys != null) it.expectingKey = true }
                '"' -> {
                    val start = index
                    index++
                    var escaped = false
                    while (index < text.length) {
                        val current = text[index]
                        if (!escaped && current == '"') break
                        escaped = !escaped && current == '\\'
                        if (current != '\\') escaped = false
                        index++
                    }
                    if (index >= text.length) return true
                    val frame = stack.lastOrNull()
                    if (frame?.objectKeys != null && frame.expectingKey) {
                        val decoded = try { JSONArray("[${text.substring(start, index + 1)}]").getString(0) } catch (_: JSONException) { return true }
                        if (!frame.objectKeys.add(decoded)) return true
                        frame.expectingKey = false
                    }
                }
            }
            index++
        }
        return stack.isNotEmpty()
    }
}
