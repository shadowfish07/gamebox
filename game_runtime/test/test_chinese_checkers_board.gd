extends RefCounted

const ChineseCheckersBoard = preload("res://games/chinese_checkers/chinese_checkers_board.gd")
const GameboxTokens = preload("res://design_system/generated/gamebox_tokens.gd")

const BOARD_RECT := Rect2(40.0, 40.0, 880.0, 1040.0)


static func cases() -> Array:
	return [
		{"name": "chinese checkers board maps all 121 star holes", "run": _maps_star_holes},
		{"name": "chinese checkers board rotates the local camp to the bottom", "run": _rotates_local_camp},
		{"name": "chinese checkers board keeps targets and pending path separate", "run": _keeps_interaction_layers},
		{"name": "chinese checkers board uses generated semantic game tokens", "run": _uses_game_tokens},
	]


static func _maps_star_holes() -> bool:
	var seen := {}
	for index in 121:
		var pixel: Vector2 = ChineseCheckersBoard.hole_to_pixel(index, BOARD_RECT, "white")
		if not _check(pixel.is_finite(), "hole %d did not map" % index) \
			or not _check(ChineseCheckersBoard.pixel_to_hole(pixel, BOARD_RECT, "white") == index, "inverse mapping failed at %d" % index):
			return false
		seen[index] = pixel
	return _check(seen.size() == 121, "star does not expose 121 holes") \
		and _check(ChineseCheckersBoard.pixel_to_hole(BOARD_RECT.position - Vector2.ONE, BOARD_RECT, "white") == -1, "outside point snapped to board") \
		and _check(ChineseCheckersBoard.pixel_to_hole(BOARD_RECT.position + Vector2.ONE, BOARD_RECT, "white") == -1, "empty board margin snapped to a hole")


static func _rotates_local_camp() -> bool:
	var white_top := ChineseCheckersBoard.hole_to_pixel(0, BOARD_RECT, "white")
	var white_bottom := ChineseCheckersBoard.hole_to_pixel(120, BOARD_RECT, "white")
	var black_zero := ChineseCheckersBoard.hole_to_pixel(0, BOARD_RECT, "black")
	var black_last := ChineseCheckersBoard.hole_to_pixel(120, BOARD_RECT, "black")
	return _check(white_top.y < white_bottom.y, "canonical white orientation changed") \
		and _check(black_zero.is_equal_approx(white_bottom), "black start camp was not rotated down") \
		and _check(black_last.is_equal_approx(white_top), "black target camp was not rotated up")


static func _keeps_interaction_layers() -> bool:
	var board = ChineseCheckersBoard.new()
	var cells := _initial_board()
	var paths := {14: [6, 14], 15: [6, 15]}
	if not _check(board.present(cells, "black", 6, paths, [], true), "selected state rejected") \
		or not _check(board.selected_hole == 6 and board.target_holes == [14, 15], "targets were not normalized"):
		board.free()
		return false
	if not _check(board.present(cells, "black", -1, {}, [6, 14], false), "pending state rejected") \
		or not _check(board.pending_path == [6, 14] and board.stone_at(6) == 1 and board.stone_at(14) == 0, "pending path changed authority"):
		board.free()
		return false
	var invalid := board.present(cells, "black", 6, {14: [6, 15]}, [], true)
	board.free()
	return _check(not invalid, "mismatched target path accepted")


static func _uses_game_tokens() -> bool:
	return _check(ChineseCheckersBoard.BOARD_COLOR == GameboxTokens.GAME["board"], "board token drifted") \
		and _check(ChineseCheckersBoard.GRID_COLOR == GameboxTokens.GAME["grid"], "grid token drifted") \
		and _check(ChineseCheckersBoard.BLACK_PIECE_COLOR == GameboxTokens.GAME["black_piece"], "black piece token drifted") \
		and _check(ChineseCheckersBoard.WHITE_PIECE_COLOR == GameboxTokens.GAME["white_piece"], "white piece token drifted") \
		and _check(ChineseCheckersBoard.PENDING_COLOR == GameboxTokens.GAME["pending_move"], "pending token drifted") \
		and _check(ChineseCheckersBoard.BOARD_GRID_ALPHA == GameboxTokens.GAME["board_grid_alpha"], "board grid alpha token drifted") \
		and _check(ChineseCheckersBoard.PIECE_SHADOW_ALPHA == GameboxTokens.GAME["piece_shadow_alpha"], "piece shadow alpha token drifted")


static func _initial_board() -> Array:
	var cells: Array = []
	cells.resize(121)
	cells.fill(0)
	for index in 10:
		cells[index] = 1
	for index in range(111, 121):
		cells[index] = 2
	return cells


static func _check(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition
