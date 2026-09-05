class_name FlightChessBoard
extends Control

signal piece_pressed(color: String, index: int)

const GameboxTokens = preload("res://design_system/generated/gamebox_tokens.gd")

const BOARD_UNITS := 600.0
const LOCAL_PADDING := 0.0
const MIN_LANE_CLEARANCE := 40.0
const LAUNCH_EDGE_CLEARANCE := 28.0
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
	Vector2(78, 204), Vector2(111, 190), Vector2(142, 190), Vector2(176, 202),
	Vector2(202, 176), Vector2(190, 142), Vector2(190, 111), Vector2(204, 78),
	Vector2(237, 63), Vector2(268.5, 63), Vector2(300, 54), Vector2(331.5, 63),
	Vector2(363, 63), Vector2(396, 78), Vector2(410, 111), Vector2(410, 142),
	Vector2(398, 176), Vector2(424, 202), Vector2(458, 190), Vector2(489, 190),
	Vector2(522, 204), Vector2(537, 237), Vector2(537, 268.5), Vector2(546, 300),
	Vector2(537, 331.5), Vector2(537, 363), Vector2(522, 396), Vector2(489, 410),
	Vector2(458, 410), Vector2(424, 398), Vector2(398, 424), Vector2(410, 458),
	Vector2(410, 489), Vector2(396, 522), Vector2(363, 537), Vector2(331.5, 537),
	Vector2(300, 546), Vector2(268.5, 537), Vector2(237, 537), Vector2(204, 522),
	Vector2(190, 489), Vector2(190, 458), Vector2(202, 424), Vector2(176, 398),
	Vector2(142, 410), Vector2(111, 410), Vector2(78, 396), Vector2(63, 363),
	Vector2(63, 331.5), Vector2(54, 300), Vector2(63, 268.5), Vector2(63, 237),
]

const BASE_ROUTE_CELL_POLYGONS := [
	[Vector2(32, 221), Vector2(95, 221), Vector2(95, 158)],
	[Vector2(95, 158), Vector2(126.5, 158), Vector2(126.5, 221), Vector2(95, 221)],
	[Vector2(126.5, 158), Vector2(158, 158), Vector2(158, 221), Vector2(126.5, 221)],
	[Vector2(158, 158), Vector2(158, 221), Vector2(221, 221)],
	[Vector2(158, 158), Vector2(221, 158), Vector2(221, 221)],
	[Vector2(158, 126.5), Vector2(221, 126.5), Vector2(221, 158), Vector2(158, 158)],
	[Vector2(158, 95), Vector2(221, 95), Vector2(221, 126.5), Vector2(158, 126.5)],
	[Vector2(158, 95), Vector2(221, 95), Vector2(221, 32)],
	[Vector2(221, 32), Vector2(252.5, 32), Vector2(252.5, 95), Vector2(221, 95)],
	[Vector2(252.5, 32), Vector2(284, 32), Vector2(284, 95), Vector2(252.5, 95)],
	[Vector2(284, 63), Vector2(300, 38), Vector2(316, 63), Vector2(300, 79)],
	[Vector2(316, 32), Vector2(347.5, 32), Vector2(347.5, 95), Vector2(316, 95)],
	[Vector2(347.5, 32), Vector2(379, 32), Vector2(379, 95), Vector2(347.5, 95)],
]

const HOME_STRETCHES := {
	"yellow": [Vector2(114, 300), Vector2(146, 300), Vector2(178, 300), Vector2(210, 300), Vector2(242, 300), Vector2(270, 300)],
	"green": [Vector2(300, 114), Vector2(300, 146), Vector2(300, 178), Vector2(300, 210), Vector2(300, 242), Vector2(300, 270)],
	"red": [Vector2(486, 300), Vector2(454, 300), Vector2(422, 300), Vector2(390, 300), Vector2(358, 300), Vector2(330, 300)],
	"blue": [Vector2(300, 486), Vector2(300, 454), Vector2(300, 422), Vector2(300, 390), Vector2(300, 358), Vector2(300, 330)],
}

const HANGAR_RECTS := {
	"yellow": Rect2(32, 32, 126, 126),
	"green": Rect2(442, 32, 126, 126),
	"red": Rect2(442, 442, 126, 126),
	"blue": Rect2(32, 442, 126, 126),
}

const HANGAR_SLOTS := {
	"yellow": [Vector2(63, 63), Vector2(126, 63), Vector2(63, 126), Vector2(126, 126)],
	"green": [Vector2(474, 63), Vector2(537, 63), Vector2(474, 126), Vector2(537, 126)],
	"red": [Vector2(474, 474), Vector2(537, 474), Vector2(474, 537), Vector2(537, 537)],
	"blue": [Vector2(63, 474), Vector2(126, 474), Vector2(63, 537), Vector2(126, 537)],
}

const LAUNCH_POINTS := {
	"yellow": Vector2(54, 174),
	"green": Vector2(426, 54),
	"red": Vector2(546, 426),
	"blue": Vector2(174, 546),
}

const FINISH_POINTS := {
	"yellow": Vector2(288, 300),
	"green": Vector2(300, 288),
	"red": Vector2(312, 300),
	"blue": Vector2(300, 312),
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
	"yellow": [Vector2(418, 236), Vector2(418, 364)],
	"green": [Vector2(364, 418), Vector2(236, 418)],
	"red": [Vector2(182, 364), Vector2(182, 236)],
	"blue": [Vector2(236, 182), Vector2(364, 182)],
}

var selected_piece_index: int:
	get: return _selected_piece_index
	set(_value): pass
var selectable_piece_indices: Array:
	get: return _selectable_piece_indices.duplicate()
	set(_value): pass
var pressed_piece_index: int:
	get: return _pressed_piece_index
	set(_value): pass

var _paper: Color = BOARD_PAPER
var _route_preview: Array = []
var _captured_flights: Array = []
var _impact := {}
var _pending_index := -1
var _bounce := {}
var _bounce_tween: Tween
var _pieces := {}
var _selectable_color := ""
var _selectable_piece_indices: Array = []
var _selected_piece_index := -1
var _pressed_piece_index := -1
var _pressed_pointer_id := -2
var _interactable := false
var _selection_phase := 0.0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	set_process(false)


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


static func route_color(index: int) -> String:
	if index < 0 or index >= MAIN_PATH.size():
		return ""
	return ROUTE_COLOR_CYCLE[index % ROUTE_COLOR_CYCLE.size()]


static func route_cell_polygon(index: int) -> PackedVector2Array:
	if index < 0 or index >= MAIN_PATH.size():
		return PackedVector2Array()
	var turns := index / 13
	var polygon := PackedVector2Array()
	for source_point in BASE_ROUTE_CELL_POLYGONS[index % 13]:
		var point: Vector2 = source_point
		for _turn in turns:
			point = Vector2(BOARD_UNITS - point.y, point.x)
		polygon.append(point)
	return polygon


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
	_pressed_piece_index = -1
	_pressed_pointer_id = -2
	_interactable = interactable and not _selectable_piece_indices.is_empty()
	mouse_filter = Control.MOUSE_FILTER_STOP if _interactable else Control.MOUSE_FILTER_IGNORE
	set_process(_interactable)
	queue_redraw()
	return true


func cancel_home_bounce() -> void:
	if _bounce_tween != null:
		_bounce_tween.kill()
		_bounce_tween = null
	_bounce.clear()
	_captured_flights.clear()
	_impact.clear()
	queue_redraw()


func board_rect() -> Rect2:
	var side := maxf(0.0, minf(size.x, size.y) - LOCAL_PADDING * 2.0)
	return Rect2((size - Vector2(side, side)) * 0.5, Vector2(side, side))


func piece_center(color: String, index: int) -> Vector2:
	if not _pieces.has(color) or index < 0 or index >= (_pieces[color] as Array).size():
		return Vector2(INF, INF)
	var piece: Dictionary = (_pieces[color] as Array)[index]
	return _logical_to_pixel(_logical_piece_center(color, piece))


func piece_stack_size(color: String, index: int) -> int:
	if not _pieces.has(color) or index < 0 or index >= (_pieces[color] as Array).size():
		return 0
	return _stack_members(color, (_pieces[color] as Array)[index]).size()


func piece_at_pixel(pixel: Vector2) -> Dictionary:
	if not pixel.is_finite() or _selectable_color.is_empty() or not board_rect().has_point(pixel):
		return EMPTY_HIT
	var nearest_index := -1
	var nearest_distance := INF
	var radius := maxf(float(GameboxTokens.COMPONENT["minimum_touch_target"]), board_rect().size.x / BOARD_UNITS * 32.0)
	for index in _selectable_piece_indices:
		var distance := pixel.distance_squared_to(piece_center(_selectable_color, index))
		if distance < nearest_distance:
			nearest_distance = distance
			nearest_index = index
	return {"color": _selectable_color, "index": nearest_index} if nearest_index >= 0 and nearest_distance <= radius * radius else EMPTY_HIT


func _gui_input(event: InputEvent) -> void:
	if not _interactable:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_begin_press(event.position, -1)
		else:
			_finish_press(event.position, -1, false)
	elif event is InputEventScreenTouch:
		if event.pressed:
			_begin_press(event.position, event.index)
		elif event.index == _pressed_pointer_id:
			_finish_press(event.position, event.index, event.canceled)


func _begin_press(position: Vector2, pointer_id: int) -> void:
	if _pressed_pointer_id != -2:
		return
	var hit := piece_at_pixel(position)
	if hit.is_empty():
		return
	_pressed_pointer_id = pointer_id
	_pressed_piece_index = hit["index"]
	queue_redraw()
	accept_event()


func _finish_press(position: Vector2, pointer_id: int, canceled: bool) -> void:
	if pointer_id != _pressed_pointer_id:
		return
	var pressed_index := _pressed_piece_index
	_pressed_pointer_id = -2
	_pressed_piece_index = -1
	queue_redraw()
	var hit := piece_at_pixel(position)
	if not canceled and not hit.is_empty() and hit["index"] == pressed_index:
		piece_pressed.emit(hit["color"], hit["index"])
	accept_event()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED or what == NOTIFICATION_THEME_CHANGED:
		queue_redraw()


func _process(delta: float) -> void:
	var cycle_seconds := float(GameboxTokens.MOTION["slow"]) * 4.0 / 1000.0
	_selection_phase = fmod(_selection_phase + delta / cycle_seconds * TAU, TAU)
	queue_redraw()


func _draw() -> void:
	_paper = BOARD_PAPER.lerp(BOARD_INK,0.10) if get_theme_color("font_color","Label").get_luminance() > 0.5 else BOARD_PAPER
	var rect := board_rect()
	if rect.size.x <= 0.0:
		return
	_draw_board_surface(rect)
	for color in PLAYER_ORDER:
		_draw_hangar(color)
	for color in PLAYER_ORDER:
		_draw_shortcut(color)
	_draw_main_route()
	_draw_finish_center()
	for color in PLAYER_ORDER:
		_draw_home_lane_slots(color)
	for color in PLAYER_ORDER:
		_draw_launch_pad(color)
	_draw_route_preview()
	for color in PLAYER_ORDER:
		_draw_color_pieces(color)
	if not _bounce.is_empty():
		_draw_piece(_logical_to_pixel(_bounce["point"]), 18.0 * _scale() * _bounce.get("scale",1.0), _bounce["color"], _bounce.get("scale",1.0))
		if _bounce.get("scale",1.0) > 0.5:
			_draw_piece_number(_logical_to_pixel(_bounce.point),_bounce.index)
	for flight in _captured_flights:
		_draw_piece(_logical_to_pixel(flight.point),18*_scale(),flight.color)
		_draw_piece_number(_logical_to_pixel(flight.point),flight.index)
	if not _impact.is_empty():
		var opacity: float = 1.0-_impact.phase
		draw_arc(_logical_to_pixel(_impact.point), (12+20*_impact.phase)*_scale(),0,TAU,40,Color(PLAYER_COLORS[_impact.color],opacity),4*_scale(),true)


func _draw_board_surface(rect: Rect2) -> void:
	var scale := rect.size.x / BOARD_UNITS
	_draw_rounded_rect(
		Rect2(rect.position + Vector2(0.0, 3.0) * scale, rect.size),
		Color(BOARD_INK, GameboxTokens.GAME["piece_shadow_alpha"]),
		13.0 * scale,
		BOARD_INK,
		0.0,
	)
	_draw_rounded_rect(rect, _paper, 16.0 * scale, Color(BOARD_INK,GameboxTokens.GAME["piece_shadow_alpha"]), maxf(1.0, scale))
	_draw_rounded_rect(rect.grow(-14 * scale), _paper, 20 * scale, Color(BOARD_INK, GameboxTokens.GAME["board_target_camp_alpha"]), scale, false)


func _draw_hangar(color: String) -> void:
	var logical_rect: Rect2 = HANGAR_RECTS[color]
	var pixel_rect := _logical_rect_to_pixel(logical_rect)
	var scale := _scale()
	var fill: Color = PLAYER_COLORS[color]
	if color in ["blue", "green"]:
		fill = _paper.lerp(fill, 0.35)
	_draw_rounded_rect(pixel_rect, fill, 20 * scale, PLAYER_COLORS[color], 0)
	for logical_center in HANGAR_SLOTS[color]:
		draw_circle(_logical_to_pixel(logical_center), 23 * scale, _paper)
	var label := "黄方" if color == "yellow" else "红方" if color == "red" else "空席"
	var point := Vector2(logical_rect.get_center().x, 23 if color in ["yellow", "green"] else 590)
	_draw_board_text(point, label, 11, BOARD_INK)


func _draw_main_route() -> void:
	for index in MAIN_PATH.size():
		_draw_route_tile(index)


func _draw_home_lane_slots(color: String) -> void:
	var scale := _scale()
	var direction: Vector2 = (FINISH_POINTS[color] - HOME_STRETCHES[color][0]).normalized()
	var normal := Vector2(-direction.y, direction.x)
	for point in HOME_STRETCHES[color]:
		var center := _logical_to_pixel(point)
		_draw_rounded_rect(Rect2(center-Vector2(15,15)*scale,Vector2(30,30)*scale),PLAYER_COLORS[color],3*scale,_paper,2*scale)
		var ink: Color = PLAYER_DARK[color] if color == "yellow" else _paper
		draw_polyline(PackedVector2Array([center-direction*3*scale-normal*5*scale, center+direction*2*scale,center-direction*3*scale+normal*5*scale]),ink,2*scale,true)


func _draw_route_tile(index: int) -> void:
	var scale := _scale()
	var logical_center: Vector2 = MAIN_PATH[index]
	var color: Color = PLAYER_COLORS[route_color(index)]
	var center := _logical_to_pixel(logical_center)
	var tile := PackedVector2Array()
	for point in route_cell_polygon(index):
		tile.append(_logical_to_pixel(point))
	draw_colored_polygon(tile, color)
	draw_polyline(
		PackedVector2Array(Array(tile) + [tile[0]]),
		_paper,
		maxf(0.7, 2.0 * scale),
		true,
	)


func _draw_shortcut(color: String) -> void:
	var line: Array = SHORTCUT_LINES[color]
	var from := _logical_to_pixel(line[0])
	var to := _logical_to_pixel(line[1])
	var delta := to - from
	var dash_count := 6
	for index in dash_count:
		var start_t := float(index) / float(dash_count)
		var end_t := minf(1.0, start_t + 0.08)
		draw_line(from + delta * start_t, from + delta * end_t, Color(PLAYER_COLORS[color], GameboxTokens.GAME["pending_overlay_alpha"]), maxf(3.0, 5.0 * _scale()), true)
	var direction := delta.normalized()
	var perpendicular := Vector2(-direction.y, direction.x)
	var arrow_size := 12.0 * _scale()
	var points := PackedVector2Array([
		to,
		to - direction * arrow_size + perpendicular * arrow_size * 0.62,
		to - direction * arrow_size + -perpendicular * arrow_size * 0.62,
	])
	draw_colored_polygon(points, Color(PLAYER_COLORS[color], GameboxTokens.GAME["pending_overlay_alpha"]))


func _draw_finish_center() -> void:
	for color in PLAYER_ORDER:
		var turns: int = PLAYER_ORDER.find(color)
		var points := PackedVector2Array()
		for source in [Vector2(300,300),Vector2(279,279),Vector2(279,321)]:
			var point: Vector2 = source
			for _turn in turns:
				point = Vector2(600-point.y,point.x)
			points.append(_logical_to_pixel(point))
		draw_colored_polygon(points,PLAYER_COLORS[color])
	_draw_board_text(Vector2(300,355), "顺时针 · 精确归家", 10, Color(BOARD_INK,GameboxTokens.GAME["pending_overlay_alpha"]))


func _draw_launch_pad(color: String) -> void:
	var center := _logical_to_pixel(LAUNCH_POINTS[color])
	var rotation := _plane_rotation(color)
	var points := PackedVector2Array()
	for point in [Vector2(-5,-11),Vector2(18,7),Vector2(-12,14)]:
		points.append(center+point.rotated(rotation)*_scale())
	draw_colored_polygon(points,PLAYER_COLORS[color])
	draw_polyline(PackedVector2Array(Array(points)+[points[0]]),_paper,2*_scale(),true)


func _draw_color_pieces(color: String) -> void:
	if not _pieces.has(color):
		return
	var color_pieces: Array = _pieces[color]
	for index in color_pieces.size():
		if _presentation_hides(color,index):
			continue
		var piece: Dictionary = color_pieces[index]
		if piece.zone == "finished":
			continue
		var members := _stack_members(color, piece)
		if index != members[0]:
			continue
		var center := _logical_to_pixel(_logical_piece_center(color, piece))
		var selectable := false
		for member in members:
			selectable = selectable or (color == _selectable_color and _selectable_piece_indices.has(member))
		var selected := selectable and members.has(_selected_piece_index)
		var pressed := selectable and members.has(_pressed_piece_index)
		var radius := 18.0 * _scale()
		if selectable:
			var pulse := 1.0 + sin(_selection_phase) * 0.06
			draw_circle(center, radius * 1.42 * pulse, Color(PLAYER_COLORS[color], GameboxTokens.GAME["board_target_fill_alpha"]))
			draw_arc(center, radius * 1.28 * pulse, 0.0, TAU, 32, PLAYER_COLORS[color], maxf(2.0, 3.5 * _scale()), true)
		if selected:
			draw_circle(center + Vector2(0.0, 4.0 * _scale()), radius * 1.12, Color(BOARD_INK, GameboxTokens.GAME["board_target_fill_alpha"]))
			radius *= 1.08
		if pressed:
			radius *= 0.84
		_draw_stack_layers(center, radius, members.size(), color)
		_draw_piece(center, radius, color)
		_draw_piece_number(center, index)
		if _pending_index >= 0 and members.has(_pending_index):
			for dash in 12:
				draw_arc(center,radius*1.45,dash*TAU/12.0,dash*TAU/12.0+0.25,6,PLAYER_DARK[color],3*_scale(),true)
		if selected:
			draw_arc(center, radius * 1.18, 0.0, TAU, 32, SLOT_COLOR, maxf(2.0, 2.5 * _scale()), true)
		if members.size() > 1 and index == members[0]:
			_draw_stack_badge(center, members.size(), color)


func _draw_stack_layers(center: Vector2, radius: float, count: int, color: String) -> void:
	for layer in range(mini(count - 1, 2), 0, -1):
		var layer_center := center + Vector2(4.0, 4.0) * _scale() * layer
		draw_circle(layer_center, radius, PLAYER_DARK[color])
		draw_circle(layer_center, radius * 0.88, PLAYER_COLORS[color])


func _draw_stack_badge(center: Vector2, count: int, color: String) -> void:
	var scale := _scale()
	var badge_center := center + Vector2(18.0, -18.0) * scale
	var radius := maxf(8.0, 10.0 * scale)
	draw_circle(badge_center, radius, PLAYER_DARK[color])
	draw_arc(badge_center, radius, 0.0, TAU, 20, SLOT_COLOR, maxf(1.0, 1.5 * scale), true)
	var font := get_theme_default_font()
	var font_size := maxi(12, roundi(12.0 * scale))
	var label := str(count)
	var text_size := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size)
	draw_string(font, badge_center + Vector2(-text_size.x * 0.5, text_size.y * 0.35), label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, SLOT_COLOR)


func _draw_piece(center: Vector2, radius: float, color: String, opacity: float = 1.0) -> void:
	draw_circle(center + Vector2(0.0, radius * 0.16), radius, Color(BOARD_INK, GameboxTokens.GAME["piece_shadow_alpha"] * opacity))
	draw_circle(center, radius, Color(_paper,opacity))
	draw_circle(center, radius * 0.86, Color(PLAYER_COLORS[color],opacity))
	_draw_plane(center, radius * 0.68, Color(PLAYER_DARK[color] if color == "yellow" else SLOT_COLOR,opacity), _plane_rotation(color))


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


func _stack_members(color: String, piece: Dictionary) -> Array:
	var result: Array = []
	var color_pieces: Array = _pieces[color]
	for index in color_pieces.size():
		if _presentation_hides(color,index):
			continue
		var candidate: Dictionary = color_pieces[index]
		if candidate["zone"] == piece["zone"] and candidate["index"] == piece["index"]:
			result.append(index)
	return result


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


func _draw_rounded_rect(rect: Rect2, fill: Color, radius: float, border: Color, border_width: float, filled: bool = true) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.draw_center = filled
	if border_width > 0.0:
		style.border_color = border
		var width := roundi(border_width)
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


func _draw_piece_number(center: Vector2, index: int) -> void:
	var point := center + Vector2(14,14)*_scale()
	draw_circle(point,9*_scale(),_paper)
	var font_size := maxi(1,roundi(13*_scale()))
	var font := get_theme_default_font()
	var width := font.get_string_size(str(index+1),HORIZONTAL_ALIGNMENT_LEFT,-1,font_size).x
	draw_string(font,point+Vector2(-width/2,5*_scale()),str(index+1),HORIZONTAL_ALIGNMENT_LEFT,-1,font_size,BOARD_INK)


func _draw_board_text(point: Vector2, text: String, font_size: int, color: Color) -> void:
	var font := get_theme_default_font()
	var scaled_size := maxi(1,roundi(font_size*_scale()))
	var width := font.get_string_size(text,HORIZONTAL_ALIGNMENT_LEFT,-1,scaled_size).x
	draw_string(font,_logical_to_pixel(point)-Vector2(width/2,0),text,HORIZONTAL_ALIGNMENT_LEFT,-1,scaled_size,color)


func _presentation_hides(color: String, index: int) -> bool:
	if _bounce.get("color") == color and _bounce.get("index") == index:
		return true
	for flight in _captured_flights:
		if flight.color == color and flight.index == index:
			return true
	return false


func set_route_preview(segments: Array, pending_index: int = -1) -> void:
	_route_preview = segments
	_pending_index = pending_index
	queue_redraw()


func _draw_route_preview() -> void:
	for segment in _route_preview:
		draw_dashed_line(_logical_to_pixel(segment.from),_logical_to_pixel(segment.to), Color(PLAYER_DARK.get(_selectable_color, BOARD_INK),GameboxTokens.GAME["pending_overlay_alpha"]),3*_scale(),8*_scale(),true,true)
	if not _route_preview.is_empty():
		var point: Vector2 = _route_preview[-1].to
		draw_arc(_logical_to_pixel(point),24*_scale(),0,TAU,40,PLAYER_DARK.get(_selectable_color,BOARD_INK),3*_scale(),true)


func animate_move(color: String, index: int, segments: Array, captured: Array, finished: bool) -> Tween:
	cancel_home_bounce()
	_route_preview.clear()
	_bounce = {"color":color,"index":index,"point":segments[0].from,"scale":1.0}
	var enemy := "yellow" if color == "red" else "red"
	var target: Vector2 = segments[-1].to
	for captured_index in captured:
		_captured_flights.append({"color":enemy,"index":captured_index,"point":target})
	_bounce_tween = create_tween()
	for segment in segments:
		_bounce_tween.tween_method(func(t: float) -> void:
			_bounce.point = segment.from.lerp(segment.to,t)+Vector2(0,-sin(t*PI)*segment.lift)
			queue_redraw()
		,0.0,1.0,segment.duration).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_bounce_tween.tween_method(func(t: float) -> void:
		_impact = {"point":target,"color":color,"phase":t}
		queue_redraw()
	,0.0,1.0,0.22)
	if not captured.is_empty():
		_bounce_tween.tween_method(func(t: float) -> void:
			for flight in _captured_flights:
				flight.point = target.lerp(HANGAR_SLOTS[enemy][flight.index],t)+Vector2(0,-sin(t*PI)*40)
			queue_redraw()
		,0.0,1.0,0.42)
	if finished:
		_bounce_tween.tween_method(func(t: float) -> void:
			_bounce.scale = 1-t
			queue_redraw()
		,0.0,1.0,0.36)
	_bounce_tween.tween_callback(func() -> void:
		_bounce.clear()
		_captured_flights.clear()
		_impact.clear()
		queue_redraw()
	)
	return _bounce_tween
