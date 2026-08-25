extends RefCounted

const GameRegistry = preload("res://core/game_registry.gd")


static func cases() -> Array:
	return [
		{"name": "registry resolves gomoku to a packed scene", "run": _resolves_gomoku_scene},
		{"name": "registry safely rejects unknown games", "run": _rejects_unknown_game},
		{"name": "registry contains gomoku and rps", "run": _contains_supported_games},
	]


static func _resolves_gomoku_scene() -> bool:
	var result: Dictionary = GameRegistry.resolve("gomoku")
	return _check(result.get("ok", false), "expected gomoku to resolve") \
		and _check(result.get("scene") is PackedScene, "expected a PackedScene")


static func _rejects_unknown_game() -> bool:
	var result: Dictionary = GameRegistry.resolve("chess")
	return _check(not result.get("ok", true), "expected unknown game to fail") \
		and _check(result.get("code", "") == "unsupported_game", "expected unsupported-game error") \
		and _check(result.get("message", "").length() > 0, "expected safe error message")


static func _contains_supported_games() -> bool:
	var game_ids: PackedStringArray = GameRegistry.game_ids()
	return _check(game_ids.size() == 2, "expected exactly two registered games") \
		and _check(game_ids.has("gomoku"), "expected gomoku to remain registered") \
		and _check(game_ids.has("rps"), "expected rps to be registered")


static func _check(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition
