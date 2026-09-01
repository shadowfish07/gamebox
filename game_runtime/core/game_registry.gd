class_name GameRegistry
extends RefCounted

const SCENES := {
	"chinese_checkers": preload("res://games/chinese_checkers/chinese_checkers_scene.tscn"),
	"gomoku": preload("res://games/gomoku/gomoku_scene.tscn"),
	"rps": preload("res://games/rps/rps_scene.tscn"),
}
const UNSUPPORTED_GAME_MESSAGE := "This game is not available in Gamebox."


static func resolve(game_id: String) -> Dictionary:
	if not SCENES.has(game_id):
		return {"ok": false, "code": "unsupported_game", "message": UNSUPPORTED_GAME_MESSAGE}
	return {"ok": true, "code": "", "message": "", "scene": SCENES[game_id]}


static func game_ids() -> PackedStringArray:
	return PackedStringArray(SCENES.keys())
