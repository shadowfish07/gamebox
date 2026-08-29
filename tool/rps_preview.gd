extends SceneTree

# Development-only desktop renderer for visual RPS iteration.  This file lives
# outside game_runtime so it is not packaged into the Android game.
const RPS_SCENE := preload("res://games/rps/rps_scene.tscn")
const GAMEBOX_THEME := preload("res://design_system/gamebox_theme.gd")
const GAMEBOX_TOKENS := preload("res://design_system/generated/gamebox_tokens.gd")
const MATCH_ID := "11111111-1111-4111-8111-111111111111"
const ME := "22222222-2222-4222-8222-222222222222"
const OPPONENT := "33333333-3333-4333-8333-333333333333"

var _state_name := "ready"
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

	var local_user_id := ME
	var connection_state := "connected"
	var _state: Variant
	var _state_name := "ready"
	var _delay_reveal := true

	func start(_ws_url: String, _match_id: String, _ticket: String, state: Variant, _game_id: String) -> bool:
		_state = state
		if _state_name == "connecting":
			connection_state = "connecting"
			return true
		_state.apply_snapshot(_snapshot())
		if _state_name == "pending":
			_state.mark_pending_choice("44444444-4444-4444-8444-444444444444", "paper", ME)
		call_deferred("_emit_state")
		return true

	func poll() -> void:
		pass

	func request_choice(_choice: String) -> String:
		return ""

	func request_resign() -> String:
		return ""

	func dispose() -> void:
		pass

	func _emit_state() -> void:
		snapshot_received.emit({})
		if _state_name == "reconnecting":
			connection_state = "reconnecting"
			connection_state_changed.emit(connection_state)
		elif _state_name == "syncing":
			snapshot_sync_started.emit()
		elif _state_name == "failed":
			connection_state = "failed"
			connection_state_changed.emit(connection_state)
		elif _state_name == "restored":
			connection_state = "reconnecting"
			connection_state_changed.emit(connection_state)
			connection_state = "connected"
			connection_state_changed.emit(connection_state)
			snapshot_received.emit({})
		if _state_name == "reveal":
			# Leave the base state on screen long enough for the desktop window to
			# become visible. Screenshot mode starts immediately so its bounded
			# frame capture records the requested reveal rather than the lock state.
			if _delay_reveal:
				await (Engine.get_main_loop() as SceneTree).create_timer(1.5).timeout
			var reveal_event := _reveal_event(false)
			_state.apply_event(reveal_event)
			event_received.emit(reveal_event)

	func _snapshot() -> Dictionary:
		var terminal := _state_name in ["finished", "finished_win", "finished_loss", "review_win", "review_loss", "resignation_win", "resignation_loss"]
		var local_won := _state_name not in ["finished_loss", "review_loss", "resignation_loss"]
		if terminal:
			return _terminal_snapshot(local_won, _state_name.begins_with("resignation_"))
		var me_locked := _state_name in ["locked", "resign", "reveal"]
		var opponent_locked := _state_name in ["opponent_locked", "resign", "reveal"]
		var me := {"userId": ME, "score": 0, "locked": me_locked}
		if me_locked:
			me["choice"] = "paper"
		return {
			"protocolVersion": 1, "gameId": "rps", "matchId": MATCH_ID,
			"revision": 1 if _state_name in ["resign", "menu"] else 0, "type": "platform.snapshot",
			"payload": {
				"status": "active", "format": "best_of_three", "round": 1,
				"me": me,
				"opponent": {"userId": OPPONENT, "score": 0, "locked": opponent_locked},
				"lastReveal": null, "winnerUserId": null, "result": null,
			},
		}

	func _terminal_snapshot(local_won: bool, resignation: bool = false) -> Dictionary:
		var my_choice := "paper" if local_won else "scissors"
		var opponent_choice := "rock"
		var my_score := 1 if resignation else 2 if local_won else 1
		var opponent_score := 0 if resignation else 1 if local_won else 2
		var winner := ME if local_won else OPPONENT
		return {
			"protocolVersion": 1, "gameId": "rps", "matchId": MATCH_ID,
			"revision": 3 if resignation else 4, "type": "platform.snapshot",
			"payload": {
				"status": "finished", "format": "best_of_three", "round": 2 if resignation else 3,
				"me": {"userId": ME, "score": my_score, "locked": false},
				"opponent": {"userId": OPPONENT, "score": opponent_score, "locked": false},
				"lastReveal": null if resignation else {
					"round": 3,
					"choices": {ME: my_choice, OPPONENT: opponent_choice},
					"roundWinnerUserId": winner, "draw": false,
					"scores": {ME: my_score, OPPONENT: opponent_score},
					"matchWinnerUserId": winner, "result": "rounds",
				},
				"winnerUserId": winner, "result": "resignation" if resignation else "rounds",
			},
		}

	func _reveal_event(finished: bool) -> Dictionary:
		return {
			"protocolVersion": 1, "gameId": "rps", "matchId": MATCH_ID,
			"revision": 1, "type": "rps.round.revealed",
			"payload": {
				"round": 1,
				"choices": {ME: "paper", OPPONENT: "rock"},
				"roundWinnerUserId": ME, "draw": false,
				"scores": {ME: 2 if finished else 1},
				"matchWinnerUserId": ME if finished else null,
				"result": "rounds" if finished else null,
			},
		}


func _init() -> void:
	_parse_arguments(OS.get_cmdline_user_args())
	DisplayServer.window_set_size(_viewport)
	call_deferred("_mount")


func _mount() -> void:
	var scene: Control = RPS_SCENE.instantiate()
	var client := PreviewClient.new()
	client._state_name = _state_name
	client._delay_reveal = _screenshot_path.is_empty()
	if not scene.configure_launch({
		"game_id": "rps", "match_id": MATCH_ID,
		"launch_ticket": "preview-ticket", "ws_url": "ws://preview.local",
	}):
		push_error("RPS preview failed to configure")
		quit(1)
		return
	scene.set_match_client_factory(func() -> PreviewClient: return client)
	get_root().add_child(scene)
	_apply_preview_theme(scene)
	if _state_name == "resign":
		scene.call_deferred("_on_resign_pressed")
	elif _state_name == "menu":
		_show_menu.call_deferred(scene)
	elif _state_name in ["review_win", "review_loss"]:
		_show_review.call_deferred(scene)
	if not _screenshot_path.is_empty():
		_capture_screenshot.call_deferred()


func _show_menu(scene: Control) -> void:
	await process_frame
	var action := scene.get_node("SafeContent/Layout/TopNavigation/ActionButton") as Button
	action.pressed.emit()
	await process_frame


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
		push_error("RPS preview screenshot failed: %s" % error_string(error))
		quit(1)
		return
	print("RPS preview saved: %s" % _screenshot_path)
	quit()


func _apply_preview_theme(scene: Control) -> void:
	if _theme_name == "system":
		return
	var dark := _theme_name == "dark"
	scene.theme = GAMEBOX_THEME.create(dark)
	var colors: Dictionary = GAMEBOX_TOKENS.DARK if dark else GAMEBOX_TOKENS.LIGHT
	(scene.get_node("ResultScrim") as ColorRect).color = Color(colors["scrim"], GAMEBOX_TOKENS.COMPONENT["dialog_scrim_opacity"])
	(scene.get_node("TerminalArena/Backdrop/Gradient") as ColorRect).color = Color(colors["primary_container"], GAMEBOX_TOKENS.COMPONENT["terminal_glow_opacity"])


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
				if _state_name not in ["connecting", "ready", "pending", "locked", "opponent_locked", "menu", "resign", "reveal", "finished", "finished_win", "finished_loss", "review_win", "review_loss", "resignation_win", "resignation_loss", "reconnecting", "syncing", "failed", "restored"]:
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
