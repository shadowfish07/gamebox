class_name FlightChessDice
extends Control

const GameboxTokens = preload("res://design_system/generated/gamebox_tokens.gd")
const FlightChessBoard = preload("res://games/flight_chess/flight_chess_board.gd")

var value: int:
	get: return _value
	set(next_value): set_value(next_value)

var _pending := false
var _phase := 0.0
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
	if _pending:
		draw_arc(rect.get_center(),rect.size.x*0.23,_phase,_phase+PI*1.5,36,get_theme_color("pip_color", "FlightChessDice"),rect.size.x*0.045,true)
	elif _value == 0:
		_draw_idle_mark(rect)
	else:
		_draw_pips(rect)


func _draw_idle_mark(rect: Rect2) -> void:
	var center := rect.get_center()
	var ink := get_theme_color("outline_color", "FlightChessDice")
	var unit := rect.size.x / 64.0
	var lines := [[Vector2(0,-20),Vector2(18,-10),Vector2(18,10),Vector2(0,20),Vector2(-18,10),Vector2(-18,-10),Vector2(0,-20)],[Vector2(-18,-10),Vector2(0,0),Vector2(18,-10)],[Vector2(0,0),Vector2(0,20)]]
	for line in lines:
		var points := PackedVector2Array()
		for point in line:
			points.append(center+point*unit)
		draw_polyline(points,ink,2*unit,true)
	for point in [Vector2(0,-11),Vector2(-10,-2),Vector2(-6,10),Vector2(7,1),Vector2(12,-2),Vector2(7,11)]:
		draw_circle(center+point*unit,1.7*unit,ink)


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


func set_pending(pending: bool) -> void:
	_pending = pending
	set_process(pending)
	queue_redraw()


func _process(delta: float) -> void:
	_phase = fmod(_phase+delta*TAU,TAU)
	queue_redraw()
