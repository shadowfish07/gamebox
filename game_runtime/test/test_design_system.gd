extends RefCounted

const GameboxTheme = preload("res://design_system/gamebox_theme.gd")
const GameboxTokens = preload("res://design_system/generated/gamebox_tokens.gd")


static func cases() -> Array:
	return [
		{"name": "design system maps light and dark semantic tokens", "run": _maps_semantic_tokens},
		{"name": "design system defines public control states and types", "run": _defines_control_states},
		{"name": "design system keeps board colors out of the shared theme", "run": _keeps_game_colors_private},
		{"name": "design system dark preference always returns a boolean", "run": _returns_dark_preference},
	]


static func _maps_semantic_tokens() -> bool:
	var light := GameboxTheme.create(false)
	var dark := GameboxTheme.create(true)
	return _check(light.get_color("font_color", "Label") == GameboxTokens.LIGHT["on_surface"], "light label color drifted") \
		and _check(dark.get_color("font_color", "Label") == GameboxTokens.DARK["on_surface"], "dark label color drifted") \
		and _check(light.get_color("font_color", "Button") == GameboxTokens.LIGHT["on_primary"], "light button foreground drifted") \
		and _check(dark.get_color("font_color", "Button") == GameboxTokens.DARK["on_primary"], "dark button foreground drifted") \
		and _check(light.get_font_size("font_size", "Label") == 28, "label type scale drifted") \
		and _check(light.get_font_size("font_size", "Button") == 28, "button type scale drifted")


static func _defines_control_states() -> bool:
	var theme := GameboxTheme.create(false)
	for type_name in ["Label", "Button", "PanelContainer", "ProgressBar", "Window", "AcceptDialog"]:
		if not _check(theme.get_type_list().has(type_name), "missing shared Theme type %s" % type_name):
			return false
	for state in ["normal", "hover", "pressed", "disabled"]:
		if not _check(theme.has_stylebox(state, "Button"), "missing Button %s style" % state):
			return false
	return _check(theme.has_color("font_pressed_color", "Button"), "pressed button color missing") \
		and _check(theme.has_color("font_disabled_color", "Button"), "disabled button color missing") \
		and _check(theme.has_stylebox("panel", "PanelContainer"), "panel surface style missing") \
		and _check(theme.has_stylebox("fill", "ProgressBar"), "progress fill style missing")


static func _keeps_game_colors_private() -> bool:
	var game_roles: Array = GameboxTokens.GAME.keys()
	for dark in [false, true]:
		var theme := GameboxTheme.create(dark)
		for type_name in theme.get_type_list():
			for color_name in theme.get_color_list(type_name):
				if not _check(not game_roles.has(color_name), "game role leaked into shared Theme: %s" % color_name):
					return false
	return true


static func _returns_dark_preference() -> bool:
	return _check(typeof(GameboxTheme.system_prefers_dark()) == TYPE_BOOL, "system dark preference was not boolean")


static func _check(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition
