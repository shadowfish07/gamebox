extends RefCounted

const GomokuPreferences = preload("res://games/gomoku/gomoku_preferences.gd")


static func cases() -> Array:
	return [
		{"name": "gomoku preferences default to direct moves", "run": _defaults_to_direct_moves},
		{"name": "gomoku preferences persist move confirmation", "run": _persists_move_confirmation},
	]


static func _defaults_to_direct_moves() -> bool:
	var settings_path := _settings_path("default")
	_remove(settings_path)
	var preferences = GomokuPreferences.new(settings_path)
	var result := _check(not preferences.load_confirm_move(), "missing setting did not preserve direct moves")
	_remove(settings_path)
	return result


static func _persists_move_confirmation() -> bool:
	var settings_path := _settings_path("persist")
	_remove(settings_path)
	var writer = GomokuPreferences.new(settings_path)
	if not _check(writer.save_confirm_move(true), "enabled confirmation setting was not saved"):
		_remove(settings_path)
		return false
	var reader = GomokuPreferences.new(settings_path)
	if not _check(reader.load_confirm_move(), "enabled confirmation setting was not restored"):
		_remove(settings_path)
		return false
	if not _check(reader.save_confirm_move(false), "disabled confirmation setting was not saved"):
		_remove(settings_path)
		return false
	var result := _check(not GomokuPreferences.new(settings_path).load_confirm_move(), "disabled setting was not restored")
	_remove(settings_path)
	return result


static func _settings_path(suffix: String) -> String:
	return "user://gomoku-preferences-%s-%d.cfg" % [suffix, Time.get_ticks_usec()]


static func _remove(settings_path: String) -> void:
	if FileAccess.file_exists(settings_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(settings_path))


static func _check(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition
