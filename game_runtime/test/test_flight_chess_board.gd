extends RefCounted

const Motion = preload("res://games/flight_chess/flight_chess_motion.gd")
const State = preload("res://games/flight_chess/flight_chess_state.gd")
const FlightChessBoard = preload("res://games/flight_chess/flight_chess_board.gd")


static func cases() -> Array:
	return [
		{"name":"flight chess presentation paths end at the authoritative destination", "run":_motion_destinations},
		{"name": "flight chess board exposes the classic 52-space topology", "run": _exposes_classic_topology},
		{"name": "flight chess board keeps its four route quadrants rotationally symmetric", "run": _keeps_route_quadrants_symmetric},
		{"name": "flight chess board aligns straight route cells edge to edge", "run": _aligns_straight_route_cells},
		{"name": "flight chess board keeps home lanes visually separate from the shared route", "run": _separates_home_lanes_from_route},
		{"name": "flight chess board keeps launch pads fully inside the playfield", "run": _keeps_launch_pads_inside},
		{"name": "flight chess board remains square inside landscape bounds", "run": _remains_square},
		{"name": "flight chess board maps selectable planes to stable hit targets", "run": _maps_selectable_planes},
		{"name": "flight chess board resolves imprecise phone taps to the nearest legal plane", "run": _snaps_imprecise_taps},
		{"name": "flight chess board exposes stacked planes as one counted group", "run": _groups_stacked_planes},
		{"name": "flight chess board shows a pressed plane before committing touch", "run": _shows_pressed_touch_state},
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
		and _check(FlightChessBoard.route_color(49) == "yellow", "yellow finish entry is not on a yellow route tile") \
		and _check(FlightChessBoard.route_color(10) == "green", "green finish entry is not on a green route tile") \
		and _check(FlightChessBoard.route_color(23) == "red", "red finish entry is not on a red route tile") \
		and _check(FlightChessBoard.route_color(36) == "blue", "blue finish entry is not on a blue route tile") \
		and _check(FlightChessBoard.route_color(17) == "yellow", "yellow shortcut trigger is not on a yellow route tile") \
		and _check(FlightChessBoard.route_color(30) == "green", "green shortcut trigger is not on a green route tile") \
		and _check(FlightChessBoard.route_color(43) == "red", "red shortcut trigger is not on a red route tile") \
		and _check(FlightChessBoard.route_color(4) == "blue", "blue shortcut trigger is not on a blue route tile") \
		and _check(topology["finish_entries"] == {"yellow": 49, "green": 10, "red": 23, "blue": 36}, "finish entries drifted") \
		and _check(topology["shortcuts"] == {
			"yellow": Vector2i(17, 29), "green": Vector2i(30, 42),
			"red": Vector2i(43, 3), "blue": Vector2i(4, 16),
		}, "shortcut graph drifted") \
		and _check((topology["home_stretches"] as Dictionary).values().all(func(points: Array) -> bool: return points.size() == 6), "a home stretch is not six spaces")


static func _separates_home_lanes_from_route() -> bool:
	for color in FlightChessBoard.HOME_STRETCHES:
		for home_point in FlightChessBoard.HOME_STRETCHES[color]:
			for route_point in FlightChessBoard.MAIN_PATH:
				if not _check(
					(home_point as Vector2).distance_to(route_point) >= FlightChessBoard.MIN_LANE_CLEARANCE,
					"%s home lane overlaps the shared route at %s" % [color, home_point],
				):
					return false
	return true


static func _keeps_route_quadrants_symmetric() -> bool:
	for quadrant in range(1, 4):
		for index in 13:
			var expected: Vector2 = FlightChessBoard.MAIN_PATH[index]
			for _turn in quadrant:
				expected = Vector2(FlightChessBoard.BOARD_UNITS - expected.y, expected.x)
			if not _check(
				(FlightChessBoard.MAIN_PATH[quadrant * 13 + index] as Vector2).is_equal_approx(expected),
				"shared route lost rotational symmetry in quadrant %d" % quadrant,
			):
				return false
	return true


static func _aligns_straight_route_cells() -> bool:
	var base_pairs := [Vector2i(1, 2), Vector2i(5, 6), Vector2i(8, 9), Vector2i(11, 12)]
	for quadrant in 4:
		for pair in base_pairs:
			var first := _polygon_rect(FlightChessBoard.route_cell_polygon(quadrant * 13 + pair.x))
			var second := _polygon_rect(FlightChessBoard.route_cell_polygon(quadrant * 13 + pair.y))
			var delta := (second.get_center() - first.get_center()).abs()
			var aligned := false
			if delta.x > delta.y:
				aligned = is_zero_approx(delta.y) and is_equal_approx(delta.x, (first.size.x + second.size.x) * 0.5)
			else:
				aligned = is_zero_approx(delta.x) and is_equal_approx(delta.y, (first.size.y + second.size.y) * 0.5)
			if not _check(aligned, "straight route cells are not edge aligned in quadrant %d" % quadrant):
				return false
	return true


static func _polygon_rect(polygon: PackedVector2Array) -> Rect2:
	var result := Rect2(polygon[0], Vector2.ZERO)
	for point in polygon:
		result = result.expand(point)
	return result


static func _keeps_launch_pads_inside() -> bool:
	for color in FlightChessBoard.LAUNCH_POINTS:
		var point: Vector2 = FlightChessBoard.LAUNCH_POINTS[color]
		if not _check(
			point.x >= FlightChessBoard.LAUNCH_EDGE_CLEARANCE
				and point.y >= FlightChessBoard.LAUNCH_EDGE_CLEARANCE
				and point.x <= FlightChessBoard.BOARD_UNITS - FlightChessBoard.LAUNCH_EDGE_CLEARANCE
				and point.y <= FlightChessBoard.BOARD_UNITS - FlightChessBoard.LAUNCH_EDGE_CLEARANCE,
			"%s launch pad is clipped by the board edge" % color,
		):
			return false
	return true


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


static func _snaps_imprecise_taps() -> bool:
	var board = FlightChessBoard.new()
	board.size = Vector2(540.0, 540.0)
	var pieces := {
		"red": [
			{"zone": "hangar", "index": 0}, {"zone": "hangar", "index": 1},
			{"zone": "hangar", "index": 2}, {"zone": "main", "index": 30},
		],
	}
	if not _check(board.present(pieces, "red", [0, 1, 2, 3], -1, true), "valid phone presentation was rejected"):
		board.free()
		return false
	var intended_center := board.piece_center("red", 0)
	var imprecise_tap := intended_center + Vector2(-24.0, -18.0)
	var hit: Dictionary = board.piece_at_pixel(imprecise_tap)
	var result := _check(hit == {"color": "red", "index": 0}, "imprecise tap did not select the nearest plane") \
		and _check(board.piece_at_pixel(board.board_rect().get_center()).is_empty(), "distant board tap selected an unintended plane") \
		and _check(board.piece_at_pixel(board.board_rect().position - Vector2.ONE).is_empty(), "tap outside the playfield selected a plane")
	board.free()
	return result


static func _groups_stacked_planes() -> bool:
	var board = FlightChessBoard.new()
	board.size = Vector2(640.0, 640.0)
	var pieces := {
		"red": [
			{"zone": "main", "index": 30}, {"zone": "main", "index": 30},
			{"zone": "hangar", "index": 2}, {"zone": "hangar", "index": 3},
		],
	}
	if not _check(board.present(pieces, "red", [0, 1], -1, true), "stacked presentation was rejected"):
		board.free()
		return false
	var first := board.piece_center("red", 0)
	var second := board.piece_center("red", 1)
	var route_center := board.board_rect().position + FlightChessBoard.MAIN_PATH[30] / FlightChessBoard.BOARD_UNITS * board.board_rect().size
	var result := _check(first.is_equal_approx(second), "stacked group did not share one stable visual center") \
		and _check(first.distance_to(route_center) < 1.0, "stacked group drifted away from its route space") \
		and _check(board.piece_stack_size("red", 0) == 2 and board.piece_stack_size("red", 1) == 2, "stack count is not exposed to the renderer") \
		and _check(board.piece_at_pixel(first) == {"color": "red", "index": 0}, "stacked group lost its stable touch target")
	board.free()
	return result


static func _shows_pressed_touch_state() -> bool:
	var board = FlightChessBoard.new()
	board.size = Vector2(640.0, 640.0)
	(Engine.get_main_loop() as SceneTree).root.add_child(board)
	var pieces := {"red": [{"zone": "hangar", "index": 0}]}
	if not _check(board.present(pieces, "red", [0], -1, true), "pressed-state presentation was rejected"):
		board.free()
		return false
	var commits: Array = []
	board.piece_pressed.connect(func(color: String, index: int) -> void: commits.append([color, index]))
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = board.piece_center("red", 0)
	board._gui_input(down)
	var result := _check(board.pressed_piece_index == 0, "touch-down did not expose pressed feedback") \
		and _check(commits.is_empty(), "touch-down committed the move before release")
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = down.position
	board._gui_input(up)
	result = result \
		and _check(board.pressed_piece_index == -1, "touch release retained pressed feedback") \
		and _check(commits == [["red", 0]], "touch release did not commit exactly once")
	board.free()
	return result


static func _check(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition


static func _motion_destinations() -> bool:
	var board := FlightChessBoard.new()
	for color in ["red","yellow"]:
		for progress in range(-1,57):
			var piece: Dictionary
			if progress == -1:
				piece = {"zone":"hangar","index":0}
			elif progress == 0:
				piece = {"zone":"launch","index":0}
			elif progress <= 50:
				piece = {"zone":"main","index":(FlightChessBoard.PATH_STARTS[color]+progress-1)%52}
			else:
				piece = {"zone":"home","index":progress-51}
			for roll in range(1,7):
				var resolved := State._resolve_move("black" if color == "red" else "white",piece,roll)
				if not resolved.get("ok",false):
					continue
				var segments := Motion.segments(color,0,piece,roll,resolved.effect)
				if not _check(segments[0].from == board._logical_piece_center(color,piece) and segments[-1].to == board._logical_piece_center(color,resolved.to),"presentation path diverges from authority: %s %d + %d" % [color,progress,roll]):
					board.free()
					return false
				for i in range(1,segments.size()):
					if not _check(segments[i-1].to == segments[i].from,"presentation path skips between segments"):
						board.free()
						return false
	board.free()
	return true
