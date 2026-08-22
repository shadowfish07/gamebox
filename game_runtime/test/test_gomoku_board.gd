extends RefCounted

const GomokuBoard = preload("res://games/gomoku/gomoku_board.gd")
const GameboxTokens = preload("res://design_system/generated/gamebox_tokens.gd")

const DESIGN_SIZE := Vector2(1080.0, 1920.0)
const BOARD_RECT := Rect2(60.0, 360.0, 960.0, 960.0)


static func cases() -> Array:
	return [
		{"name": "gomoku board maps corners center and inverse coordinates", "run": _maps_board_coordinates},
		{"name": "gomoku board rejects points beyond half a cell", "run": _rejects_outside_tap_margin},
		{"name": "gomoku board mapping survives expanded viewport stretch", "run": _maps_expanded_viewports},
		{"name": "gomoku board submits one safe single-finger release", "run": _submits_only_safe_release},
		{"name": "gomoku board advances pressed pending and authoritative states", "run": _advances_interaction_states},
		{"name": "gomoku board keeps authoritative stones separate from pending", "run": _keeps_pending_separate},
		{"name": "gomoku board maps every rendered state to game tokens", "run": _maps_game_tokens},
	]


static func _maps_board_coordinates() -> bool:
	for cell in [Vector2i(0, 0), Vector2i(14, 0), Vector2i(7, 7), Vector2i(0, 14), Vector2i(14, 14)]:
		var pixel: Vector2 = GomokuBoard.cell_to_pixel(cell, BOARD_RECT)
		if not _check(GomokuBoard.pixel_to_cell(pixel, BOARD_RECT) == cell, "cell/pixel inverse failed for %s" % cell):
			return false
	return _check(GomokuBoard.cell_to_pixel(Vector2i(0, 0), BOARD_RECT).is_equal_approx(BOARD_RECT.position), "top-left mapping changed") \
		and _check(GomokuBoard.cell_to_pixel(Vector2i(14, 14), BOARD_RECT).is_equal_approx(BOARD_RECT.end), "bottom-right mapping changed") \
		and _check(GomokuBoard.cell_to_pixel(Vector2i(7, 7), BOARD_RECT).is_equal_approx(BOARD_RECT.get_center()), "center mapping changed")


static func _rejects_outside_tap_margin() -> bool:
	var spacing := BOARD_RECT.size.x / 14.0
	return _check(GomokuBoard.pixel_to_cell(BOARD_RECT.position - Vector2(spacing * 0.51, 0.0), BOARD_RECT) == Vector2i(-1, -1), "left outside tap accepted") \
		and _check(GomokuBoard.pixel_to_cell(Vector2(BOARD_RECT.end.x + spacing * 0.51, BOARD_RECT.position.y), BOARD_RECT) == Vector2i(-1, -1), "right outside tap accepted") \
		and _check(GomokuBoard.pixel_to_cell(BOARD_RECT.position - Vector2(0.0, spacing * 0.51), BOARD_RECT) == Vector2i(-1, -1), "top outside tap accepted") \
		and _check(GomokuBoard.pixel_to_cell(Vector2(BOARD_RECT.position.x, BOARD_RECT.end.y + spacing * 0.51), BOARD_RECT) == Vector2i(-1, -1), "bottom outside tap accepted")


static func _maps_expanded_viewports() -> bool:
	for viewport_size in [Vector2(540.0, 960.0), Vector2(1080.0, 2400.0), Vector2(1440.0, 2560.0)]:
		if not _check(
			GomokuBoard.design_to_viewport(Vector2.ZERO, DESIGN_SIZE, viewport_size) == Vector2.ZERO,
			"expanded content stopped using the top-left origin at %s" % viewport_size,
		):
			return false
		var transformed_rect: Rect2 = GomokuBoard.design_rect_to_viewport(BOARD_RECT, DESIGN_SIZE, viewport_size)
		if not _check(is_equal_approx(transformed_rect.size.x, transformed_rect.size.y), "board stopped being square at %s" % viewport_size):
			return false
		for cell in [Vector2i(0, 0), Vector2i(7, 7), Vector2i(14, 14)]:
			var target_pixel: Vector2 = GomokuBoard.design_to_viewport(
				GomokuBoard.cell_to_pixel(cell, BOARD_RECT), DESIGN_SIZE, viewport_size,
			)
			if not _check(GomokuBoard.pixel_to_cell(target_pixel, transformed_rect) == cell, "stretched mapping failed for %s at %s" % [cell, viewport_size]):
				return false
			var design_pixel: Vector2 = GomokuBoard.viewport_to_design(target_pixel, DESIGN_SIZE, viewport_size)
			if not _check(design_pixel.is_equal_approx(GomokuBoard.cell_to_pixel(cell, BOARD_RECT)), "viewport inverse failed"):
				return false
	return true


static func _submits_only_safe_release() -> bool:
	var board := GomokuBoard.new()
	board.size = Vector2(960.0, 960.0)
	var pressed: Array[Vector2i] = []
	board.cell_pressed.connect(func(x: int, y: int) -> void: pressed.append(Vector2i(x, y)))
	var center: Vector2 = GomokuBoard.cell_to_pixel(Vector2i(7, 7), board.board_rect())

	board._gui_input(_touch(0, true, center))
	board._gui_input(_touch(0, false, center))
	if not _check(pressed == [Vector2i(7, 7)], "single release did not submit exactly once"):
		board.free()
		return false
	var off_center := center + Vector2(20.0, 0.0)
	board._gui_input(_touch(0, true, off_center))
	board._gui_input(_drag(0, off_center + Vector2(2.0, 0.0), Vector2(2.0, 0.0)))
	board._gui_input(_touch(0, false, off_center + Vector2(2.0, 0.0)))
	if not _check(pressed == [Vector2i(7, 7), Vector2i(7, 7)], "small off-center finger motion was treated as a drag"):
		board.free()
		return false
	board._gui_input(_touch(0, true, center))
	board._gui_input(_touch(0, false, center, true))

	board._gui_input(_touch(0, true, center))
	board._gui_input(_drag(0, center + Vector2(40.0, 0.0)))
	board._gui_input(_touch(0, false, center))
	board._gui_input(_touch(0, true, center))
	board._gui_input(_touch(1, true, center))
	board._gui_input(_touch(0, false, center))
	board._gui_input(_touch(1, false, center))
	board._gui_input(_touch(0, true, center))
	board._gui_input(_touch(0, false, Vector2(-200.0, -200.0)))
	board._gui_input(_touch(0, true, Vector2.ZERO))
	board._gui_input(_touch(1, true, center))
	board._gui_input(_touch(1, false, center))
	board._gui_input(_touch(0, false, Vector2.ZERO))
	var result := _check(pressed == [Vector2i(7, 7), Vector2i(7, 7)], "cancel, drag, multitouch, or outside release submitted a move")
	board.free()
	return result


static func _keeps_pending_separate() -> bool:
	var board := GomokuBoard.new()
	board.size = Vector2(960.0, 960.0)
	var cells: Array = []
	cells.resize(225)
	cells.fill(0)
	cells[7 * 15 + 7] = 1
	board.present(cells, Vector2i(7, 7), Vector2i(8, 7))
	var result := _check(board.stone_at(7, 7) == 1, "authoritative stone missing") \
		and _check(board.stone_at(8, 7) == 0, "pending move was painted into authoritative board") \
		and _check(board.pending_cell == Vector2i(8, 7), "pending marker missing") \
		and _check(board.last_move_cell == Vector2i(7, 7), "last move marker missing")
	board.free()
	return result


static func _advances_interaction_states() -> bool:
	var board := GomokuBoard.new()
	board.size = Vector2(960.0, 960.0)
	var cells: Array = []
	cells.resize(225)
	cells.fill(0)
	var requests: Array[Vector2i] = []
	board.cell_pressed.connect(func(x: int, y: int) -> void:
		var requested := Vector2i(x, y)
		requests.append(requested)
		board.present(cells, Vector2i(-1, -1), requested)
	)
	var target := Vector2i(7, 7)
	var center: Vector2 = GomokuBoard.cell_to_pixel(target, board.board_rect())

	board._gui_input(_touch(0, true, center))
	if not _check(_pressed_cell(board) == target, "touch-down did not expose an immediate pressed cell") \
		or not _check(board.pending_cell == Vector2i(-1, -1), "touch-down became pending before release"):
		board.free()
		return false
	board._gui_input(_drag(0, center + Vector2(40.0, 0.0)))
	if not _check(_pressed_cell(board) == Vector2i(-1, -1), "drag did not clear the pressed cell"):
		board.free()
		return false
	board._gui_input(_touch(0, false, center))

	board._gui_input(_touch(0, true, center))
	board._gui_input(_touch(0, false, center, true))
	if not _check(_pressed_cell(board) == Vector2i(-1, -1), "cancel did not clear the pressed cell") \
		or not _check(requests.is_empty(), "drag or cancel submitted a request"):
		board.free()
		return false

	board._gui_input(_touch(0, true, center))
	if not _check(_pressed_cell(board) == target, "second touch-down did not restore pressed feedback"):
		board.free()
		return false
	board._gui_input(_touch(0, false, center))
	if not _check(_pressed_cell(board) == Vector2i(-1, -1), "safe release kept pressed feedback") \
		or not _check(requests == [target], "safe release did not request exactly one move") \
		or not _check(board.pending_cell == target, "safe release did not become server-authoritative pending") \
		or not _check(board.stone_at(target.x, target.y) == 0, "pending feedback became an authoritative stone"):
		board.free()
		return false

	cells[target.y * 15 + target.x] = 1
	board.present(cells, target, Vector2i(-1, -1))
	var result := _check(board.stone_at(target.x, target.y) == 1, "authoritative acceptance did not create a stone") \
		and _check(board.pending_cell == Vector2i(-1, -1), "authoritative acceptance did not clear pending") \
		and _check(board.last_move_cell == target, "authoritative acceptance did not mark the last move")
	board.free()
	return result


static func _maps_game_tokens() -> bool:
	var board := GomokuBoard.new()
	var constants: Dictionary = board.get_script().get_script_constant_map()
	var result := _check(constants.get("BOARD_COLOR") == GameboxTokens.GAME["board"], "board surface stopped using the game token") \
		and _check(constants.get("GRID_COLOR") == GameboxTokens.GAME["grid"], "grid stopped using the game token") \
		and _check(constants.get("BLACK_STONE_COLOR") == GameboxTokens.GAME["black_piece"], "black stone stopped using the game token") \
		and _check(constants.get("WHITE_STONE_COLOR") == GameboxTokens.GAME["white_piece"], "white stone stopped using the game token") \
		and _check(constants.get("WHITE_STONE_OUTLINE") == GameboxTokens.GAME["white_piece_outline"], "white outline stopped using the game token") \
		and _check(constants.get("LAST_MOVE_COLOR") == GameboxTokens.GAME["last_move"], "last move stopped using the game token") \
		and _check(constants.get("PRESSED_COLOR") == GameboxTokens.GAME["pressed_move"], "pressed move stopped using the game token") \
		and _check(constants.get("PENDING_COLOR") == GameboxTokens.GAME["pending_move"], "pending move stopped using the game token") \
		and _check(constants.get("PENDING_OVERLAY_ALPHA") == GameboxTokens.GAME["pending_overlay_alpha"], "pending opacity stopped using the game token")
	board.free()
	return result


static func _pressed_cell(board: Control) -> Variant:
	for property in board.get_property_list():
		if property.get("name") == "pressed_cell":
			return board.get("pressed_cell")
	return null


static func _touch(index: int, pressed: bool, position: Vector2, cancelled: bool = false) -> InputEventScreenTouch:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.pressed = pressed
	event.position = position
	event.canceled = cancelled
	return event


static func _drag(index: int, position: Vector2, relative: Vector2 = Vector2(40.0, 0.0)) -> InputEventScreenDrag:
	var event := InputEventScreenDrag.new()
	event.index = index
	event.position = position
	event.relative = relative
	return event


static func _check(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition
