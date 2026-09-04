extends SceneTree

const FLIGHT_CHESS_SCENE := preload("res://games/flight_chess/flight_chess_scene.tscn")
const FLIGHT_CHESS_CONTROLLER := preload("res://games/flight_chess/flight_chess_controller.gd")
const FLIGHT_CHESS_FULL_GAME_DRIVER := preload("res://test/support/flight_chess_full_game_driver.gd")
const MATCH_ID := "11111111-1111-4111-8111-111111111111"
const BLACK_ID := "22222222-2222-4222-8222-222222222222"
const WHITE_ID := "33333333-3333-4333-8333-333333333333"
const ROLL_ACTION_ID := "44444444-4444-4444-8444-444444444444"
const MOVE_ACTION_ID := "55555555-5555-4555-8555-555555555555"

var _state_name := "ready"
var _viewport := Vector2i(1280, 720)
var _screenshot_path := ""
var _milestone_dir := ""
var _theme_name := "light"
var _safe_insets := Vector4.ZERO
var _step_delay := 0.02
var _scene: Control
var _client: FullGameMatchClient


func _init() -> void:
	if not _parse_arguments(OS.get_cmdline_user_args()):
		return
	DisplayServer.window_set_size(_viewport)
	FLIGHT_CHESS_CONTROLLER.apply_window_profile(get_root())
	call_deferred("_mount")


func _mount() -> void:
	_scene = FLIGHT_CHESS_SCENE.instantiate()
	_scene.set_preview_dark(_theme_name == "dark")
	var logical_insets := FLIGHT_CHESS_CONTROLLER.physical_insets_to_logical(
		_safe_insets,
		Vector2(_viewport),
		get_root().get_visible_rect().size,
	)
	_scene.set_preview_safe_insets(logical_insets)
	_scene.set_quit_callback(func() -> void: quit())
	if _state_name == "full-game":
		_client = FullGameMatchClient.new()
		_scene.configure_launch({
			"game_id": "flight_chess",
			"match_id": MATCH_ID,
			"launch_ticket": "safe-preview-ticket",
			"ws_url": "ws://127.0.0.1:8080/v1/ws",
		})
		_scene.set_match_client_factory(func() -> Variant: return _client)
	else:
		_scene.set_preview_state(_state_name)
	get_root().add_child(_scene)
	if _state_name == "full-game":
		_play_full_game.call_deferred()
	elif not _screenshot_path.is_empty():
		_capture_screenshot.call_deferred()


func _play_full_game() -> void:
	for _frame in 3:
		await process_frame
	_client.accept_snapshot(FLIGHT_CHESS_FULL_GAME_DRIVER.initial_snapshot(MATCH_ID, BLACK_ID, WHITE_ID))
	await process_frame
	var counts := {
		"events": 0,
		"rolls": 0,
		"moves": 0,
		"black_rolls": 0,
		"white_rolls": 0,
		"black_moves": 0,
		"white_moves": 0,
		"captures": 0,
		"jumps": 0,
		"shortcuts": 0,
	}
	var captured_milestones := {}
	while _client.state.status == "active" and _client.state.revision < 512:
		var event: Dictionary = FLIGHT_CHESS_FULL_GAME_DRIVER.next_event(_client.state, MATCH_ID)
		if event.is_empty() or not await _submit_local_action(event) or not _client.accept_event(event):
			push_error("Flight Chess full-game preview could not apply its next event")
			quit(1)
			return
		counts["events"] += 1
		if event["type"] == "flight_chess.roll.accepted":
			counts["rolls"] += 1
			counts["%s_rolls" % event["payload"]["color"]] += 1
		else:
			counts["moves"] += 1
			var payload: Dictionary = event["payload"]
			counts["%s_moves" % payload["color"]] += 1
			counts["captures"] += payload["capturedPieceIndices"].size()
			var effect: String = payload["effect"]
			if effect in ["jump", "jump_shortcut"]:
				counts["jumps"] += 1
			if effect in ["shortcut", "jump_shortcut"]:
				counts["shortcuts"] += 1
			if not await _capture_move_milestone(payload, captured_milestones):
				quit(1)
				return
		await process_frame
		if _step_delay > 0.0:
			await create_timer(_step_delay).timeout
	if not _validate_finished_match(counts):
		quit(1)
		return
	print(
		"GAMEBOX_FLIGHT_CHESS_FULL_GAME events=%d rolls=%d moves=%d black_rolls=%d white_rolls=%d black_moves=%d white_moves=%d captures=%d jumps=%d shortcuts=%d winner=black"
		% [
			counts["events"], counts["rolls"], counts["moves"], counts["black_rolls"], counts["white_rolls"],
			counts["black_moves"], counts["white_moves"],
			counts["captures"], counts["jumps"], counts["shortcuts"],
		]
	)
	if not _screenshot_path.is_empty():
		await _capture_screenshot()
	else:
		quit()


func _submit_local_action(event: Dictionary) -> bool:
	if event["payload"]["color"] != "black":
		return true
	if event["type"] == "flight_chess.roll.accepted":
		_scene._on_roll_pressed()
	else:
		_scene._on_piece_pressed("red", event["payload"]["pieceIndex"])
	await process_frame
	return not _client.state.pending_action.is_empty()


func _capture_move_milestone(payload: Dictionary, captured: Dictionary) -> bool:
	if _milestone_dir.is_empty():
		return true
	var milestone := ""
	if payload["from"]["zone"] == "hangar" and not captured.has("launch"):
		milestone = "01-launch"
		captured["launch"] = true
	elif payload["color"] == "white" and not captured.has("opponent"):
		milestone = "02-opponent-in-flight"
		captured["opponent"] = true
	elif payload["effect"] in ["jump", "jump_shortcut"] and not captured.has("jump"):
		milestone = "03-jump"
		captured["jump"] = true
	elif payload["effect"] in ["shortcut", "jump_shortcut"] and not captured.has("shortcut"):
		milestone = "04-shortcut"
		captured["shortcut"] = true
	elif payload["to"]["zone"] == "finished" and not captured.has("finished"):
		milestone = "05-first-finished"
		captured["finished"] = true
	if milestone.is_empty():
		return true
	var error := DirAccess.make_dir_recursive_absolute(_milestone_dir)
	if error != OK:
		push_error("Flight Chess milestone directory failed: %s" % error_string(error))
		return false
	error = await _save_current_frame(_milestone_dir.path_join("%s.png" % milestone))
	if error != OK:
		push_error("Flight Chess milestone screenshot failed: %s" % error_string(error))
		return false
	return true


func _validate_finished_match(counts: Dictionary) -> bool:
	var result_panel := _scene.get_node("ResultPanel") as PanelContainer
	var all_red_finished := true
	for piece_index in range(4):
		all_red_finished = all_red_finished and _scene.piece_state("red", piece_index).get("zone") == "finished"
	var valid: bool = _client.state.status == "finished" and _client.state.result == "goal" \
		and _client.state.winner_user_id == BLACK_ID and _client.state.revision < 512 \
		and counts["black_moves"] > 0 and counts["white_moves"] > 0 \
		and _client.roll_requests == counts["black_rolls"] and _client.move_requests == counts["black_moves"] \
		and counts["jumps"] > 0 and counts["shortcuts"] > 0 \
		and all_red_finished and result_panel.visible \
		and _scene.get_node("LeftRail/Content/LocalCard/Content/Meta").text == "4 架抵达" \
		and result_panel.get_node("Content/Result").text == "全员抵达"
	if not valid:
		push_error("Flight Chess full-game preview did not reach a valid goal result")
	return valid


func _capture_screenshot() -> void:
	for _frame in 6:
		await process_frame
	await create_timer(0.35).timeout
	for _frame in 2:
		await RenderingServer.frame_post_draw
		await process_frame
	RenderingServer.force_draw()
	RenderingServer.force_sync()
	var right_rail := _scene.get_node("RightRail") as Control
	var dice_card := _scene.get_node("RightRail/Content/DiceCard") as Control
	var roll_button := _scene.get_node("RightRail/Content/RollButton") as Control
	var scene_rect := Rect2(Vector2.ZERO, _scene.size)
	if not scene_rect.encloses(right_rail.get_global_rect()) \
		or not right_rail.get_global_rect().encloses(dice_card.get_global_rect()) \
		or not right_rail.get_global_rect().encloses(roll_button.get_global_rect()):
		push_error("Flight Chess preview clips its primary controls")
		quit(1)
		return
	print(
		"GAMEBOX_FLIGHT_CHESS_PREVIEW physical=%s logical=%s right=%s dice=%s roll=%s"
		% [_viewport, _scene.size, right_rail.get_global_rect(), dice_card.get_global_rect(), roll_button.get_global_rect()]
	)
	var error := await _save_current_frame(_screenshot_path)
	if error != OK:
		push_error("Flight Chess preview screenshot failed: %s" % error_string(error))
		quit(1)
		return
	print("Flight Chess preview saved: %s" % _screenshot_path)
	quit()


func _save_current_frame(path: String) -> Error:
	for _frame in 2:
		await RenderingServer.frame_post_draw
		await process_frame
	RenderingServer.force_draw()
	RenderingServer.force_sync()
	return get_root().get_texture().get_image().save_png(path)


func _parse_arguments(args: PackedStringArray) -> bool:
	var index := 0
	while index < args.size():
		if index + 1 >= args.size():
			push_error("Expected a value after %s" % args[index])
			quit(2)
			return false
		match args[index]:
			"--state":
				_state_name = args[index + 1]
				if _state_name not in ["ready", "rolled", "pressed", "selected", "stacked", "full-game"]:
					push_error("Unknown preview state: %s" % _state_name)
					quit(2)
					return false
			"--viewport":
				_viewport = _parse_viewport(args[index + 1])
				if _viewport == Vector2i.ZERO:
					push_error("Viewport must be a landscape WIDTHxHEIGHT of at least 960x540")
					quit(2)
					return false
			"--screenshot":
				_screenshot_path = args[index + 1]
				if _screenshot_path.is_empty():
					push_error("Screenshot path must not be empty")
					quit(2)
					return false
			"--milestone-dir":
				_milestone_dir = args[index + 1]
				if _milestone_dir.is_empty():
					push_error("Milestone directory must not be empty")
					quit(2)
					return false
			"--step-delay":
				var value := args[index + 1]
				if not value.is_valid_float() or value.to_float() < 0.0 or value.to_float() > 1.0:
					push_error("Step delay must be between 0 and 1 second")
					quit(2)
					return false
				_step_delay = value.to_float()
			"--theme":
				_theme_name = args[index + 1]
				if _theme_name not in ["light", "dark"]:
					push_error("Theme must be light or dark")
					quit(2)
					return false
			"--safe-insets":
				_safe_insets = _parse_insets(args[index + 1])
				if _safe_insets.x < 0.0:
					push_error("Safe insets must be four non-negative values: LEFT,TOP,RIGHT,BOTTOM")
					quit(2)
					return false
			_:
				push_error("Unknown preview option: %s" % args[index])
				quit(2)
				return false
		index += 2
	if _safe_insets.x + _safe_insets.z >= _viewport.x or _safe_insets.y + _safe_insets.w >= _viewport.y:
		push_error("Safe insets leave no usable viewport")
		quit(2)
		return false
	return true


func _parse_viewport(value: String) -> Vector2i:
	var parts := value.split("x", false)
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return Vector2i.ZERO
	var result := Vector2i(parts[0].to_int(), parts[1].to_int())
	return result if result.x >= 960 and result.y >= 540 and result.x > result.y else Vector2i.ZERO


func _parse_insets(value: String) -> Vector4:
	var parts := value.split(",", false)
	if parts.size() != 4:
		return Vector4(-1.0, -1.0, -1.0, -1.0)
	var values := PackedFloat32Array()
	for part in parts:
		if not part.is_valid_float() or part.to_float() < 0.0:
			return Vector4(-1.0, -1.0, -1.0, -1.0)
		values.append(part.to_float())
	return Vector4(values[0], values[1], values[2], values[3])


class FullGameMatchClient:
	extends RefCounted

	signal connection_state_changed(next_state: String)
	signal snapshot_sync_started
	signal snapshot_received(envelope: Dictionary)
	signal event_received(envelope: Dictionary)
	signal player_presence_changed(user_id: String, online: bool)
	signal match_error(code: String)
	signal return_to_lobby_requested(code: String)

	var connection_state := "closed"
	var local_user_id := BLACK_ID
	var state: Variant
	var roll_requests := 0
	var move_requests := 0

	func start(_ws_url: String, _match_id: String, _ticket: String, game_state: Variant, game_id: String) -> bool:
		state = game_state
		connection_state = "connecting"
		return game_id == "flight_chess"

	func poll() -> void:
		pass

	func request_flight_chess_roll() -> String:
		if not state.mark_pending_roll(ROLL_ACTION_ID, local_user_id):
			return ""
		roll_requests += 1
		return ROLL_ACTION_ID

	func request_flight_chess_move(piece_index: int) -> String:
		if not state.mark_pending_move(MOVE_ACTION_ID, piece_index, local_user_id):
			return ""
		move_requests += 1
		return MOVE_ACTION_ID

	func request_resign() -> String:
		return ""

	func has_player_presence(_user_id: String) -> bool:
		return true

	func is_player_online(_user_id: String) -> bool:
		return true

	func dispose() -> void:
		pass

	func accept_snapshot(envelope: Dictionary) -> void:
		connection_state = "connected"
		connection_state_changed.emit(connection_state)
		snapshot_received.emit(envelope)

	func accept_event(envelope: Dictionary) -> bool:
		var applied: Dictionary = state.apply_event(envelope)
		if not applied.get("ok", false):
			return false
		event_received.emit(envelope)
		return true
