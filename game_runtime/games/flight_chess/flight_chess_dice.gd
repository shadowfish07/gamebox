class_name FlightChessDice
extends Control

const GameboxTokens = preload("res://design_system/generated/gamebox_tokens.gd")
const FlightChessBoard = preload("res://games/flight_chess/flight_chess_board.gd")

var value: int:
	get: return _value
	set(next_value): set_value(next_value)

var _value := 0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_value(next_value: int) -> bool:
	if next_value < 0 or next_value > 6:
		return false
	_value = next_value
	queue_redraw()
	return true


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED or what == NOTIFICATION_THEME_CHANGED:
		queue_redraw()


func _draw() -> void:
	var side := minf(size.x, size.y)
	if side <= 0.0:
		return
	var rect := Rect2((size - Vector2(side, side)) * 0.5, Vector2(side, side)).grow(-side * 0.08)
	var style := StyleBoxFlat.new()
	style.bg_color = get_theme_color("face_color", "FlightChessDice")
	style.border_color = get_theme_color("outline_color", "FlightChessDice")
	var border := maxi(2, roundi(side * 0.035))
	style.border_width_left = border
	style.border_width_top = border
	style.border_width_right = border
	style.border_width_bottom = border
	var corner := roundi(side * 0.17)
	style.corner_radius_top_left = corner
	style.corner_radius_top_right = corner
	style.corner_radius_bottom_right = corner
	style.corner_radius_bottom_left = corner
	style.shadow_color = Color(GameboxTokens.LIGHT["shadow"], GameboxTokens.COMPONENT["result_shadow_opacity"])
	style.shadow_size = roundi(side * 0.055)
	style.shadow_offset = Vector2(0.0, side * 0.035)
	draw_style_box(style, rect)
	if _value == 0:
		_draw_idle_mark(rect)
	else:
		_draw_pips(rect)


func _draw_idle_mark(rect: Rect2) -> void:
	var center := rect.get_center()
	var color := get_theme_color("pip_color", "FlightChessDice")
	var radius := rect.size.x * 0.24
	draw_circle(center, radius, Color(color, GameboxTokens.GAME["board_side_camp_alpha"]))
	draw_arc(center, radius, -0.22, PI * 1.08, 28, Color(color, GameboxTokens.GAME["pending_overlay_alpha"]), maxf(2.0, rect.size.x * 0.025), true)
	draw_arc(center, radius, PI - 0.22, PI * 2.08, 28, Color(color, GameboxTokens.GAME["board_grid_alpha"]), maxf(2.0, rect.size.x * 0.018), true)
	var direction := Vector2.RIGHT.rotated(-0.22)
	var tip := center + direction * radius
	var perpendicular := Vector2(-direction.y, direction.x)
	draw_colored_polygon(PackedVector2Array([
		tip,
		tip - direction * rect.size.x * 0.09 + perpendicular * rect.size.x * 0.05,
		tip - direction * rect.size.x * 0.09 - perpendicular * rect.size.x * 0.05,
	]), color)
	_draw_plane_mark(center, rect.size.x * 0.17, color)


func _draw_plane_mark(center: Vector2, radius: float, color: Color) -> void:
	var source := [
		Vector2(0.92, 0.0), Vector2(0.2, -0.16), Vector2(-0.14, -0.78),
		Vector2(-0.36, -0.78), Vector2(-0.22, -0.13), Vector2(-0.74, -0.34),
		Vector2(-0.88, -0.18), Vector2(-0.42, 0.0), Vector2(-0.88, 0.18),
		Vector2(-0.74, 0.34), Vector2(-0.22, 0.13), Vector2(-0.36, 0.78),
		Vector2(-0.14, 0.78), Vector2(0.2, 0.16),
	]
	var points := PackedVector2Array()
	for point in source:
		points.append(center + point * radius)
	draw_colored_polygon(points, color)


func _draw_pips(rect: Rect2) -> void:
	var center := rect.get_center()
	var distance := rect.size.x * 0.24
	var positions := {
		"tl": center + Vector2(-distance, -distance), "tc": center + Vector2(0, -distance), "tr": center + Vector2(distance, -distance),
		"ml": center + Vector2(-distance, 0), "mc": center, "mr": center + Vector2(distance, 0),
		"bl": center + Vector2(-distance, distance), "bc": center + Vector2(0, distance), "br": center + Vector2(distance, distance),
	}
	var layout := {
		1: ["mc"], 2: ["tl", "br"], 3: ["tl", "mc", "br"],
		4: ["tl", "tr", "bl", "br"], 5: ["tl", "tr", "mc", "bl", "br"],
		6: ["tl", "ml", "bl", "tr", "mr", "br"],
	}
	var radius := rect.size.x * 0.064
	for key in layout[_value]:
		draw_circle(positions[key], radius, get_theme_color("pip_color", "FlightChessDice"))
