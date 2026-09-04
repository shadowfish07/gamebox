class_name FlightChessBoard
extends Control

signal piece_pressed(color: String, index: int)

const GameboxTokens = preload("res://design_system/generated/gamebox_tokens.gd")

const BOARD_UNITS := 600.0
const LOCAL_PADDING := 10.0
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
	Vector2(84, 210), Vector2(118, 194), Vector2(150, 194), Vector2(182, 210),
	Vector2(210, 182), Vector2(194, 150), Vector2(194, 118), Vector2(210, 84),
	Vector2(242, 70), Vector2(271, 70), Vector2(300, 70), Vector2(329, 70),
	Vector2(358, 70), Vector2(390, 84), Vector2(406, 118), Vector2(406, 150),
	Vector2(390, 182), Vector2(418, 210), Vector2(450, 194), Vector2(482, 194),
	Vector2(516, 210), Vector2(530, 242), Vector2(530, 271), Vector2(530, 300),
	Vector2(530, 329), Vector2(530, 358), Vector2(516, 390), Vector2(482, 406),
	Vector2(450, 406), Vector2(418, 390), Vector2(390, 418), Vector2(406, 450),
	Vector2(406, 482), Vector2(390, 516), Vector2(358, 530), Vector2(329, 530),
	Vector2(300, 530), Vector2(271, 530), Vector2(242, 530), Vector2(210, 516),
	Vector2(194, 482), Vector2(194, 450), Vector2(210, 418), Vector2(182, 390),
	Vector2(150, 406), Vector2(118, 406), Vector2(84, 390), Vector2(70, 358),
	Vector2(70, 329), Vector2(70, 300), Vector2(70, 271), Vector2(70, 242),
]

const HOME_STRETCHES := {
	"yellow": [Vector2(114, 300), Vector2(146, 300), Vector2(178, 300), Vector2(210, 300), Vector2(242, 300), Vector2(270, 300)],
	"green": [Vector2(300, 114), Vector2(300, 146), Vector2(300, 178), Vector2(300, 210), Vector2(300, 242), Vector2(300, 270)],
	"red": [Vector2(486, 300), Vector2(454, 300), Vector2(422, 300), Vector2(390, 300), Vector2(358, 300), Vector2(330, 300)],
	"blue": [Vector2(300, 486), Vector2(300, 454), Vector2(300, 422), Vector2(300, 390), Vector2(300, 358), Vector2(300, 330)],
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
	"yellow": Vector2(32, 174),
	"green": Vector2(426, 32),
	"red": Vector2(568, 426),
	"blue": Vector2(174, 568),
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
	var rect := board_rect()
	if rect.size.x <= 0.0:
		return
	_draw_board_surface(rect)
	for color in PLAYER_ORDER:
		_draw_hangar(color)
	_draw_route_guide()
	for color in PLAYER_ORDER:
		_draw_shortcut(color)
	_draw_main_route()
	for color in PLAYER_ORDER:
		_draw_home_lane_backdrop(color)
	_draw_finish_center()
	for color in PLAYER_ORDER:
		_draw_home_lane_slots(color)
	for color in PLAYER_ORDER:
		_draw_launch_pad(color)
	for color in PLAYER_ORDER:
		_draw_color_pieces(color)


func _draw_board_surface(rect: Rect2) -> void:
	var scale := rect.size.x / BOARD_UNITS
	_draw_rounded_rect(
		Rect2(rect.position + Vector2(0.0, 3.0) * scale, rect.size),
		Color(BOARD_INK, GameboxTokens.GAME["piece_shadow_alpha"]),
		13.0 * scale,
		BOARD_INK,
		0.0,
	)
	_draw_rounded_rect(rect, BOARD_PAPER, 13.0 * scale, BOARD_INK, maxf(2.0, scale * 3.0))
	var center := _logical_to_pixel(Vector2(300, 300))
	draw_circle(center, 111.0 * scale, Color(BOARD_INK, GameboxTokens.GAME["board_center_alpha"]))
	draw_arc(center, 111.0 * scale, 0.0, TAU, 64, Color(BOARD_INK, GameboxTokens.GAME["board_side_camp_alpha"]), maxf(1.0, scale), true)


func _draw_hangar(color: String) -> void:
	var logical_rect: Rect2 = HANGAR_RECTS[color]
	var pixel_rect := _logical_rect_to_pixel(logical_rect)
	var scale := _scale()
	_draw_rounded_rect(
		Rect2(pixel_rect.position + Vector2(0.0, 2.5) * scale, pixel_rect.size),
		Color(BOARD_INK, GameboxTokens.GAME["piece_shadow_alpha"]),
		11.0 * scale,
		BOARD_INK,
		0.0,
	)
	_draw_rounded_rect(pixel_rect, PLAYER_COLORS[color], 11.0 * scale, PLAYER_DARK[color], 2.0 * scale)
	var wash_rect := pixel_rect.grow(-8.0 * scale)
	_draw_rounded_rect(wash_rect, Color(SLOT_COLOR, GameboxTokens.GAME["board_side_camp_alpha"]), 7.0 * scale, Color(SLOT_COLOR, GameboxTokens.GAME["piece_shadow_alpha"]), maxf(1.0, scale))
	for logical_center in HANGAR_SLOTS[color]:
		var center := _logical_to_pixel(logical_center)
		draw_circle(center + Vector2(0.0, 1.5) * scale, 18.0 * scale, Color(BOARD_INK, GameboxTokens.GAME["board_target_camp_alpha"]))
		draw_circle(center, 18.0 * scale, SLOT_COLOR)
		draw_arc(center, 18.0 * scale, 0.0, TAU, 28, PLAYER_DARK[color], maxf(1.2, 1.8 * scale), true)


func _draw_route_guide() -> void:
	var route := PackedVector2Array()
	for point in MAIN_PATH:
		route.append(_logical_to_pixel(point))
	route.append(_logical_to_pixel(MAIN_PATH[0]))
	draw_polyline(route, Color(BOARD_INK, GameboxTokens.GAME["board_target_camp_alpha"]), maxf(4.0, 7.0 * _scale()), true)


func _draw_main_route() -> void:
	for index in MAIN_PATH.size():
		_draw_route_tile(index)


func _draw_home_lane_backdrop(color: String) -> void:
	var points: Array = HOME_STRETCHES[color]
	var scale := _scale()
	var start := _logical_to_pixel(points[0])
	var finish := _logical_to_pixel(points[-1])
	var direction := (finish - start).normalized()
	var perpendicular := Vector2(-direction.y, direction.x)
	var half_width := 14.0 * scale
	var tail := start - direction * 15.0 * scale
	var neck := finish + direction * 7.0 * scale
	var tip := finish + direction * 28.0 * scale
	var lane := PackedVector2Array([
		tail - perpendicular * half_width,
		neck - perpendicular * half_width,
		neck - perpendicular * half_width * 1.32,
		tip,
		neck + perpendicular * half_width * 1.32,
		neck + perpendicular * half_width,
		tail + perpendicular * half_width,
	])
	draw_colored_polygon(lane, PLAYER_COLORS[color])
	draw_polyline(PackedVector2Array(Array(lane) + [lane[0]]), PLAYER_DARK[color], maxf(1.0, 1.4 * scale), true)


func _draw_home_lane_slots(color: String) -> void:
	var scale := _scale()
	for point in HOME_STRETCHES[color]:
		var center := _logical_to_pixel(point)
		draw_circle(center, 9.0 * scale, SLOT_COLOR)
		draw_arc(center, 9.0 * scale, 0.0, TAU, 24, PLAYER_DARK[color], maxf(0.8, scale), true)


func _draw_route_tile(index: int) -> void:
	var scale := _scale()
	var logical_center: Vector2 = MAIN_PATH[index]
	var color: Color = PLAYER_COLORS[route_color(index)]
	var center := _logical_to_pixel(logical_center)
	var rect := Rect2(center - Vector2(14.0, 13.0) * scale, Vector2(28.0, 26.0) * scale)
	_draw_rounded_rect(Rect2(rect.position + Vector2(0.0, 1.4) * scale, rect.size), Color(BOARD_INK, GameboxTokens.GAME["board_target_camp_alpha"]), 6.0 * scale, BOARD_INK, 0.0)
	_draw_rounded_rect(rect, color, 6.0 * scale, BOARD_INK, maxf(1.0, 1.2 * scale))
	var shortcut_color := _shortcut_color(index)
	if shortcut_color.is_empty():
		draw_circle(center, 6.3 * scale, SLOT_COLOR)
		draw_arc(center, 6.3 * scale, 0.0, TAU, 20, Color(BOARD_INK, GameboxTokens.GAME["board_grid_alpha"]), maxf(0.7, scale * 0.75), true)
	else:
		_draw_plane(center, 8.2 * scale, SLOT_COLOR, _plane_rotation(shortcut_color))


func _shortcut_color(index: int) -> String:
	for color in SHORTCUTS:
		if (SHORTCUTS[color] as Vector2i).x == index:
			return color
	return ""


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
	var polygons := {
		"yellow": [Vector2(300, 300), Vector2(278, 278), Vector2(254, 300), Vector2(278, 322)],
		"green": [Vector2(300, 300), Vector2(278, 278), Vector2(300, 254), Vector2(322, 278)],
		"red": [Vector2(300, 300), Vector2(322, 278), Vector2(346, 300), Vector2(322, 322)],
		"blue": [Vector2(300, 300), Vector2(278, 322), Vector2(300, 346), Vector2(322, 322)],
	}
	for color in PLAYER_ORDER:
		var points := PackedVector2Array()
		for point in polygons[color]:
			points.append(_logical_to_pixel(point))
		draw_colored_polygon(points, PLAYER_COLORS[color])
		draw_polyline(PackedVector2Array(Array(points) + [points[0]]), BOARD_INK, maxf(1.0, 1.5 * _scale()), true)
	draw_circle(_logical_to_pixel(Vector2(300, 300)), 6.5 * _scale(), SLOT_COLOR)


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
		var piece: Dictionary = color_pieces[index]
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


func _stack_members(color: String, piece: Dictionary) -> Array:
	var result: Array = []
	var color_pieces: Array = _pieces[color]
	for index in color_pieces.size():
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


func _draw_rounded_rect(rect: Rect2, fill: Color, radius: float, border: Color, border_width: float) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
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
