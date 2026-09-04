class_name FlightChessTheme
extends RefCounted

const GameboxTheme = preload("res://design_system/gamebox_theme.gd")
const GameboxTokens = preload("res://design_system/generated/gamebox_tokens.gd")
const FlightChessBoard = preload("res://games/flight_chess/flight_chess_board.gd")


static func create(dark: bool) -> Theme:
	var colors: Dictionary = GameboxTokens.DARK if dark else GameboxTokens.LIGHT
	var theme := GameboxTheme.create(dark)
	var semibold := SystemFont.new()
	semibold.font_weight = 650
	var bold := SystemFont.new()
	bold.font_weight = 750

	for pair in [
		["FlightChessBackground", "PanelContainer"],
		["FlightChessRail", "PanelContainer"],
		["FlightChessYellowCard", "PanelContainer"],
		["FlightChessRedCard", "PanelContainer"],
		["FlightChessDiceCard", "PanelContainer"],
		["FlightChessGameTitle", "Label"],
		["FlightChessEyebrow", "Label"],
		["FlightChessPlayerName", "Label"],
		["FlightChessPlayerMeta", "Label"],
		["FlightChessTurn", "Label"],
		["FlightChessHint", "Label"],
		["FlightChessRule", "Label"],
		["FlightChessRuleCompact", "Label"],
		["FlightChessStatus", "Label"],
		["FlightChessTurnCompact", "Label"],
		["FlightChessDice", "Control"],
	]:
		theme.set_type_variation(pair[0], pair[1])

	theme.set_stylebox("panel", "FlightChessBackground", _flat_style(colors["surface"]))
	theme.set_stylebox("panel", "FlightChessRail", StyleBoxEmpty.new())
	theme.set_stylebox("panel", "FlightChessYellowCard", _panel_style(colors["surface"].lerp(FlightChessBoard.PLAYER_COLORS["yellow"], 0.18), FlightChessBoard.PLAYER_DARK["yellow"], 16, 16, colors["shadow"]))
	theme.set_stylebox("panel", "FlightChessRedCard", _panel_style(colors["surface"].lerp(FlightChessBoard.PLAYER_COLORS["red"], 0.17), FlightChessBoard.PLAYER_DARK["red"], 16, 16, colors["shadow"]))
	theme.set_stylebox("panel", "FlightChessDiceCard", _panel_style(colors["surface_container_high"], colors["outline_variant"], 22, 8, colors["shadow"]))

	theme.set_font("font", "FlightChessGameTitle", bold)
	theme.set_font_size("font_size", "FlightChessGameTitle", _scaled(GameboxTokens.TYPOGRAPHY["headline_medium"]["font_size"]))
	theme.set_color("font_color", "FlightChessGameTitle", colors["on_surface"])
	theme.set_font("font", "FlightChessEyebrow", semibold)
	theme.set_font_size("font_size", "FlightChessEyebrow", _scaled(GameboxTokens.TYPOGRAPHY["label_medium"]["font_size"]))
	theme.set_color("font_color", "FlightChessEyebrow", colors["primary"])
	theme.set_font("font", "FlightChessPlayerName", bold)
	theme.set_font_size("font_size", "FlightChessPlayerName", _scaled(GameboxTokens.TYPOGRAPHY["title_medium"]["font_size"]))
	theme.set_color("font_color", "FlightChessPlayerName", colors["on_surface"])
	theme.set_font("font", "FlightChessPlayerMeta", semibold)
	theme.set_font_size("font_size", "FlightChessPlayerMeta", _scaled(GameboxTokens.TYPOGRAPHY["body_small"]["font_size"]))
	theme.set_color("font_color", "FlightChessPlayerMeta", colors["on_surface_variant"])
	theme.set_font("font", "FlightChessTurn", bold)
	theme.set_font_size("font_size", "FlightChessTurn", _scaled(GameboxTokens.TYPOGRAPHY["headline_small"]["font_size"]))
	theme.set_color("font_color", "FlightChessTurn", colors["on_surface"])
	theme.set_font("font", "FlightChessTurnCompact", bold)
	theme.set_font_size("font_size", "FlightChessTurnCompact", _scaled(GameboxTokens.TYPOGRAPHY["title_medium"]["font_size"]))
	theme.set_color("font_color", "FlightChessTurnCompact", colors["on_surface"])
	for type_name in ["FlightChessHint", "FlightChessRule"]:
		theme.set_font_size("font_size", type_name, _scaled(GameboxTokens.TYPOGRAPHY["body_medium"]["font_size"]))
		theme.set_color("font_color", type_name, colors["on_surface_variant"])
	theme.set_font_size("font_size", "FlightChessRuleCompact", _scaled(GameboxTokens.TYPOGRAPHY["body_small"]["font_size"]))
	theme.set_color("font_color", "FlightChessRuleCompact", colors["on_surface_variant"])
	theme.set_font("font", "FlightChessStatus", semibold)
	theme.set_font_size("font_size", "FlightChessStatus", _scaled(GameboxTokens.TYPOGRAPHY["label_medium"]["font_size"]))
	theme.set_color("font_color", "FlightChessStatus", colors["on_primary_container"])
	theme.set_stylebox("normal", "FlightChessStatus", _label_style(colors["primary_container"], GameboxTokens.SHAPE["full"], 14, 7))

	theme.set_color("face_color", "FlightChessDice", colors["surface_container_lowest"])
	theme.set_color("pip_color", "FlightChessDice", colors["primary"])
	theme.set_color("outline_color", "FlightChessDice", colors["outline"])
	theme.set_constant("separation", "VBoxContainer", _scaled(GameboxTokens.SPACING["layout"]))
	return theme


static func _scaled(value: Variant) -> int:
	return roundi(float(value) * GameboxTheme.LOGICAL_SCALE)


static func _flat_style(fill: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	return style


static func _panel_style(fill: Color, border: Color, radius: int, padding: int, shadow: Variant = null) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(2)
	style.set_corner_radius_all(_scaled(radius))
	style.content_margin_left = _scaled(padding)
	style.content_margin_top = _scaled(padding)
	style.content_margin_right = _scaled(padding)
	style.content_margin_bottom = _scaled(padding)
	if shadow is Color:
		style.shadow_color = Color(shadow, GameboxTokens.COMPONENT["result_shadow_opacity"])
		style.shadow_size = _scaled(5)
		style.shadow_offset = Vector2(0.0, _scaled(3))
	return style


static func _label_style(fill: Color, radius: int, horizontal_padding: int, vertical_padding: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.set_corner_radius_all(_scaled(radius))
	style.content_margin_left = _scaled(horizontal_padding)
	style.content_margin_right = _scaled(horizontal_padding)
	style.content_margin_top = _scaled(vertical_padding)
	style.content_margin_bottom = _scaled(vertical_padding)
	return style
