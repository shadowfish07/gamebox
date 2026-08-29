extends SceneTree

# Development-only desktop renderer for visual Gomoku iteration. This file
# lives outside game_runtime so it is not packaged into the Android game.
const GOMOKU_SCENE := preload("res://games/gomoku/gomoku_scene.tscn")
const GAMEBOX_THEME := preload("res://design_system/gamebox_theme.gd")
const GAMEBOX_TOKENS := preload("res://design_system/generated/gamebox_tokens.gd")
const MATCH_ID := "11111111-1111-4111-8111-111111111111"
const BLACK_ID := "22222222-2222-4222-8222-222222222222"
const WHITE_ID := "33333333-3333-4333-8333-333333333333"
const ACTION_ID := "44444444-4444-4444-8444-444444444444"

var _state_name := "finished_win"
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
	var _state_name := "finished_win"
	var _snapshot_envelope := {}

	func start(_ws_url: String, _match_id: String, _ticket: String, _state: Variant) -> bool:
		if connection_state == "connecting":
			return true
		if _state_name == "resignation_move_loss":
			call_deferred("_emit_resignation_sequence")
			return true
		call_deferred("_emit_snapshot")
		return true

	func poll() -> void:
		pass

	func request_move(_x: int, _y: int) -> String:
		return ""

	func request_resign() -> String:
		return ""

	func has_player_presence(_user_id: String) -> bool:
		return true

	func is_player_online(_user_id: String) -> bool:
		return true

	func dispose() -> void:
		pass

	func _emit_snapshot() -> void:
		snapshot_received.emit(_snapshot_envelope)

	func _emit_resignation_sequence() -> void:
		var board: Array = []
		board.resize(225)
		board.fill(0)
		snapshot_received.emit({
			"protocolVersion": 1, "gameId": "gomoku", "matchId": MATCH_ID,
			"revision": 0, "type": "platform.snapshot",
			"payload": {
				"status": "active", "board": board, "boardSize": 15,
				"blackUserId": BLACK_ID, "whiteUserId": WHITE_ID, "nextColor": "black",
				"winnerUserId": null, "result": null,
			},
		})
		event_received.emit({
			"protocolVersion": 1, "gameId": "gomoku", "matchId": MATCH_ID,
			"revision": 1, "type": "gomoku.move.accepted", "actionId": ACTION_ID,
			"payload": {"userId": BLACK_ID, "color": "black", "x": 7, "y": 7},
		})
		event_received.emit({
			"protocolVersion": 1, "gameId": "gomoku", "matchId": MATCH_ID,
			"revision": 2, "type": "gomoku.resigned", "actionId": ACTION_ID,
			"payload": {"userId": BLACK_ID, "winnerUserId": WHITE_ID},
		})


func _init() -> void:
	_parse_arguments(OS.get_cmdline_user_args())
	DisplayServer.window_set_size(_viewport)
	call_deferred("_mount")


func _mount() -> void:
	var local_won := _state_name not in ["finished_loss", "review_loss", "resignation_loss", "resignation_move_loss"]
	var scene: Control = GOMOKU_SCENE.instantiate()
	var client := PreviewClient.new()
	client.connection_state = "connecting" if _state_name == "connecting" else "connected"
	client.local_user_id = BLACK_ID if local_won else WHITE_ID
	client._state_name = _state_name
	if _state_name == "resignation_move_loss":
		client.local_user_id = BLACK_ID
	if _state_name != "connecting":
		client._snapshot_envelope = _terminal_snapshot(_state_name.begins_with("resignation_"))
	if not scene.configure_launch({
		"game_id": "gomoku", "match_id": MATCH_ID,
		"launch_ticket": "preview-ticket", "ws_url": "ws://preview.local",
	}):
		push_error("Gomoku preview failed to configure")
		quit(1)
		return
	scene.set_match_client_factory(func() -> PreviewClient: return client)
	scene.set_quit_callback(func() -> void: pass)
	get_root().add_child(scene)
	_apply_preview_theme(scene)
	if _state_name in ["review_win", "review_loss"]:
		_show_review.call_deferred(scene)
	if not _screenshot_path.is_empty():
		_capture_screenshot.call_deferred()


func _show_review(scene: Control) -> void:
	await process_frame
	await process_frame
	(scene.get_node("ResultPanel/Content/Actions/ReviewButton") as Button).pressed.emit()
	await process_frame


func _capture_screenshot() -> void:
	for _frame in 5:
		await process_frame
	await RenderingServer.frame_post_draw
	var error := get_root().get_texture().get_image().save_png(_screenshot_path)
	if error != OK:
		push_error("Gomoku preview screenshot failed: %s" % error_string(error))
		quit(1)
		return
	print("Gomoku preview saved: %s" % _screenshot_path)
	quit()


func _apply_preview_theme(scene: Control) -> void:
	if _theme_name == "system":
		return
	var dark := _theme_name == "dark"
	scene.theme = GAMEBOX_THEME.create(dark)
	var colors: Dictionary = GAMEBOX_TOKENS.DARK if dark else GAMEBOX_TOKENS.LIGHT
	(scene.get_node("ResultScrim") as ColorRect).color = Color(colors["scrim"], GAMEBOX_TOKENS.COMPONENT["dialog_scrim_opacity"])


func _terminal_snapshot(resignation: bool = false) -> Dictionary:
	var board: Array = []
	board.resize(225)
	board.fill(0)
	var black_stones := 2 if resignation else 5
	var white_stones := 2 if resignation else 4
	for x in black_stones:
		board[7 * 15 + 5 + x] = 1
	for x in white_stones:
		board[8 * 15 + 5 + x] = 2
	return {
		"protocolVersion": 1, "gameId": "gomoku", "matchId": MATCH_ID,
		"revision": 5 if resignation else 9, "type": "platform.snapshot",
		"payload": {
			"status": "finished", "board": board, "boardSize": 15,
			"blackUserId": BLACK_ID, "whiteUserId": WHITE_ID, "nextColor": "black" if resignation else "white",
			"winnerUserId": BLACK_ID, "result": "resignation" if resignation else "five",
		},
	}


func _parse_arguments(args: PackedStringArray) -> void:
	var index := 0
	while index < args.size():
		if index + 1 >= args.size():
			push_error("Expected a value after %s" % args[index])
			quit(2)
			return
		match args[index]:
			"--state":
				_state_name = args[index + 1]
				if _state_name not in ["connecting", "finished_win", "finished_loss", "review_win", "review_loss", "resignation_win", "resignation_loss", "resignation_move_loss"]:
					push_error("Unknown preview state: %s" % _state_name)
					quit(2)
					return
			"--viewport":
				_viewport = _parse_viewport(args[index + 1])
				if _viewport == Vector2i.ZERO:
					push_error("Viewport must be WIDTHxHEIGHT")
					quit(2)
					return
			"--screenshot":
				_screenshot_path = args[index + 1]
				if _screenshot_path.is_empty():
					push_error("Screenshot path must not be empty")
					quit(2)
					return
			"--theme":
				_theme_name = args[index + 1]
				if _theme_name not in ["system", "light", "dark"]:
					push_error("Theme must be system, light, or dark")
					quit(2)
					return
			_:
				push_error("Unknown preview option: %s" % args[index])
				quit(2)
				return
		index += 2


func _parse_viewport(value: String) -> Vector2i:
	var parts := value.split("x", false)
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return Vector2i.ZERO
	var result := Vector2i(parts[0].to_int(), parts[1].to_int())
	return result if result.x >= 320 and result.y >= 640 else Vector2i.ZERO
