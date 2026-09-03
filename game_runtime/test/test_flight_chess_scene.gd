extends RefCounted

const FlightChessScene = preload("res://games/flight_chess/flight_chess_scene.tscn")
const FlightChessController = preload("res://games/flight_chess/flight_chess_controller.gd")


static func cases() -> Array:
	return [
		{"name": "flight chess scene keeps the board dominant at landscape phone sizes", "run": _keeps_board_dominant},
		{"name": "flight chess scene rolls before enabling manual plane selection", "run": _rolls_before_selection},
	]


static func _keeps_board_dominant() -> bool:
	for viewport in [Vector2(960.0, 540.0), Vector2(1280.0, 720.0), Vector2(2340.0, 1080.0)]:
		var layout: Dictionary = FlightChessController.layout_for_size(viewport)
		if not _check(not layout.is_empty(), "landscape layout was rejected at %s" % viewport):
			return false
		var board: Rect2 = layout["board"]
		var left: Rect2 = layout["left"]
		var right: Rect2 = layout["right"]
		if not _check(is_equal_approx(board.size.x, board.size.y), "board stretched at %s" % viewport) \
			or not _check(board.size.x > left.size.x and board.size.x > right.size.x, "board stopped being dominant at %s" % viewport) \
			or not _check(left.end.x < board.position.x and board.end.x < right.position.x, "rail overlaps the board at %s" % viewport) \
			or not _check(left.position.x >= 24.0 and right.end.x <= viewport.x - 24.0, "safe edge margin drifted at %s" % viewport):
			return false
	return true


static func _rolls_before_selection() -> bool:
	var scene = FlightChessScene.instantiate()
	(scene as Control).set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	(scene as Control).size = Vector2(960.0, 540.0)
	(Engine.get_main_loop() as SceneTree).root.add_child(scene)
	await (Engine.get_main_loop() as SceneTree).process_frame
	await (Engine.get_main_loop() as SceneTree).process_frame
	var board = scene.get_node("Board")
	var roll_button := scene.get_node("RightRail/Content/RollButton") as Button
	var right_rail := scene.get_node("RightRail") as PanelContainer
	var result := _check(board.selectable_piece_indices.is_empty(), "planes were selectable before the die roll") \
		and _check(roll_button.custom_minimum_size.y >= 96.0, "roll target is smaller than 48dp") \
		and _check(right_rail.get_global_rect().encloses(roll_button.get_global_rect()), "narrow landscape clips the roll action")
	scene._on_roll_pressed()
	result = result \
		and _check(scene.dice_value == 6, "deterministic first roll is not six") \
		and _check(board.selectable_piece_indices == [0, 1, 2, 3], "six did not enable manual plane selection") \
		and _check((scene.get_node("RightRail/Content/HintLabel") as Label).text.contains("选择"), "rolled state does not prompt plane selection")
	scene._on_piece_pressed("red", 0)
	result = result \
		and _check(scene.piece_state("red", 0)["zone"] == "launch", "selected hangar plane did not move to launch") \
		and _check(scene.dice_value == 0, "resolved selection retained the die") \
		and _check(not roll_button.disabled, "rolling six did not grant another roll")
	scene.free()
	return result


static func _check(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition
