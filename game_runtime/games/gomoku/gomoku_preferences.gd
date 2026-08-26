class_name GomokuPreferences
extends RefCounted

const DEFAULT_PATH := "user://gamebox_settings.cfg"
const SECTION := "gomoku"
const CONFIRM_MOVE_KEY := "confirm_move"

var _settings_path: String


func _init(settings_path: String = DEFAULT_PATH) -> void:
	_settings_path = settings_path


func load_confirm_move() -> bool:
	var config := ConfigFile.new()
	if config.load(_settings_path) != OK:
		return false
	return config.get_value(SECTION, CONFIRM_MOVE_KEY, false) == true


func save_confirm_move(enabled: bool) -> bool:
	var config := ConfigFile.new()
	config.load(_settings_path)
	config.set_value(SECTION, CONFIRM_MOVE_KEY, enabled)
	return config.save(_settings_path) == OK
