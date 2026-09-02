extends SceneTree

# Development-only renderer for Chinese Checkers UX inspection. This script
# mounts the production scene and injects deterministic, non-networked state.
const CHINESE_CHECKERS_SCENE := preload("res://games/chinese_checkers/chinese_checkers_scene.tscn")
const GAMEBOX_THEME := preload("res://design_system/gamebox_theme.gd")
const MATCH_ID := "11111111-1111-4111-8111-111111111111"
const BLACK_ID := "22222222-2222-4222-8222-222222222222"
const WHITE_ID := "33333333-3333-4333-8333-333333333333"
const ACTION_ID := "44444444-4444-4444-8444-444444444444"

var _state_name := "own"
var _viewport := Vector2i(720, 1600)
var _screenshot_path := ""
var _theme_name := "system"


class PreviewClient:
	extends RefCounted

	signal connection_state_changed(next_state: String)
	signal snapshot_sync_started()
	signal snapshot_received(envelope: Dictionary)
	signal event_received(envelope: Dictionary)
	signal player_presence_changed(user_id: String, online: bool)
	signal match_error(code: String)
	signal return_to_lobby_requested(code: String)

	var connection_state := "connected"
	var local_user_id := BLACK_ID
	var state: Variant
	var snapshot := {}

	func start(_ws_url: String, _match_id: String, _ticket: String, game_state: Variant, _game_id: String) -> bool:
		state = game_state
		call_deferred("_emit_snapshot")
		return true

	func poll() -> void:
		pass

	func request_chinese_checkers_move(path: Array) -> String:
		return ACTION_ID if state.mark_pending_path(ACTION_ID, path, local_user_id) else ""

	func request_resign() -> String:
		return ACTION_ID if state.mark_pending_resign(ACTION_ID, local_user_id) else ""

	func has_player_presence(_user_id: String) -> bool:
		return true

	func is_player_online(_user_id: String) -> bool:
		return true

	func dispose() -> void:
		pass

	func _emit_snapshot() -> void:
		snapshot_received.emit(snapshot)


func _init() -> void:
	if not _parse_arguments(OS.get_cmdline_user_args()):
		return
	DisplayServer.window_set_size(_viewport)
	call_deferred("_mount")


func _mount() -> void:
	var scene: Control = CHINESE_CHECKERS_SCENE.instantiate()
	var client := PreviewClient.new()
	client.local_user_id = WHITE_ID if _state_name == "own_white" else BLACK_ID
	client.snapshot = _terminal_snapshot() if _state_name == "terminal" \
		else _goal_ready_snapshot() if _state_name == "winning" \
		else _snapshot("white" if _state_name in ["opponent", "own_white"] else "black")
	if not scene.configure_launch({
		"game_id": "chinese_checkers", "match_id": MATCH_ID,
		"launch_ticket": "preview-ticket", "ws_url": "ws://preview.local",
	}):
		push_error("Chinese Checkers preview failed to configure")
		quit(1)
		return
	scene.set_match_client_factory(func() -> PreviewClient: return client)
	scene.set_quit_callback(func() -> void: pass)
	get_root().add_child(scene)
	if _theme_name != "system":
		scene.theme = GAMEBOX_THEME.create(_theme_name == "dark")
	if _state_name == "pending":
		_show_pending.call_deferred(scene)
	elif _state_name in ["accepted", "winning"]:
		_show_accepted.call_deferred(scene, client, _state_name == "winning")
	if not _screenshot_path.is_empty():
		_capture_screenshot.call_deferred()


func _show_pending(scene: Control) -> void:
	await process_frame
	await process_frame
	scene._on_hole_pressed(6)
	scene._on_hole_pressed(14)


func _show_accepted(scene: Control, client: PreviewClient, winning: bool) -> void:
	await process_frame
	await process_frame
	var path := [102, 111] if winning else [3, 16]
	scene._on_hole_pressed(path[0])
	scene._on_hole_pressed(path[1])
	var accepted := _accepted_move(winning)
	var applied: Dictionary = client.state.apply_event(accepted)
	if not applied.get("ok", false) or applied.get("status") != "applied":
		push_error("Chinese Checkers preview failed to apply accepted move")
		quit(1)
		return
	client.event_received.emit(accepted)
	var board := scene.get_node("Board")
	board.set_process(false)
	board._process(0.1)
	board.set_process(false)


func _capture_screenshot() -> void:
	for _frame in 7:
		await process_frame
	# A fresh dark-theme render can finish its GPU readback after the first drawn
	# frame on Metal. Let the production board settle, then cross three completed
	# draw boundaries so narrow-viewport screenshots are deterministic.
	await create_timer(1.0).timeout
	for _frame in 3:
		await RenderingServer.frame_post_draw
		await process_frame
	RenderingServer.force_draw()
	RenderingServer.force_sync()
	var error := get_root().get_texture().get_image().save_png(_screenshot_path)
	if error != OK:
		push_error("Chinese Checkers preview screenshot failed: %s" % error_string(error))
		quit(1)
		return
	print("Chinese Checkers preview saved: %s" % _screenshot_path)
	quit()


func _snapshot(next_color: String) -> Dictionary:
	var board: Array = []
	board.resize(121)
	board.fill(0)
	for index in 10:
		board[index] = 1
	for index in range(111, 121):
		board[index] = 2
	return {
		"protocolVersion": 1, "gameId": "chinese_checkers", "matchId": MATCH_ID,
		"revision": 1 if next_color == "white" else 0, "type": "platform.snapshot",
		"payload": {
			"status": "active", "board": board,
			"blackUserId": BLACK_ID, "whiteUserId": WHITE_ID, "nextColor": next_color,
			"winnerUserId": null, "result": null,
		},
	}


func _terminal_snapshot() -> Dictionary:
	var snapshot := _snapshot("white")
	snapshot["revision"] = 2
	snapshot["payload"]["status"] = "finished"
	snapshot["payload"]["winnerUserId"] = WHITE_ID
	snapshot["payload"]["result"] = "resignation"
	return snapshot


func _goal_ready_snapshot() -> Dictionary:
	var board: Array = []
	board.resize(121)
	board.fill(0)
	for index in [112, 113, 114, 115, 116, 117, 118, 119, 120, 102]:
		board[index] = 1
	for index in [23, 24, 25, 26, 27, 28, 29, 30, 31, 32]:
		board[index] = 2
	var snapshot := _snapshot("black")
	snapshot["revision"] = 20
	snapshot["payload"]["board"] = board
	return snapshot


func _accepted_move(winning: bool) -> Dictionary:
	return {
		"protocolVersion": 1, "gameId": "chinese_checkers", "matchId": MATCH_ID,
		"revision": 21 if winning else 1,
		"type": "chinese_checkers.move.accepted", "actionId": ACTION_ID,
		"payload": {"userId": BLACK_ID, "color": "black", "path": [102, 111] if winning else [3, 16]},
	}


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
				if _state_name not in ["own", "own_white", "opponent", "pending", "accepted", "winning", "terminal"]:
					push_error("Unknown preview state: %s" % _state_name)
					quit(2)
					return false
			"--viewport":
				_viewport = _parse_viewport(args[index + 1])
				if _viewport == Vector2i.ZERO:
					push_error("Viewport must be WIDTHxHEIGHT")
					quit(2)
					return false
			"--screenshot":
				_screenshot_path = args[index + 1]
				if _screenshot_path.is_empty():
					push_error("Screenshot path must not be empty")
					quit(2)
					return false
			"--theme":
				_theme_name = args[index + 1]
				if _theme_name not in ["system", "light", "dark"]:
					push_error("Theme must be system, light, or dark")
					quit(2)
					return false
			_:
				push_error("Unknown preview option: %s" % args[index])
				quit(2)
				return false
		index += 2
	return true


func _parse_viewport(value: String) -> Vector2i:
	var parts := value.split("x", false)
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return Vector2i.ZERO
	var result := Vector2i(parts[0].to_int(), parts[1].to_int())
	return result if result.x >= 320 and result.y >= 640 else Vector2i.ZERO
