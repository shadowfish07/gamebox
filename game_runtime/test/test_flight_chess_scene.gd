extends RefCounted

const FlightChessScene = preload("res://games/flight_chess/flight_chess_scene.tscn")
const FlightChessController = preload("res://games/flight_chess/flight_chess_controller.gd")


static func cases() -> Array:
	return [
		{"name": "flight chess scene declares sensor landscape for mobile", "run": _declares_mobile_landscape},
		{"name": "flight chess scene uses a landscape virtual pixel base", "run": _uses_landscape_content_scale},
		{"name": "flight chess scene keeps the board dominant at landscape phone sizes", "run": _keeps_board_dominant},
		{"name": "flight chess scene keeps standard phone actions on screen", "run": _keeps_standard_actions_visible},
		{"name": "flight chess scene stays inside landscape phone safe areas", "run": _respects_phone_safe_areas},
		{"name": "flight chess scene rolls before enabling manual plane selection", "run": _rolls_before_selection},
	]


static func _declares_mobile_landscape() -> bool:
	return _check(
		FlightChessController.preferred_mobile_orientation() == DisplayServer.SCREEN_SENSOR_LANDSCAPE,
		"flight chess did not declare sensor landscape",
	)


static func _uses_landscape_content_scale() -> bool:
	var result := _check(
		FlightChessController.preferred_content_scale_size() == Vector2i(1920, 1080),
		"flight chess retained the portrait virtual pixel base",
	)
	result = result and _check(
		FlightChessController.physical_insets_to_logical(
			Vector4(80.0, 48.0, 40.0, 48.0),
			Vector2(1280.0, 720.0),
			Vector2(1920.0, 1080.0),
		).is_equal_approx(Vector4(120.0, 72.0, 60.0, 72.0)),
		"preview safe-area pixels were not converted into virtual pixels",
	)
	return result


static func _keeps_board_dominant() -> bool:
	for viewport in [Vector2(1920.0, 1080.0), Vector2(2160.0, 1080.0), Vector2(2400.0, 1080.0)]:
		var layout: Dictionary = FlightChessController.layout_for_size(viewport)
		if not _check(not layout.is_empty(), "landscape layout was rejected at %s" % viewport):
			return false
		var board: Rect2 = layout["board"]
		var left: Rect2 = layout["left"]
		var right: Rect2 = layout["right"]
		if not _check(is_equal_approx(board.size.x, board.size.y), "board stretched at %s" % viewport) \
			or not _check(board.size.x > left.size.x and board.size.x > right.size.x, "board stopped being dominant at %s" % viewport) \
			or not _check(left.end.x < board.position.x and board.end.x < right.position.x, "rail overlaps the board at %s" % viewport) \
			or not _check(left.position.x >= 24.0 and left.position.x <= 40.0, "left rail is not anchored to the usable edge at %s" % viewport) \
			or not _check(right.end.x <= viewport.x - 24.0 and right.end.x >= viewport.x - 40.0, "right rail is not anchored to the usable edge at %s" % viewport) \
			or not _check(board.get_center().is_equal_approx(viewport * 0.5), "board is not centered in the usable viewport at %s" % viewport):
			return false
	return true


static func _keeps_standard_actions_visible() -> bool:
	var scene = FlightChessScene.instantiate()
	(scene as Control).set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	(scene as Control).size = Vector2(1920.0, 1080.0)
	(Engine.get_main_loop() as SceneTree).root.add_child(scene)
	await (Engine.get_main_loop() as SceneTree).process_frame
	await (Engine.get_main_loop() as SceneTree).process_frame
	var right_rail := scene.get_node("RightRail") as PanelContainer
	var left_rail := scene.get_node("LeftRail") as PanelContainer
	var back_button := scene.get_node("LeftRail/Content/BackButton") as Button
	var dice_card := scene.get_node("RightRail/Content/DiceCard") as PanelContainer
	var roll_button := scene.get_node("RightRail/Content/RollButton") as Button
	var hint := scene.get_node("RightRail/Content/HintLabel") as Label
	var intended_layout: Dictionary = FlightChessController.layout_for_size(Vector2(1920.0, 1080.0))
	var result := _check(right_rail.get_global_rect().is_equal_approx(intended_layout["right"]), "standard phone rail retained a stale portrait height") \
		and _check(left_rail.get_global_rect().encloses(back_button.get_global_rect()), "standard phone clips the visible back action") \
		and _check(back_button.size.x >= 96.0 and back_button.size.y >= 96.0, "visible back action is smaller than 48dp") \
		and _check(dice_card.visible and roll_button.visible, "standard phone hid the primary controls") \
		and _check(right_rail.get_global_rect().encloses(dice_card.get_global_rect()), "standard phone clips the dice") \
		and _check(right_rail.get_global_rect().encloses(roll_button.get_global_rect()), "standard phone clips the roll action") \
		and _check(roll_button.size.y >= 96.0, "standard phone roll target is smaller than 48dp")
	scene._on_roll_pressed()
	await (Engine.get_main_loop() as SceneTree).process_frame
	await (Engine.get_main_loop() as SceneTree).process_frame
	result = result \
		and _check(hint.get_line_count() >= 2, "standard phone does not wrap the long selection hint") \
		and _check(right_rail.get_global_rect().encloses(hint.get_global_rect()), "standard phone hint escapes the right rail")
	scene._on_piece_pressed("red", 0)
	await (Engine.get_main_loop() as SceneTree).process_frame
	await (Engine.get_main_loop() as SceneTree).process_frame
	var turn_label := scene.get_node("RightRail/Content/TurnLabel") as Label
	result = result \
		and _check(turn_label.text == "可以再掷一次" and turn_label.size.y >= turn_label.get_line_height(), "completed launch hides the extra-roll message") \
		and _check(hint.text.contains("奖励") and hint.size.y >= hint.get_line_height(), "completed launch hides its rule hint") \
		and _check(right_rail.get_global_rect().encloses(turn_label.get_global_rect()), "completed launch message escapes the right rail") \
		and _check(right_rail.get_global_rect().encloses(hint.get_global_rect()), "completed launch hint escapes the right rail")
	scene.free()
	return result


static func _respects_phone_safe_areas() -> bool:
	var viewport := Vector2(2400.0, 1080.0)
	var safe_rect := Rect2(144.0, 24.0, 2160.0, 1008.0)
	var layout: Dictionary = FlightChessController.layout_for_size(viewport, safe_rect)
	if not _check(not layout.is_empty(), "20:9 cutout layout was rejected"):
		return false
	for region_name in ["left", "board", "right"]:
		var region: Rect2 = layout[region_name]
		if not _check(safe_rect.encloses(region), "%s escaped the Android safe area" % region_name):
			return false
	var board: Rect2 = layout["board"]
	var left: Rect2 = layout["left"]
	var right: Rect2 = layout["right"]
	var short_safe_layout := FlightChessController.layout_for_size(
		Vector2(1280.0, 720.0),
		Rect2(80.0, 48.0, 1160.0, 624.0),
	)
	var result := _check(is_equal_approx(board.size.x, board.size.y), "safe-area board stretched") \
		and _check(left.end.x < board.position.x and board.end.x < right.position.x, "safe-area rails overlap the board") \
		and _check(is_equal_approx(right.end.x, safe_rect.end.x - 32.0), "right rail is not anchored to the 16dp page inset") \
		and _check(is_equal_approx(left.position.x, safe_rect.position.x + 32.0), "left rail is not anchored to the 16dp page inset") \
		and _check(board.get_center().is_equal_approx(safe_rect.get_center()), "safe-area board is not centered") \
		and _check(FlightChessController.layout_is_compact(short_safe_layout), "short safe-area phone did not switch to compact controls")
	var scene = FlightChessScene.instantiate()
	(scene as Control).set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	(scene as Control).size = Vector2(1280.0, 720.0)
	scene.set_preview_safe_insets(Vector4(80.0, 48.0, 40.0, 48.0))
	(Engine.get_main_loop() as SceneTree).root.add_child(scene)
	await (Engine.get_main_loop() as SceneTree).process_frame
	await (Engine.get_main_loop() as SceneTree).process_frame
	var actual_board := (scene.get_node("Board") as Control).get_global_rect()
	var hint := scene.get_node("RightRail/Content/HintLabel") as Label
	var dice_card := scene.get_node("RightRail/Content/DiceCard") as PanelContainer
	result = result \
		and _check(actual_board.is_equal_approx(short_safe_layout["board"]), "production scene ignored the injected phone safe area") \
		and _check(not hint.visible and dice_card.size.y <= 152.0, "production scene did not apply compact safe-area controls")
	scene.free()
	return result


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
	var dice_card := scene.get_node("RightRail/Content/DiceCard") as PanelContainer
	var eyebrow := scene.get_node("LeftRail/Content/Eyebrow") as Label
	var hint := scene.get_node("RightRail/Content/HintLabel") as Label
	var result := _check(board.selectable_piece_indices.is_empty(), "planes were selectable before the die roll") \
		and _check(roll_button.custom_minimum_size.y >= 96.0, "roll target is smaller than 48dp") \
		and _check(right_rail.get_global_rect().encloses(roll_button.get_global_rect()), "narrow landscape clips the roll action") \
		and _check(dice_card.size.y <= 152.0, "compact phone lets the dice card become an empty vertical slab") \
		and _check(not eyebrow.visible and not hint.visible, "compact phone retained secondary copy") \
		and _check(roll_button.get_global_rect().end.y >= right_rail.get_global_rect().end.y - 20.0, "primary action is not docked for the right thumb")
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
	result = result \
		and _check(scene.set_preview_state("selected"), "selected preview state was rejected") \
		and _check(board.selected_piece_index == 0, "selected preview does not exercise the real board selection binding") \
		and _check(scene.set_preview_state("pressed"), "pressed preview state was rejected") \
		and _check(board.pressed_piece_index == 0, "pressed preview does not exercise the real board press binding")
	scene.free()
	return result


static func _check(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition
