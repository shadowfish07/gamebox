package me.zqydev.gamebox

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import lanengine.Lanengine
import org.json.JSONObject

internal class AppProfileChannel(messenger: BinaryMessenger) : AutoCloseable {
    private val channel = MethodChannel(messenger, CHANNEL_NAME)

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != NORMALIZE_METHOD) {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val arguments = call.arguments as? Map<*, *>
            val raw = arguments?.get(NICKNAME_ARGUMENT) as? String
            if (arguments?.size != 1 || raw == null) {
                result.error(INVALID_NICKNAME_CODE, INVALID_NICKNAME_MESSAGE, null)
                return@setMethodCallHandler
            }
            try {
                val nickname = normalizeNickname(raw)
                if (nickname == null) {
                    result.error(INVALID_NICKNAME_CODE, INVALID_NICKNAME_MESSAGE, null)
                } else {
                    result.success(mapOf(NICKNAME_ARGUMENT to nickname))
                }
            } catch (_: RuntimeException) {
                result.error(PROFILE_UNAVAILABLE_CODE, PROFILE_UNAVAILABLE_MESSAGE, null)
            }
        }
    }

    override fun close() {
        channel.setMethodCallHandler(null)
    }

    internal companion object {
        const val CHANNEL_NAME = "me.zqydev.gamebox/app_profile"
        const val NORMALIZE_METHOD = "normalizeNickname"
        const val NICKNAME_ARGUMENT = "nickname"
        const val INVALID_NICKNAME_CODE = "invalid_nickname"
        const val INVALID_NICKNAME_MESSAGE = "Nickname is invalid"
        const val PROFILE_UNAVAILABLE_CODE = "profile_unavailable"
        const val PROFILE_UNAVAILABLE_MESSAGE = "Nickname rules are unavailable"

        fun normalizeNickname(raw: String): String? {
            val response = JSONObject(Lanengine.normalizeNickname(raw))
            if (!response.getBoolean("valid")) return null
            return response.getString("display").takeIf { it.isNotEmpty() }
        }
    }
}
