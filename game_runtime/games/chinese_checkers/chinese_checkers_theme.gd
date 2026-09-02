class_name ChineseCheckersTheme
extends RefCounted

const GameboxTheme = preload("res://design_system/gamebox_theme.gd")
const GameboxTokens = preload("res://design_system/generated/gamebox_tokens.gd")


static func create(dark: bool) -> Theme:
	var colors: Dictionary = GameboxTokens.DARK if dark else GameboxTokens.LIGHT
	var theme := GameboxTheme.create(dark)
	var semibold_font := SystemFont.new()
	semibold_font.font_weight = 600
	var identity_size := _scaled(GameboxTokens.TYPOGRAPHY["label_large"]["font_size"])
	var supporting_size := _scaled(GameboxTokens.TYPOGRAPHY["label_medium"]["font_size"])

	for pair in [
		["ChineseCheckersTurnPlayerStrip", "PanelContainer"],
		["ChineseCheckersTurnPlayerRow", "HBoxContainer"],
		["ChineseCheckersTurnPlayerInactive", "PanelContainer"],
		["ChineseCheckersTurnPlayerActiveLocal", "PanelContainer"],
		["ChineseCheckersTurnPlayerActiveOpponent", "PanelContainer"],
		["ChineseCheckersTurnPlayerIdentity", "Label"],
		["ChineseCheckersTurnPlayerSupporting", "Label"],
		["ChineseCheckersTurnPlayerActiveLocalIdentity", "Label"],
		["ChineseCheckersTurnPlayerActiveLocalSupporting", "Label"],
		["ChineseCheckersTurnPlayerActiveOpponentIdentity", "Label"],
		["ChineseCheckersTurnPlayerActiveOpponentSupporting", "Label"],
		["ChineseCheckersTurnStatus", "Label"],
	]:
		theme.set_type_variation(pair[0], pair[1])

	theme.set_stylebox("panel", "ChineseCheckersTurnPlayerStrip", _turn_strip_style())
	theme.set_constant("separation", "ChineseCheckersTurnPlayerRow", _scaled(GameboxTokens.SPACING["base"]))
	theme.set_stylebox("panel", "ChineseCheckersTurnPlayerInactive", _turn_player_inactive_style())
	theme.set_stylebox("panel", "ChineseCheckersTurnPlayerActiveLocal", _turn_player_style(colors["primary_container"], colors["primary_fixed_dim"]))
	theme.set_stylebox("panel", "ChineseCheckersTurnPlayerActiveOpponent", _turn_player_style(colors["tertiary_container"], colors["tertiary_fixed_dim"]))
	for identity_type in ["ChineseCheckersTurnPlayerIdentity", "ChineseCheckersTurnPlayerActiveLocalIdentity", "ChineseCheckersTurnPlayerActiveOpponentIdentity"]:
		theme.set_font("font", identity_type, semibold_font)
		theme.set_font_size("font_size", identity_type, identity_size)
	for supporting_type in ["ChineseCheckersTurnPlayerSupporting", "ChineseCheckersTurnPlayerActiveLocalSupporting", "ChineseCheckersTurnPlayerActiveOpponentSupporting"]:
		theme.set_font("font", supporting_type, semibold_font)
		theme.set_font_size("font_size", supporting_type, supporting_size)
	theme.set_color("font_color", "ChineseCheckersTurnPlayerIdentity", colors["on_surface"])
	theme.set_color("font_color", "ChineseCheckersTurnPlayerSupporting", colors["on_surface_variant"])
	theme.set_color("font_color", "ChineseCheckersTurnPlayerActiveLocalIdentity", colors["on_primary_container"])
	theme.set_color("font_color", "ChineseCheckersTurnPlayerActiveLocalSupporting", colors["on_primary_container"])
	theme.set_color("font_color", "ChineseCheckersTurnPlayerActiveOpponentIdentity", colors["on_tertiary_container"])
	theme.set_color("font_color", "ChineseCheckersTurnPlayerActiveOpponentSupporting", colors["on_tertiary_container"])
	theme.set_font("font", "ChineseCheckersTurnStatus", semibold_font)
	theme.set_font_size("font_size", "ChineseCheckersTurnStatus", supporting_size)
	theme.set_color("font_color", "ChineseCheckersTurnStatus", colors["on_surface_variant"])
	theme.set_stylebox("normal", "ChineseCheckersTurnStatus", _turn_status_style())
	return theme


static func _scaled(value: Variant) -> int:
	return roundi(float(value) * GameboxTheme.LOGICAL_SCALE)


static func _turn_strip_style() -> StyleBoxEmpty:
	var box := StyleBoxEmpty.new()
	box.content_margin_left = _scaled(GameboxTokens.SPACING["layout"])
	box.content_margin_right = _scaled(GameboxTokens.SPACING["layout"])
	box.content_margin_top = _scaled(GameboxTokens.SPACING["base"])
	box.content_margin_bottom = _scaled(GameboxTokens.SPACING["base"])
	return box


static func _turn_status_style() -> StyleBoxEmpty:
	var box := StyleBoxEmpty.new()
	box.content_margin_left = _scaled(GameboxTokens.SPACING["layout"])
	box.content_margin_right = _scaled(GameboxTokens.SPACING["layout"])
	return box


static func _turn_player_style(fill: Color, border: Color) -> StyleBoxFlat:
	var box := _turn_player_base_style()
	box.bg_color = fill
	var radius := _scaled(GameboxTokens.SHAPE["card"])
	box.corner_radius_top_left = radius
	box.corner_radius_top_right = radius
	box.corner_radius_bottom_right = radius
	box.corner_radius_bottom_left = radius
	var border_width := _scaled(GameboxTokens.SPACING["base"]) / int(GameboxTheme.LOGICAL_SCALE)
	box.border_color = border
	box.border_width_left = border_width
	box.border_width_top = border_width
	box.border_width_right = border_width
	box.border_width_bottom = border_width
	return box


static func _turn_player_inactive_style() -> StyleBoxEmpty:
	var box := StyleBoxEmpty.new()
	_apply_player_margins(box)
	return box


static func _turn_player_base_style() -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	_apply_player_margins(box)
	return box


static func _apply_player_margins(box: StyleBox) -> void:
	box.content_margin_left = _scaled(GameboxTokens.SPACING["layout"])
	box.content_margin_right = _scaled(GameboxTokens.SPACING["layout"])
	box.content_margin_top = _scaled(GameboxTokens.SPACING["base"])
	box.content_margin_bottom = _scaled(GameboxTokens.SPACING["base"])
