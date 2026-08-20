class_name GomokuBoard
extends Control

signal cell_pressed(x: int, y: int)

const BOARD_SIZE := 15
const BOARD_CELLS := BOARD_SIZE * BOARD_SIZE
const EMPTY := 0
const BLACK := 1
const WHITE := 2
const LOCAL_PADDING := 36.0
const INVALID_CELL := Vector2i(-1, -1)
const DRAG_CANCEL_DISTANCE := 12.0

const BOARD_COLOR := Color("d8a85f")
const GRID_COLOR := Color("493217")
const BLACK_STONE_COLOR := Color("151a24")
const WHITE_STONE_COLOR := Color("f8fafc")
const WHITE_STONE_OUTLINE := Color("667085")
const LAST_MOVE_COLOR := Color("f04438")
const PENDING_COLOR := Color("0072b2")

var pending_cell: Vector2i:
	get:
		return _pending_cell
	set(_value):
		pass

var last_move_cell: Vector2i:
	get:
		return _last_move_cell
	set(_value):
		pass

var _cells: Array = []
var _pending_cell := INVALID_CELL
var _last_move_cell := INVALID_CELL
var _interactable := true
var _active_touch := -1
var _touch_start_cell := INVALID_CELL
var _touch_start_position := Vector2.ZERO
var _touch_cancelled := false
var _blocked_touches := {}


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	_cells.resize(BOARD_CELLS)
	_cells.fill(EMPTY)


func present(cells: Array, last_move: Vector2i = INVALID_CELL, pending: Vector2i = INVALID_CELL) -> bool:
	if not _valid_cells(cells) or not _valid_marker(last_move) or not _valid_marker(pending):
		return false
	if last_move != INVALID_CELL and cells[last_move.y * BOARD_SIZE + last_move.x] == EMPTY:
		return false
	if pending != INVALID_CELL and cells[pending.y * BOARD_SIZE + pending.x] != EMPTY:
		return false
	if last_move != INVALID_CELL and last_move == pending:
		return false
	_cells = cells.duplicate()
	_last_move_cell = last_move
	_pending_cell = pending
	queue_redraw()
	return true


func set_interactable(next_interactable: bool) -> void:
	_interactable = next_interactable
	if not _interactable:
		_reset_touch()
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if _interactable else Control.CURSOR_ARROW


func stone_at(x: int, y: int) -> int:
	if x < 0 or x >= BOARD_SIZE or y < 0 or y >= BOARD_SIZE:
		return -1
	return _cells[y * BOARD_SIZE + x]


func board_rect() -> Rect2:
	var side: float = maxf(0.0, minf(size.x, size.y) - LOCAL_PADDING * 2.0)
	var origin: Vector2 = (size - Vector2(side, side)) * 0.5
	return Rect2(origin, Vector2(side, side))


static func cell_to_pixel(cell: Vector2i, rect: Rect2) -> Vector2:
	if not _valid_rect(rect) or cell.x < 0 or cell.x >= BOARD_SIZE or cell.y < 0 or cell.y >= BOARD_SIZE:
		return Vector2(INF, INF)
	var spacing := rect.size / float(BOARD_SIZE - 1)
	return rect.position + Vector2(cell) * spacing


static func pixel_to_cell(pixel: Vector2, rect: Rect2) -> Vector2i:
	if not _valid_rect(rect) or not pixel.is_finite():
		return INVALID_CELL
	var spacing := rect.size / float(BOARD_SIZE - 1)
	var minimum := rect.position - spacing * 0.5
	var maximum := rect.end + spacing * 0.5
	if pixel.x < minimum.x or pixel.y < minimum.y or pixel.x > maximum.x or pixel.y > maximum.y:
		return INVALID_CELL
	var relative := (pixel - rect.position) / spacing
	var cell := Vector2i(int(floor(relative.x + 0.5)), int(floor(relative.y + 0.5)))
	if cell.x < 0 or cell.x >= BOARD_SIZE or cell.y < 0 or cell.y >= BOARD_SIZE:
		return INVALID_CELL
	return cell


static func design_to_viewport(point: Vector2, design_size: Vector2, viewport_size: Vector2) -> Vector2:
	var transform := _viewport_transform(design_size, viewport_size)
	if not transform.get("ok", false):
		return Vector2(INF, INF)
	return transform["offset"] + point * float(transform["scale"])


static func viewport_to_design(point: Vector2, design_size: Vector2, viewport_size: Vector2) -> Vector2:
	var transform := _viewport_transform(design_size, viewport_size)
	if not transform.get("ok", false):
		return Vector2(INF, INF)
	return (point - Vector2(transform["offset"])) / float(transform["scale"])


static func design_rect_to_viewport(rect: Rect2, design_size: Vector2, viewport_size: Vector2) -> Rect2:
	var top_left := design_to_viewport(rect.position, design_size, viewport_size)
	var bottom_right := design_to_viewport(rect.end, design_size, viewport_size)
	if not top_left.is_finite() or not bottom_right.is_finite():
		return Rect2()
	return Rect2(top_left, bottom_right - top_left)


func _gui_input(event: InputEvent) -> void:
	if not _interactable:
		return
	if event is InputEventScreenTouch:
		_handle_touch(event)
	elif event is InputEventScreenDrag and event.index == _active_touch:
		if event.position.distance_to(_touch_start_position) > DRAG_CANCEL_DISTANCE:
			_touch_cancelled = true
		accept_event()


func _handle_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		if _active_touch >= 0:
			_touch_cancelled = true
			_blocked_touches[event.index] = true
		elif _blocked_touches.is_empty():
			var start_cell := pixel_to_cell(event.position, board_rect())
			if start_cell != INVALID_CELL:
				_active_touch = event.index
				_touch_start_cell = start_cell
				_touch_start_position = event.position
				_touch_cancelled = false
			else:
				_blocked_touches[event.index] = true
	else:
		if event.index == _active_touch:
			var release_cell := pixel_to_cell(event.position, board_rect())
			var should_submit := not event.canceled and not _touch_cancelled and release_cell == _touch_start_cell
			var submitted_cell := _touch_start_cell
			_reset_active_touch()
			if should_submit:
				cell_pressed.emit(submitted_cell.x, submitted_cell.y)
		elif _blocked_touches.has(event.index):
			_blocked_touches.erase(event.index)
	accept_event()


func _draw() -> void:
	var rect := board_rect()
	if not _valid_rect(rect):
		return
	draw_rect(Rect2(Vector2.ZERO, size), BOARD_COLOR, true)
	var spacing := rect.size / float(BOARD_SIZE - 1)
	for index in BOARD_SIZE:
		var x := rect.position.x + spacing.x * index
		var y := rect.position.y + spacing.y * index
		draw_line(Vector2(x, rect.position.y), Vector2(x, rect.end.y), GRID_COLOR, 2.0, true)
		draw_line(Vector2(rect.position.x, y), Vector2(rect.end.x, y), GRID_COLOR, 2.0, true)
	var star_radius: float = maxf(4.0, spacing.x * 0.09)
	for star in [Vector2i(3, 3), Vector2i(11, 3), Vector2i(7, 7), Vector2i(3, 11), Vector2i(11, 11)]:
		draw_circle(cell_to_pixel(star, rect), star_radius, GRID_COLOR, true, -1.0, true)
	var stone_radius := spacing.x * 0.39
	for y in BOARD_SIZE:
		for x in BOARD_SIZE:
			var stone: int = _cells[y * BOARD_SIZE + x]
			if stone == EMPTY:
				continue
			var center := cell_to_pixel(Vector2i(x, y), rect)
			if stone == BLACK:
				draw_circle(center, stone_radius, BLACK_STONE_COLOR, true, -1.0, true)
			else:
				draw_circle(center, stone_radius, WHITE_STONE_OUTLINE, true, -1.0, true)
				draw_circle(center, stone_radius - 2.5, WHITE_STONE_COLOR, true, -1.0, true)
	if _last_move_cell != INVALID_CELL:
		var last_center := cell_to_pixel(_last_move_cell, rect)
		draw_arc(last_center, stone_radius * 0.47, 0.0, TAU, 32, LAST_MOVE_COLOR, 4.0, true)
	if _pending_cell != INVALID_CELL:
		var pending_center := cell_to_pixel(_pending_cell, rect)
		draw_circle(pending_center, stone_radius * 0.42, Color(PENDING_COLOR, 0.24), true, -1.0, true)
		draw_arc(pending_center, stone_radius * 0.72, 0.0, TAU, 32, PENDING_COLOR, 5.0, true)


func _notification(what: int) -> void:
	if what == NOTIFICATION_FOCUS_EXIT or what == NOTIFICATION_VISIBILITY_CHANGED and not is_visible_in_tree():
		_reset_touch()


func _reset_touch() -> void:
	_reset_active_touch()
	_blocked_touches.clear()


func _reset_active_touch() -> void:
	_active_touch = -1
	_touch_start_cell = INVALID_CELL
	_touch_start_position = Vector2.ZERO
	_touch_cancelled = false


func _valid_cells(cells: Array) -> bool:
	if cells.size() != BOARD_CELLS:
		return false
	for value in cells:
		if typeof(value) != TYPE_INT or value < EMPTY or value > WHITE:
			return false
	return true


static func _valid_marker(cell: Vector2i) -> bool:
	return cell == INVALID_CELL or cell.x >= 0 and cell.x < BOARD_SIZE and cell.y >= 0 and cell.y < BOARD_SIZE


static func _valid_rect(rect: Rect2) -> bool:
	return rect.position.is_finite() and rect.size.is_finite() and rect.size.x > 0.0 \
		and is_equal_approx(rect.size.x, rect.size.y)


static func _viewport_transform(design_size: Vector2, viewport_size: Vector2) -> Dictionary:
	if not design_size.is_finite() or not viewport_size.is_finite() \
		or design_size.x <= 0.0 or design_size.y <= 0.0 or viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return {"ok": false}
	var scale: float = minf(viewport_size.x / design_size.x, viewport_size.y / design_size.y)
	return {"ok": true, "scale": scale, "offset": (viewport_size - design_size * scale) * 0.5}
