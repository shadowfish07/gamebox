class_name FlightChessBoard
extends Control

signal piece_pressed(color: String, index: int)

const GameboxTokens = preload("res://design_system/generated/gamebox_tokens.gd")

const BOARD_UNITS := 600.0
const LOCAL_PADDING := 10.0
const EMPTY_HIT := {}
const PLAYER_ORDER := ["yellow", "green", "red", "blue"]
const ROUTE_COLOR_CYCLE := ["blue", "yellow", "green", "red"]

const PLAYER_COLORS := {
	"yellow": GameboxTokens.GAME["flight_yellow"],
	"green": GameboxTokens.GAME["flight_green"],
	"red": GameboxTokens.GAME["flight_red"],
	"blue": GameboxTokens.GAME["flight_blue"],
}
const PLAYER_DARK := {
	"yellow": GameboxTokens.GAME["flight_yellow_dark"],
	"green": GameboxTokens.GAME["flight_green_dark"],
	"red": GameboxTokens.GAME["flight_red_dark"],
	"blue": GameboxTokens.GAME["flight_blue_dark"],
}
const BOARD_PAPER := GameboxTokens.GAME["flight_board_paper"]
const BOARD_INK := GameboxTokens.GAME["flight_board_ink"]
const SLOT_COLOR := GameboxTokens.GAME["white_piece"]

const MAIN_PATH := [
	Vector2(91, 212), Vector2(122, 198), Vector2(151, 198), Vector2(183, 212),
	Vector2(209, 184), Vector2(195, 150), Vector2(196, 120), Vector2(209, 86),
	Vector2(241, 74), Vector2(270, 74), Vector2(300, 75), Vector2(330, 75),
	Vector2(358, 74), Vector2(390, 86), Vector2(404, 119), Vector2(404, 150),
	Vector2(390, 184), Vector2(416, 212), Vector2(448, 198), Vector2(477, 198),
	Vector2(508, 212), Vector2(519, 244), Vector2(518, 276), Vector2(520, 307),
	Vector2(519, 336), Vector2(519, 366), Vector2(508, 399), Vector2(477, 413),
	Vector2(447, 413), Vector2(416, 400), Vector2(391, 428), Vector2(405, 461),
	Vector2(404, 491), Vector2(390, 526), Vector2(358, 536), Vector2(328, 537),
	Vector2(299, 537), Vector2(270, 537), Vector2(239, 536), Vector2(210, 526),
	Vector2(195, 491), Vector2(196, 460), Vector2(210, 427), Vector2(182, 398),
	Vector2(151, 413), Vector2(122, 413), Vector2(90, 399), Vector2(81, 366),
	Vector2(79, 335), Vector2(80, 305), Vector2(80, 275), Vector2(82, 245),
]

const HOME_STRETCHES := {
	"yellow": [Vector2(93, 305), Vector2(129, 305), Vector2(161, 305), Vector2(195, 305), Vector2(229, 305), Vector2(269, 305)],
	"green": [Vector2(300, 94), Vector2(300, 127), Vector2(300, 162), Vector2(300, 197), Vector2(300, 231), Vector2(300, 271)],
	"red": [Vector2(506, 305), Vector2(470, 305), Vector2(437, 305), Vector2(403, 305), Vector2(369, 305), Vector2(329, 305)],
	"blue": [Vector2(299, 505), Vector2(299, 471), Vector2(300, 438), Vector2(299, 404), Vector2(300, 370), Vector2(299, 331)],
}

const HANGAR_RECTS := {
	"yellow": Rect2(10, 10, 145, 145),
	"green": Rect2(445, 10, 145, 145),
	"red": Rect2(445, 445, 145, 145),
	"blue": Rect2(10, 445, 145, 145),
}

const HANGAR_SLOTS := {
	"yellow": [Vector2(52, 52), Vector2(111, 52), Vector2(52, 111), Vector2(111, 111)],
	"green": [Vector2(487, 52), Vector2(548, 52), Vector2(487, 111), Vector2(548, 111)],
	"red": [Vector2(487, 487), Vector2(548, 487), Vector2(487, 548), Vector2(548, 548)],
	"blue": [Vector2(52, 487), Vector2(111, 487), Vector2(52, 548), Vector2(111, 548)],
}

const LAUNCH_POINTS := {
	"yellow": Vector2(15, 170),
	"green": Vector2(429, 17),
	"red": Vector2(582, 430),
	"blue": Vector2(168, 582),
}

const FINISH_POINTS := {
	"yellow": Vector2(275, 305),
	"green": Vector2(299, 281),
	"red": Vector2(323, 305),
	"blue": Vector2(299, 329),
}

const PATH_STARTS := {"yellow": 0, "green": 13, "red": 26, "blue": 39}
const FINISH_ENTRIES := {"yellow": 49, "green": 10, "red": 23, "blue": 36}
const SHORTCUTS := {
	"yellow": Vector2i(17, 29),
	"green": Vector2i(30, 42),
	"red": Vector2i(43, 3),
	"blue": Vector2i(4, 16),
}
const SHORTCUT_LINES := {
	"yellow": [Vector2(416, 232), Vector2(416, 380)],
	"green": [Vector2(370, 400), Vector2(230, 400)],
	"red": [Vector2(182, 378), Vector2(182, 232)],
	"blue": [Vector2(229, 212), Vector2(370, 212)],
}

var selected_piece_index: int:
	get: return _selected_piece_index
	set(_value): pass
var selectable_piece_indices: Array:
	get: return _selectable_piece_indices.duplicate()
	set(_value): pass

var _pieces := {}
var _selectable_color := ""
var _selectable_piece_indices: Array = []
var _selected_piece_index := -1
var _interactable := false


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE


static func topology() -> Dictionary:
	var stretches := {}
	for color in HOME_STRETCHES:
		stretches[color] = HOME_STRETCHES[color].duplicate()
	return {
		"main_path": MAIN_PATH.duplicate(),
		"home_stretches": stretches,
		"path_starts": PATH_STARTS.duplicate(),
		"finish_entries": FINISH_ENTRIES.duplicate(),
		"shortcuts": SHORTCUTS.duplicate(),
	}


func present(
	pieces: Dictionary,
	selectable_color: String = "",
	selectable_indices: Array = [],
	selected_index: int = -1,
	interactable: bool = false,
) -> bool:
	if not selectable_color.is_empty() and not PLAYER_COLORS.has(selectable_color):
		return false
	var normalized := {}
	for color in pieces:
		if not PLAYER_COLORS.has(color) or not pieces[color] is Array:
			return false
		var color_pieces: Array = pieces[color]
		if color_pieces.size() > 4:
			return false
		var normalized_pieces: Array = []
		for piece in color_pieces:
			if not _valid_piece(piece):
				return false
			normalized_pieces.append((piece as Dictionary).duplicate())
		normalized[color] = normalized_pieces
	var normalized_indices: Array = []
	for index in selectable_indices:
		if typeof(index) != TYPE_INT or index < 0 or not normalized.has(selectable_color) \
			or index >= (normalized[selectable_color] as Array).size() or normalized_indices.has(index):
			return false
		normalized_indices.append(index)
	normalized_indices.sort()
	if selected_index != -1 and not normalized_indices.has(selected_index):
		return false
	_pieces = normalized
	_selectable_color = selectable_color
	_selectable_piece_indices = normalized_indices
	_selected_piece_index = selected_index
	_interactable = interactable and not _selectable_piece_indices.is_empty()
	mouse_filter = Control.MOUSE_FILTER_STOP if _interactable else Control.MOUSE_FILTER_IGNORE
	queue_redraw()
	return true


func board_rect() -> Rect2:
	var side := maxf(0.0, minf(size.x, size.y) - LOCAL_PADDING * 2.0)
	return Rect2((size - Vector2(side, side)) * 0.5, Vector2(side, side))


func piece_center(color: String, index: int) -> Vector2:
	if not _pieces.has(color) or index < 0 or index >= (_pieces[color] as Array).size():
		return Vector2(INF, INF)
	return _logical_to_pixel(_logical_piece_center(color, (_pieces[color] as Array)[index]))


func piece_at_pixel(pixel: Vector2) -> Dictionary:
	if not pixel.is_finite() or _selectable_color.is_empty():
		return EMPTY_HIT
	var radius := board_rect().size.x / BOARD_UNITS * 28.0
	for index in _selectable_piece_indices:
		if pixel.distance_squared_to(piece_center(_selectable_color, index)) <= radius * radius:
			return {"color": _selectable_color, "index": index}
	return EMPTY_HIT


func _gui_input(event: InputEvent) -> void:
	if not _interactable:
		return
	var release_position := Vector2(INF, INF)
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		release_position = event.position
	elif event is InputEventScreenTouch and not event.pressed and not event.canceled:
		release_position = event.position
	if not release_position.is_finite():
		return
	var hit := piece_at_pixel(release_position)
	if not hit.is_empty():
		piece_pressed.emit(hit["color"], hit["index"])
	accept_event()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED or what == NOTIFICATION_THEME_CHANGED:
		queue_redraw()


func _draw() -> void:
	var rect := board_rect()
	if rect.size.x <= 0.0:
		return
	_draw_board_surface(rect)
	for color in PLAYER_ORDER:
		_draw_hangar(color)
	for color in PLAYER_ORDER:
		_draw_shortcut(color)
	_draw_main_route()
	for color in PLAYER_ORDER:
		_draw_home_stretch(color)
	_draw_finish_center()
	for color in PLAYER_ORDER:
		_draw_launch_pad(color)
	for color in PLAYER_ORDER:
		_draw_color_pieces(color)


func _draw_board_surface(rect: Rect2) -> void:
	draw_rect(rect, BOARD_PAPER, true)
	var scale := rect.size.x / BOARD_UNITS
	for index in 84:
		var logical := Vector2(fmod(float(index * 83 + 31), 590.0) + 5.0, fmod(float(index * 47 + 19), 590.0) + 5.0)
		draw_circle(_logical_to_pixel(logical), maxf(0.7, scale * 0.8), Color(BOARD_INK, GameboxTokens.GAME["board_side_camp_alpha"]))
	draw_rect(rect, BOARD_INK, false, maxf(2.0, scale * 4.0), true)


func _draw_hangar(color: String) -> void:
	var logical_rect: Rect2 = HANGAR_RECTS[color]
	var pixel_rect := _logical_rect_to_pixel(logical_rect)
	_draw_rounded_rect(pixel_rect, PLAYER_COLORS[color], 7.0 * _scale(), PLAYER_DARK[color], 2.5 * _scale())
	for logical_center in HANGAR_SLOTS[color]:
		var center := _logical_to_pixel(logical_center)
		draw_circle(center, 18.0 * _scale(), SLOT_COLOR)
		draw_arc(center, 18.0 * _scale(), 0.0, TAU, 28, PLAYER_DARK[color], maxf(1.2, 1.8 * _scale()), true)


func _draw_main_route() -> void:
	for index in MAIN_PATH.size():
		_draw_route_tile(MAIN_PATH[index], PLAYER_COLORS[ROUTE_COLOR_CYCLE[index % 4]])


func _draw_home_stretch(color: String) -> void:
	for point in HOME_STRETCHES[color]:
		_draw_route_tile(point, PLAYER_COLORS[color])


func _draw_route_tile(logical_center: Vector2, color: Color) -> void:
	var scale := _scale()
	var center := _logical_to_pixel(logical_center)
	var rect := Rect2(center - Vector2(15.0, 14.0) * scale, Vector2(30.0, 28.0) * scale)
	_draw_rounded_rect(rect, color, 4.5 * scale, BOARD_INK, maxf(1.0, 1.3 * scale))
	draw_circle(center, 8.5 * scale, SLOT_COLOR)
	draw_arc(center, 8.5 * scale, 0.0, TAU, 20, Color(BOARD_INK, GameboxTokens.GAME["board_hole_alpha"]), maxf(0.8, scale), true)


func _draw_shortcut(color: String) -> void:
	var line: Array = SHORTCUT_LINES[color]
	var from := _logical_to_pixel(line[0])
	var to := _logical_to_pixel(line[1])
	var delta := to - from
	var dash_count := 7
	for index in dash_count:
		var start_t := float(index) / float(dash_count)
		var end_t := minf(1.0, start_t + 0.075)
		draw_line(from + delta * start_t, from + delta * end_t, PLAYER_COLORS[color], maxf(4.0, 8.0 * _scale()), true)
	var direction := delta.normalized()
	var perpendicular := Vector2(-direction.y, direction.x)
	var arrow_size := 18.0 * _scale()
	var points := PackedVector2Array([
		to,
		to - direction * arrow_size + perpendicular * arrow_size * 0.62,
		to - direction * arrow_size + -perpendicular * arrow_size * 0.62,
	])
	draw_colored_polygon(points, PLAYER_COLORS[color])


func _draw_finish_center() -> void:
	var polygons := {
		"yellow": [Vector2(269, 277), Vector2(299, 305), Vector2(269, 333), Vector2(239, 305)],
		"green": [Vector2(271, 275), Vector2(299, 245), Vector2(327, 275), Vector2(299, 305)],
		"red": [Vector2(329, 277), Vector2(359, 305), Vector2(329, 333), Vector2(299, 305)],
		"blue": [Vector2(271, 335), Vector2(299, 305), Vector2(327, 335), Vector2(299, 365)],
	}
	for color in PLAYER_ORDER:
		var points := PackedVector2Array()
		for point in polygons[color]:
			points.append(_logical_to_pixel(point))
		draw_colored_polygon(points, PLAYER_COLORS[color])
		draw_polyline(PackedVector2Array(Array(points) + [points[0]]), BOARD_INK, maxf(1.0, 1.5 * _scale()), true)
	draw_circle(_logical_to_pixel(Vector2(299, 305)), 8.0 * _scale(), SLOT_COLOR)


func _draw_launch_pad(color: String) -> void:
	var center := _logical_to_pixel(LAUNCH_POINTS[color])
	var radius := 18.0 * _scale()
	draw_circle(center, radius, SLOT_COLOR)
	draw_arc(center, radius, 0.0, TAU, 28, PLAYER_COLORS[color], maxf(2.0, 4.0 * _scale()), true)
	_draw_plane(center, radius * 0.7, PLAYER_COLORS[color], _plane_rotation(color))


func _draw_color_pieces(color: String) -> void:
	if not _pieces.has(color):
		return
	var color_pieces: Array = _pieces[color]
	for index in color_pieces.size():
		var center := piece_center(color, index)
		var selectable := color == _selectable_color and _selectable_piece_indices.has(index)
		var selected := selectable and index == _selected_piece_index
		var radius := 18.0 * _scale()
		if selectable:
			draw_circle(center, radius * 1.42, Color(PLAYER_COLORS[color], GameboxTokens.GAME["board_target_fill_alpha"]))
			draw_arc(center, radius * 1.28, 0.0, TAU, 32, PLAYER_COLORS[color], maxf(2.0, 3.5 * _scale()), true)
		if selected:
			draw_circle(center + Vector2(0.0, 4.0 * _scale()), radius * 1.12, Color(BOARD_INK, GameboxTokens.GAME["board_target_fill_alpha"]))
			radius *= 1.08
		_draw_piece(center, radius, color)


func _draw_piece(center: Vector2, radius: float, color: String) -> void:
	draw_circle(center + Vector2(0.0, radius * 0.16), radius, Color(BOARD_INK, GameboxTokens.GAME["piece_shadow_alpha"]))
	draw_circle(center, radius, PLAYER_DARK[color])
	draw_circle(center, radius * 0.88, PLAYER_COLORS[color])
	_draw_plane(center, radius * 0.68, SLOT_COLOR, _plane_rotation(color))


func _draw_plane(center: Vector2, radius: float, color: Color, rotation: float) -> void:
	var source := [
		Vector2(0.92, 0.0), Vector2(0.2, -0.16), Vector2(-0.14, -0.78),
		Vector2(-0.36, -0.78), Vector2(-0.22, -0.13), Vector2(-0.74, -0.34),
		Vector2(-0.88, -0.18), Vector2(-0.42, 0.0), Vector2(-0.88, 0.18),
		Vector2(-0.74, 0.34), Vector2(-0.22, 0.13), Vector2(-0.36, 0.78),
		Vector2(-0.14, 0.78), Vector2(0.2, 0.16),
	]
	var points := PackedVector2Array()
	for point in source:
		points.append(center + (point as Vector2).rotated(rotation) * radius)
	draw_colored_polygon(points, color)


func _logical_piece_center(color: String, piece: Dictionary) -> Vector2:
	var zone := str(piece["zone"])
	var index := int(piece["index"])
	match zone:
		"hangar": return HANGAR_SLOTS[color][index]
		"launch": return LAUNCH_POINTS[color]
		"main": return MAIN_PATH[index]
		"home": return HOME_STRETCHES[color][index]
		"finished": return FINISH_POINTS[color]
	return Vector2(INF, INF)


static func _valid_piece(piece: Variant) -> bool:
	if not piece is Dictionary or not piece.has("zone") or not piece.has("index") or typeof(piece["index"]) != TYPE_INT:
		return false
	var zone := str(piece["zone"])
	var index: int = piece["index"]
	match zone:
		"hangar": return index >= 0 and index < 4
		"launch", "finished": return index == 0
		"main": return index >= 0 and index < 52
		"home": return index >= 0 and index < 6
	return false


func _logical_to_pixel(logical: Vector2) -> Vector2:
	var rect := board_rect()
	return rect.position + logical / BOARD_UNITS * rect.size


func _logical_rect_to_pixel(logical: Rect2) -> Rect2:
	return Rect2(_logical_to_pixel(logical.position), logical.size * _scale())


func _scale() -> float:
	return board_rect().size.x / BOARD_UNITS


static func _plane_rotation(color: String) -> float:
	match color:
		"green": return PI * 0.5
		"red": return PI
		"blue": return -PI * 0.5
	return 0.0


func _draw_rounded_rect(rect: Rect2, fill: Color, radius: float, border: Color, border_width: float) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	var width := maxi(1, roundi(border_width))
	style.border_width_left = width
	style.border_width_top = width
	style.border_width_right = width
	style.border_width_bottom = width
	var corner := maxi(1, roundi(radius))
	style.corner_radius_top_left = corner
	style.corner_radius_top_right = corner
	style.corner_radius_bottom_right = corner
	style.corner_radius_bottom_left = corner
	draw_style_box(style, rect)
