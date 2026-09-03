extends RefCounted

const FlightChessBoard = preload("res://games/flight_chess/flight_chess_board.gd")


static func cases() -> Array:
	return [
		{"name": "flight chess board exposes the classic 52-space topology", "run": _exposes_classic_topology},
		{"name": "flight chess board remains square inside landscape bounds", "run": _remains_square},
		{"name": "flight chess board maps selectable planes to stable hit targets", "run": _maps_selectable_planes},
	]


static func _exposes_classic_topology() -> bool:
	var topology: Dictionary = FlightChessBoard.topology()
	var main_path: Array = topology["main_path"]
	var unique_points := {}
	for point in main_path:
		unique_points[point] = true
	return _check(main_path.size() == 52, "main route is not 52 spaces") \
		and _check(unique_points.size() == 52, "main route contains duplicate spaces") \
		and _check(topology["path_starts"] == {"yellow": 0, "green": 13, "red": 26, "blue": 39}, "path starts drifted") \
		and _check(topology["finish_entries"] == {"yellow": 49, "green": 10, "red": 23, "blue": 36}, "finish entries drifted") \
		and _check(topology["shortcuts"] == {
			"yellow": Vector2i(17, 29), "green": Vector2i(30, 42),
			"red": Vector2i(43, 3), "blue": Vector2i(4, 16),
		}, "shortcut graph drifted") \
		and _check((topology["home_stretches"] as Dictionary).values().all(func(points: Array) -> bool: return points.size() == 6), "a home stretch is not six spaces")


static func _remains_square() -> bool:
	var board = FlightChessBoard.new()
	board.size = Vector2(920.0, 640.0)
	var rect: Rect2 = board.board_rect()
	var center := rect.get_center()
	var result := _check(is_equal_approx(rect.size.x, rect.size.y), "board content stretched") \
		and _check(rect.size.x <= 640.0, "board content exceeded its control") \
		and _check(center.is_equal_approx(Vector2(460.0, 320.0)), "square board was not centered")
	board.free()
	return result


static func _maps_selectable_planes() -> bool:
	var board = FlightChessBoard.new()
	board.size = Vector2(640.0, 640.0)
	var pieces := {
		"red": [
			{"zone": "hangar", "index": 0}, {"zone": "hangar", "index": 1},
			{"zone": "hangar", "index": 2}, {"zone": "main", "index": 30},
		],
		"yellow": [
			{"zone": "hangar", "index": 0}, {"zone": "hangar", "index": 1},
			{"zone": "main", "index": 6}, {"zone": "main", "index": 17},
		],
	}
	if not _check(board.present(pieces, "red", [0, 3], 0, true), "valid board presentation was rejected"):
		board.free()
		return false
	var red_zero := board.piece_center("red", 0)
	var hit: Dictionary = board.piece_at_pixel(red_zero)
	var result := _check(board.selectable_piece_indices == [0, 3], "selectable plane order drifted") \
		and _check(board.selected_piece_index == 0, "selected plane was not retained") \
		and _check(hit == {"color": "red", "index": 0}, "plane hit target did not round trip") \
		and _check(board.piece_at_pixel(Vector2(-1.0, -1.0)).is_empty(), "outside point selected a plane") \
		and _check(not board.present(pieces, "red", [0, 4], -1, true), "invalid plane index was accepted")
	board.free()
	return result


static func _check(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition
