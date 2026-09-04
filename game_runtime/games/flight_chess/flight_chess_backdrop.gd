class_name FlightChessBackdrop
extends Control

const FlightChessBoard = preload("res://games/flight_chess/flight_chess_board.gd")
const GameboxTokens = preload("res://design_system/generated/gamebox_tokens.gd")


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED or what == NOTIFICATION_THEME_CHANGED:
		queue_redraw()


func _draw() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var glow_radius := size.y * 0.72
	var glow_centers := [
		Vector2(0.0, 0.0), Vector2(size.x, 0.0),
		Vector2(size.x, size.y), Vector2(0.0, size.y),
	]
	var glow_colors := [
		FlightChessBoard.PLAYER_COLORS["yellow"],
		FlightChessBoard.PLAYER_COLORS["green"],
		FlightChessBoard.PLAYER_COLORS["red"],
		FlightChessBoard.PLAYER_COLORS["blue"],
	]
	for index in glow_centers.size():
		draw_circle(glow_centers[index], glow_radius, Color(glow_colors[index], GameboxTokens.GAME["board_center_alpha"]))

	var line_color := Color(get_theme_color("font_color", "Label"), GameboxTokens.GAME["board_side_camp_alpha"])
	var center := size * 0.5
	for radius_ratio in [0.34, 0.48, 0.62]:
		draw_arc(center, size.y * radius_ratio, -0.38, PI + 0.38, 72, line_color, 2.0, true)
	for index in 18:
		var x := fmod(float(index * 317 + 89), size.x)
		var y := fmod(float(index * 173 + 47), size.y)
		draw_circle(Vector2(x, y), 1.8, line_color)
