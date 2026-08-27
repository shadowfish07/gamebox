extends SceneTree

# Development-only desktop renderer for visual RPS iteration.  This file lives
# outside game_runtime so it is not packaged into the Android game.
const RPS_SCENE := preload("res://games/rps/rps_scene.tscn")
const MATCH_ID := "11111111-1111-4111-8111-111111111111"
const ME := "22222222-2222-4222-8222-222222222222"
const OPPONENT := "33333333-3333-4333-8333-333333333333"

var _state_name := "ready"
var _viewport := Vector2i(720, 1600)


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

	func start(_ws_url: String, _match_id: String, _ticket: String, state: Variant, _game_id: String) -> bool:
		_state = state
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
		if _state_name in ["reveal", "finished"]:
			# Leave the base state on screen long enough for the desktop window to
			# become visible, then play the same timed reveal as production.
			await (Engine.get_main_loop() as SceneTree).create_timer(1.5).timeout
			_state.apply_event(_reveal_event(_state_name == "finished"))
			event_received.emit({})

	func _snapshot() -> Dictionary:
		var me_locked := _state_name in ["locked", "resign", "reveal", "finished"]
		var opponent_locked := _state_name in ["opponent_locked", "resign", "reveal", "finished"]
		var me := {"userId": ME, "score": 0, "locked": me_locked}
		if me_locked:
			me["choice"] = "paper"
		return {
			"protocolVersion": 1, "gameId": "rps", "matchId": MATCH_ID,
			"revision": 1 if _state_name == "resign" else 0, "type": "platform.snapshot",
			"payload": {
				"status": "active", "format": "best_of_three", "round": 1,
				"me": me,
				"opponent": {"userId": OPPONENT, "score": 0, "locked": opponent_locked},
				"lastReveal": null, "winnerUserId": null, "result": null,
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
	if not scene.configure_launch({
		"game_id": "rps", "match_id": MATCH_ID,
		"launch_ticket": "preview-ticket", "ws_url": "ws://preview.local",
	}):
		push_error("RPS preview failed to configure")
		quit(1)
		return
	scene.set_match_client_factory(func() -> PreviewClient: return client)
	get_root().add_child(scene)
	if _state_name == "resign":
		scene.call_deferred("_on_resign_pressed")


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
				if _state_name not in ["ready", "pending", "locked", "opponent_locked", "resign", "reveal", "finished"]:
					push_error("Unknown preview state: %s" % _state_name)
					quit(2)
					return
			"--viewport":
				_viewport = _parse_viewport(args[index + 1])
				if _viewport == Vector2i.ZERO:
					push_error("Viewport must be WIDTHxHEIGHT")
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
