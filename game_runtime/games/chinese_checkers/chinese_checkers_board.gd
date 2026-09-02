class_name ChineseCheckersBoard
extends Control

signal hole_pressed(index: int)
signal move_animation_finished

const ChineseCheckersState = preload("res://games/chinese_checkers/chinese_checkers_state.gd")
const GameboxTokens = preload("res://design_system/generated/gamebox_tokens.gd")

const BOARD_CELLS := 121
const EMPTY := 0
const BLACK := 1
const WHITE := 2
const INVALID_HOLE := -1
const LOCAL_PADDING := 28.0
const VERTICAL_STEP := 0.8660254037844386
const DRAG_CANCEL_DISTANCE := 14.0
const MOVE_LIFT_FACTOR := 0.46

const BOARD_COLOR := GameboxTokens.GAME["board"]
const GRID_COLOR := GameboxTokens.GAME["grid"]
const BLACK_PIECE_COLOR := GameboxTokens.GAME["black_piece"]
const WHITE_PIECE_COLOR := GameboxTokens.GAME["white_piece"]
const WHITE_PIECE_OUTLINE := GameboxTokens.GAME["white_piece_outline"]
const SELECTED_COLOR := GameboxTokens.GAME["pressed_move"]
const PENDING_COLOR := GameboxTokens.GAME["pending_move"]
const PENDING_ALPHA := GameboxTokens.GAME["pending_overlay_alpha"]
const BOARD_CENTER_ALPHA := GameboxTokens.GAME["board_center_alpha"]
const BOARD_GRID_ALPHA := GameboxTokens.GAME["board_grid_alpha"]
const BOARD_HOLE_ALPHA := GameboxTokens.GAME["board_hole_alpha"]
const BOARD_SIDE_CAMP_ALPHA := GameboxTokens.GAME["board_side_camp_alpha"]
const BOARD_TARGET_CAMP_ALPHA := GameboxTokens.GAME["board_target_camp_alpha"]
const BOARD_TARGET_FILL_ALPHA := GameboxTokens.GAME["board_target_fill_alpha"]
const PIECE_SHADOW_ALPHA := GameboxTokens.GAME["piece_shadow_alpha"]

var selected_hole: int:
	get: return _selected_hole
	set(_value): pass
var target_holes: Array:
	get: return _target_holes.duplicate()
	set(_value): pass
var pending_path: Array:
	get: return _pending_path.duplicate()
	set(_value): pass
var move_animation_path: Array:
	get: return _move_animation_path.duplicate()
	set(_value): pass

var _cells: Array = []
var _local_color := "white"
var _selected_hole := INVALID_HOLE
var _target_paths := {}
var _target_holes: Array = []
var _pending_path: Array = []
var _interactable := false
var _active_touch := -1
var _pressed_hole := INVALID_HOLE
var _touch_start := Vector2.ZERO
var _touch_cancelled := false
var _move_animation_path: Array = []
var _move_animation_stone := EMPTY
var _move_animation_elapsed := 0.0
var _move_animation_duration := 0.0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	set_process(false)
	_cells.resize(BOARD_CELLS)
	_cells.fill(EMPTY)


func present(
	cells: Array,
	local_color: String,
	selected: int = INVALID_HOLE,
	target_paths: Dictionary = {},
	pending: Array = [],
	interactable: bool = false,
) -> bool:
	if not _valid_cells(cells) or local_color not in ["black", "white"] \
		or selected < INVALID_HOLE or selected >= BOARD_CELLS \
		or selected >= 0 and cells[selected] == EMPTY \
		or not pending.is_empty() and (selected != INVALID_HOLE or not target_paths.is_empty()) \
		or not _valid_pending(cells, pending):
		return false
	var normalized_paths := {}
	var normalized_targets: Array = []
	for destination in target_paths:
		var path: Variant = target_paths[destination]
		if typeof(destination) != TYPE_INT or destination < 0 or destination >= BOARD_CELLS \
			or cells[destination] != EMPTY or not path is Array or path.size() < 2 \
			or path[0] != selected or path.back() != destination or not _valid_indices(path):
			return false
		normalized_paths[destination] = path.duplicate()
		normalized_targets.append(destination)
	normalized_targets.sort()
	_cells = cells.duplicate()
	_local_color = local_color
	_selected_hole = selected
	_target_paths = normalized_paths
	_target_holes = normalized_targets
	_pending_path = pending.duplicate()
	if not _move_animation_path.is_empty() and (
			not pending.is_empty() or cells[_move_animation_path.back()] != _move_animation_stone):
		_finish_move_animation()
	set_interactable(interactable)
	queue_redraw()
	return true


func set_interactable(value: bool) -> void:
	_interactable = value
	_sync_input_state()


func play_move_animation(path: Array) -> bool:
	if not _move_animation_path.is_empty() or path.size() < 2 or not _valid_indices(path):
		return false
	var origin: int = path[0]
	var destination: int = path.back()
	var stone: int = _cells[destination]
	if _cells[origin] != EMPTY or stone not in [BLACK, WHITE]:
		return false
	_move_animation_path = path.duplicate()
	_move_animation_stone = stone
	_move_animation_elapsed = 0.0
	var duration_ms := clampi(
		(path.size() - 1) * int(GameboxTokens.MOTION["fast"]),
		int(GameboxTokens.MOTION["standard"]),
		int(GameboxTokens.MOTION["page_enter"]),
	)
	_move_animation_duration = float(duration_ms) / 1000.0
	set_process(true)
	_sync_input_state()
	queue_redraw()
	return true


func animation_piece_position(progress: float = -1.0) -> Vector2:
	if _move_animation_path.is_empty():
		return Vector2(INF, INF)
	var resolved_progress := progress
	if resolved_progress < 0.0:
		resolved_progress = _move_animation_elapsed / _move_animation_duration
	return _animation_path_position(clampf(resolved_progress, 0.0, 1.0), true)


func _process(delta: float) -> void:
	if _move_animation_path.is_empty():
		set_process(false)
		return
	_move_animation_elapsed += maxf(0.0, delta)
	if _move_animation_elapsed >= _move_animation_duration:
		_finish_move_animation()
	queue_redraw()


func stone_at(index: int) -> int:
	return _cells[index] if index >= 0 and index < BOARD_CELLS else -1


func path_for_target(index: int) -> Array:
	var path: Variant = _target_paths.get(index, [])
	return path.duplicate() if path is Array else []


func board_rect() -> Rect2:
	return Rect2(Vector2(LOCAL_PADDING, LOCAL_PADDING), Vector2(maxf(0.0, size.x - LOCAL_PADDING * 2.0), maxf(0.0, size.y - LOCAL_PADDING * 2.0)))


static func hole_to_pixel(index: int, rect: Rect2, local_color: String) -> Vector2:
	if index < 0 or index >= BOARD_CELLS or not _valid_rect(rect) or local_color not in ["black", "white"]:
		return Vector2(INF, INF)
	var point := ChineseCheckersState.point_for_index(index)
	var logical := Vector2(point.x * 0.5, point.y * VERTICAL_STEP)
	var logical_size := Vector2(12.0, 16.0 * VERTICAL_STEP)
	if local_color == "black":
		logical = logical_size - logical
	var spacing: float = minf(rect.size.x / logical_size.x, rect.size.y / logical_size.y)
	var star_size := logical_size * spacing
	var origin := rect.position + (rect.size - star_size) * 0.5
	return origin + logical * spacing


static func pixel_to_hole(pixel: Vector2, rect: Rect2, local_color: String) -> int:
	if not pixel.is_finite() or not _valid_rect(rect) or not _point_in_rect_inclusive(pixel, rect) \
		or local_color not in ["black", "white"]:
		return INVALID_HOLE
	var nearest := INVALID_HOLE
	var nearest_distance := INF
	for index in BOARD_CELLS:
		var distance := pixel.distance_squared_to(hole_to_pixel(index, rect, local_color))
		if distance < nearest_distance:
			nearest_distance = distance
			nearest = index
	var sample_spacing := hole_to_pixel(56, rect, local_color).distance_to(hole_to_pixel(57, rect, local_color))
	return nearest if nearest_distance <= pow(sample_spacing * 0.46, 2.0) else INVALID_HOLE


func _gui_input(event: InputEvent) -> void:
	if not _interactable:
		return
	if event is InputEventScreenTouch:
		_handle_touch(event)
	elif event is InputEventScreenDrag and event.index == _active_touch:
		if event.position.distance_to(_touch_start) > DRAG_CANCEL_DISTANCE:
			_touch_cancelled = true
			_pressed_hole = INVALID_HOLE
			queue_redraw()
		accept_event()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_pressed_hole = pixel_to_hole(event.position, board_rect(), _local_color)
		else:
			var released := pixel_to_hole(event.position, board_rect(), _local_color)
			var submitted := _pressed_hole
			_pressed_hole = INVALID_HOLE
			queue_redraw()
			if submitted >= 0 and submitted == released:
				hole_pressed.emit(submitted)
		accept_event()


func _handle_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		if _active_touch < 0:
			_active_touch = event.index
			_touch_start = event.position
			_pressed_hole = pixel_to_hole(event.position, board_rect(), _local_color)
			_touch_cancelled = _pressed_hole < 0
			queue_redraw()
	elif event.index == _active_touch:
		var released := pixel_to_hole(event.position, board_rect(), _local_color)
		var submitted := _pressed_hole
		var should_submit := not event.canceled and not _touch_cancelled and submitted >= 0 and submitted == released
		_reset_touch()
		if should_submit:
			hole_pressed.emit(submitted)
	accept_event()


func _draw() -> void:
	var rect := board_rect()
	if not _valid_rect(rect):
		return
	draw_rect(Rect2(Vector2.ZERO, size), BOARD_COLOR, true)
	var sample_a := hole_to_pixel(56, rect, _local_color)
	var sample_b := hole_to_pixel(57, rect, _local_color)
	var spacing := sample_a.distance_to(sample_b)
	for index in BOARD_CELLS:
		var origin := ChineseCheckersState.point_for_index(index)
		for delta in ChineseCheckersState.ADJACENT_DELTAS:
			var neighbor := ChineseCheckersState.index_for_point(origin + delta)
			if neighbor > index:
				draw_line(hole_to_pixel(index, rect, _local_color), hole_to_pixel(neighbor, rect, _local_color), Color(GRID_COLOR, BOARD_GRID_ALPHA), 2.0, true)
	if not _pending_path.is_empty():
		var points := PackedVector2Array()
		for index in _pending_path:
			points.append(hole_to_pixel(index, rect, _local_color))
		if points.size() >= 2:
			draw_polyline(points, PENDING_COLOR, maxf(5.0, spacing * 0.07), true)

	var hole_radius := maxf(5.0, spacing * 0.13)
	var piece_radius := maxf(10.0, spacing * 0.34)
	for index in BOARD_CELLS:
		var center := hole_to_pixel(index, rect, _local_color)
		var camp_tint := _camp_tint(index)
		draw_circle(center, hole_radius * 1.45, camp_tint, true, -1.0, true)
		draw_circle(center, hole_radius, Color(GRID_COLOR, BOARD_HOLE_ALPHA), true, -1.0, true)
		if _target_paths.has(index):
			draw_circle(center, piece_radius * 0.54, Color(SELECTED_COLOR, BOARD_TARGET_FILL_ALPHA), true, -1.0, true)
			draw_arc(center, piece_radius * 0.64, 0.0, TAU, 32, SELECTED_COLOR, 4.0, true)
			draw_circle(center, maxf(4.0, piece_radius * 0.13), SELECTED_COLOR, true, -1.0, true)

	for index in BOARD_CELLS:
		var stone: int = _cells[index]
		if stone == EMPTY or not _move_animation_path.is_empty() and index == _move_animation_path.back():
			continue
		var center := hole_to_pixel(index, rect, _local_color)
		if index == _selected_hole:
			center.y -= maxf(5.0, spacing * 0.08)
			draw_circle(center + Vector2(0.0, maxf(6.0, spacing * 0.09)), piece_radius, Color(BLACK_PIECE_COLOR, PIECE_SHADOW_ALPHA), true, -1.0, true)
		var alpha := 0.34 if not _pending_path.is_empty() and index == _pending_path[0] else 1.0
		_draw_piece(center, piece_radius, stone, alpha)
		if index == _selected_hole:
			draw_arc(center, piece_radius * 1.18, 0.0, TAU, 36, SELECTED_COLOR, 5.0, true)
	if not _pending_path.is_empty():
		var destination: int = _pending_path.back()
		var center := hole_to_pixel(destination, rect, _local_color)
		_draw_piece(center, piece_radius, _cells[_pending_path[0]], 0.42)
		draw_arc(center, piece_radius * 1.18, 0.0, TAU, 36, PENDING_COLOR, 5.0, true)
	if not _move_animation_path.is_empty():
		var progress := clampf(_move_animation_elapsed / _move_animation_duration, 0.0, 1.0)
		var shadow_center := _animation_path_position(progress, false)
		var center := _animation_path_position(progress, true)
		var lift_ratio := clampf((shadow_center.y - center.y) / maxf(spacing * MOVE_LIFT_FACTOR, 1.0), 0.0, 1.0)
		var shadow_color := BLACK_PIECE_COLOR
		shadow_color.a = PIECE_SHADOW_ALPHA * lerpf(1.0, 0.55, lift_ratio)
		draw_circle(shadow_center + Vector2(0.0, maxf(4.0, spacing * 0.06)), piece_radius * lerpf(0.88, 0.7, lift_ratio), shadow_color, true, -1.0, true)
		_draw_piece(center, piece_radius * lerpf(1.0, 1.06, lift_ratio), _move_animation_stone, 1.0)
	if _pressed_hole >= 0:
		draw_arc(hole_to_pixel(_pressed_hole, rect, _local_color), piece_radius * 0.82, 0.0, TAU, 32, SELECTED_COLOR, 4.0, true)


func _draw_piece(center: Vector2, radius: float, stone: int, alpha: float) -> void:
	if stone == BLACK:
		draw_circle(center, radius, Color(BLACK_PIECE_COLOR, alpha), true, -1.0, true)
	else:
		draw_circle(center, radius, Color(WHITE_PIECE_OUTLINE, alpha), true, -1.0, true)
		draw_circle(center, radius - 2.5, Color(WHITE_PIECE_COLOR, alpha), true, -1.0, true)


func _camp_tint(index: int) -> Color:
	if index <= 9 or index >= 111:
		return Color(SELECTED_COLOR, BOARD_TARGET_CAMP_ALPHA)
	if _is_side_camp(index):
		return Color(GRID_COLOR, BOARD_SIDE_CAMP_ALPHA)
	return Color(GRID_COLOR, BOARD_CENTER_ALPHA)


static func _is_side_camp(index: int) -> bool:
	var point := ChineseCheckersState.point_for_index(index)
	if point.y < 4 or point.y > 12 or point.y == 8:
		return false
	var row_offset := 0
	for row in point.y:
		row_offset += ChineseCheckersState.ROW_LENGTHS[row]
	var column := index - row_offset
	var depth := 8 - point.y if point.y <= 7 else point.y - 8
	return column < depth or column >= ChineseCheckersState.ROW_LENGTHS[point.y] - depth


func _reset_touch() -> void:
	_active_touch = -1
	_pressed_hole = INVALID_HOLE
	_touch_start = Vector2.ZERO
	_touch_cancelled = false
	queue_redraw()


func _sync_input_state() -> void:
	var effective := _interactable and _move_animation_path.is_empty()
	mouse_filter = Control.MOUSE_FILTER_STOP if effective else Control.MOUSE_FILTER_IGNORE
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if effective else Control.CURSOR_ARROW
	if not effective:
		_reset_touch()


func _finish_move_animation() -> void:
	var had_animation := not _move_animation_path.is_empty()
	_move_animation_path.clear()
	_move_animation_stone = EMPTY
	_move_animation_elapsed = 0.0
	_move_animation_duration = 0.0
	set_process(false)
	_sync_input_state()
	if had_animation:
		move_animation_finished.emit()


func _animation_path_position(progress: float, lifted: bool) -> Vector2:
	var segment_count := _move_animation_path.size() - 1
	var scaled_progress := progress * segment_count
	var segment := mini(floori(scaled_progress), segment_count - 1)
	var segment_progress := 1.0 if progress >= 1.0 else scaled_progress - segment
	var eased_progress := segment_progress * segment_progress * (3.0 - 2.0 * segment_progress)
	var rect := board_rect()
	var start := hole_to_pixel(_move_animation_path[segment], rect, _local_color)
	var finish := hole_to_pixel(_move_animation_path[segment + 1], rect, _local_color)
	var position := start.lerp(finish, eased_progress)
	if lifted:
		var spacing := hole_to_pixel(56, rect, _local_color).distance_to(hole_to_pixel(57, rect, _local_color))
		position.y -= sin(segment_progress * PI) * spacing * MOVE_LIFT_FACTOR
	return position


static func _valid_pending(cells: Array, pending: Array) -> bool:
	return pending.is_empty() or pending.size() >= 2 and _valid_indices(pending) \
		and cells[pending[0]] in [BLACK, WHITE] and cells[pending.back()] == EMPTY


static func _valid_indices(values: Array) -> bool:
	var seen := {}
	for value in values:
		if typeof(value) != TYPE_INT or value < 0 or value >= BOARD_CELLS or seen.has(value):
			return false
		seen[value] = true
	return true


static func _valid_cells(cells: Array) -> bool:
	if cells.size() != BOARD_CELLS:
		return false
	for value in cells:
		if typeof(value) != TYPE_INT or value < EMPTY or value > WHITE:
			return false
	return true


static func _valid_rect(rect: Rect2) -> bool:
	return rect.position.is_finite() and rect.size.is_finite() and rect.size.x > 0.0 and rect.size.y > 0.0


static func _point_in_rect_inclusive(point: Vector2, rect: Rect2) -> bool:
	return point.x >= rect.position.x and point.y >= rect.position.y \
		and point.x <= rect.end.x and point.y <= rect.end.y
