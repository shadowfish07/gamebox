extends RefCounted

const ChineseCheckersScene = preload("res://games/chinese_checkers/chinese_checkers_scene.tscn")

const MATCH_ID := "11111111-1111-4111-8111-111111111111"
const BLACK_ID := "22222222-2222-4222-8222-222222222222"
const WHITE_ID := "33333333-3333-4333-8333-333333333333"
const ACTION_ID := "44444444-4444-4444-8444-444444444444"


static func cases() -> Array:
	return [
		{"name": "chinese checkers scene uses the direct lightweight board shell", "run": _uses_direct_lightweight_shell},
		{"name": "chinese checkers scene submits a highlighted endpoint without confirmation", "run": _submits_direct_endpoint},
		{"name": "chinese checkers scene preserves and locks the board during reconnect", "run": _locks_during_reconnect},
		{"name": "chinese checkers Back returns without resigning", "run": _back_is_non_destructive},
		{"name": "chinese checkers scene presents an authoritative result", "run": _presents_authoritative_result},
		{"name": "chinese checkers scene plays confirmed move sound for either player", "run": _plays_confirmed_move_sound_for_either_player},
	]


static func _uses_direct_lightweight_shell() -> bool:
	var harness: Dictionary = await _scene_harness(BLACK_ID)
	var scene: Control = harness["scene"]
	var top_bar = scene.get_node("TopNavigation")
	var board := scene.get_node("Board") as Control
	var result := _check(scene.theme != null, "Gamebox Theme is not applied") \
		and _check(scene.has_node("ConnectionLabel/Content/Message"), "compact connection banner is missing") \
		and _check(not scene.has_node("LoadingOverlay"), "direct board flow introduced a blocking loader") \
		and _check(top_bar.get_node("MenuLayer/MenuRoot/MenuPanel/Items").get_child_count() == 1, "overflow must contain only resignation") \
		and _check(not scene.has_node("MoveConfirmation"), "direct endpoint flow mounted a confirmation surface") \
		and _check(board.custom_minimum_size == Vector2(960, 1050), "portrait board size changed") \
		and _check(board.has_signal("hole_pressed"), "board interaction signal is missing") \
		and _check((scene.get_node("ConnectionLabel/Content/Message") as Label).text == "连接中…", "initial compact status changed")
	return _cleanup(scene, result)


static func _submits_direct_endpoint() -> bool:
	var harness: Dictionary = await _scene_harness(BLACK_ID)
	var scene: Control = harness["scene"]
	var client: FakeMatchClient = harness["client"]
	client.accept_snapshot(_snapshot(0))
	scene._on_hole_pressed(6)
	var board = scene.get_node("Board")
	if not _check(board.selected_hole == 6, "own piece was not selected") \
		or not _check(board.target_holes.has(14), "legal direct endpoint was not highlighted"):
		return _cleanup(scene)
	scene._on_hole_pressed(14)
	var result := _check(client.path_requests == [[6, 14]], "endpoint did not submit its full path exactly once") \
		and _check(board.pending_path == [6, 14], "submitted path is not shown as pending") \
		and _check(board.stone_at(6) == 1 and board.stone_at(14) == 0, "pending UI changed the authoritative board") \
		and _check(board.mouse_filter == Control.MOUSE_FILTER_IGNORE, "pending board still accepts input") \
		and _check(not scene.has_node("MoveConfirmation"), "endpoint unexpectedly opened confirmation")
	return _cleanup(scene, result)


static func _locks_during_reconnect() -> bool:
	var harness: Dictionary = await _scene_harness(BLACK_ID)
	var scene: Control = harness["scene"]
	var client: FakeMatchClient = harness["client"]
	client.accept_snapshot(_snapshot(0))
	scene._on_hole_pressed(6)
	client.set_connection("reconnecting")
	var board = scene.get_node("Board")
	var result := _check(board.stone_at(6) == 1, "reconnect discarded the last authoritative board") \
		and _check(board.selected_hole == -1 and board.target_holes.is_empty(), "reconnect retained a stale selection") \
		and _check(board.mouse_filter == Control.MOUSE_FILTER_IGNORE, "reconnect did not lock board input") \
		and _check(scene.get_node("ConnectionLabel").visible, "reconnect compact banner is hidden") \
		and _check(not scene.get_node("PlayerStrip").visible, "reconnect player strip overlaps the connection banner") \
		and _check((scene.get_node("ConnectionLabel/Content/Message") as Label).text == "重连中…", "reconnect copy changed") \
		and _check((scene.get_node("HintLabel") as Label).text.contains("棋盘会保留"), "reconnect does not explain preserved board state")
	return _cleanup(scene, result)


static func _back_is_non_destructive() -> bool:
	var harness: Dictionary = await _scene_harness(BLACK_ID)
	var scene: Control = harness["scene"]
	var client: FakeMatchClient = harness["client"]
	var quit_calls: Array = harness["quit_calls"]
	client.accept_snapshot(_snapshot(0))
	(scene.get_node("TopNavigation/BackButton") as Button).pressed.emit()
	var result := _check(client.resign_requests == 0, "Back submitted resignation") \
		and _check(client.dispose_calls == 1, "Back did not dispose exactly once") \
		and _check(quit_calls.size() == 1, "Back did not return exactly once")
	return _cleanup(scene, result)


static func _presents_authoritative_result() -> bool:
	var harness: Dictionary = await _scene_harness(BLACK_ID)
	var scene: Control = harness["scene"]
	var client: FakeMatchClient = harness["client"]
	client.accept_snapshot(_snapshot(2, "finished", "white", "resignation", BLACK_ID))
	var result := _check(scene.get_node("ResultPanel").visible, "terminal result panel is hidden") \
		and _check((scene.get_node("ResultPanel/Content/Result") as Label).text == "对手已认输", "authoritative result copy changed") \
		and _check((scene.get_node("PlayerStrip/Content/Turn") as Label).text == "对局结束", "terminal turn chip retained an active-turn label") \
		and _check((scene.get_node("HintLabel") as Label).text == "对局已结束，结果已由服务器确认", "terminal hint retained active-play copy") \
		and _check(scene.get_node("Board").mouse_filter == Control.MOUSE_FILTER_IGNORE, "terminal board accepts input")
	return _cleanup(scene, result)


static func _plays_confirmed_move_sound_for_either_player() -> bool:
	for local_user_id in [BLACK_ID, WHITE_ID]:
		var harness: Dictionary = await _scene_harness(local_user_id)
		var scene: Control = harness["scene"]
		var client: FakeMatchClient = harness["client"]
		var sound := scene.get_node_or_null("MoveSound") as AudioStreamPlayer
		if not _check(sound != null and sound.stream != null, "confirmed move sound is not configured"):
			return _cleanup(scene)
		client.accept_snapshot(_snapshot(0))
		if not _check(not sound.playing, "authoritative snapshot replayed move sound"):
			return _cleanup(scene)
		client.accept_event(_move(1, BLACK_ID, "black", [6, 14]))
		if not _check(sound.playing, "confirmed move was silent for local user %s" % local_user_id):
			return _cleanup(scene)
		sound.stop()
		client.event_received.emit(_move(1, BLACK_ID, "black", [6, 14]))
		if not _check(not sound.playing, "duplicate confirmed move replayed its sound"):
			return _cleanup(scene)
		_cleanup(scene, true)
	return true


static func _scene_harness(local_user_id: String) -> Dictionary:
	var scene := ChineseCheckersScene.instantiate() as Control
	var client := FakeMatchClient.new()
	client.local_user_id = local_user_id
	var quit_calls: Array = []
	scene.configure_launch({
		"game_id": "chinese_checkers",
		"match_id": MATCH_ID,
		"launch_ticket": "opaque-test-ticket",
		"ws_url": "ws://127.0.0.1:8080/v1/ws",
	})
	scene.set_match_client_factory(func() -> Variant: return client)
	scene.set_quit_callback(func() -> void: quit_calls.append(true))
	(Engine.get_main_loop() as SceneTree).root.add_child(scene)
	await (Engine.get_main_loop() as SceneTree).process_frame
	return {"scene": scene, "client": client, "quit_calls": quit_calls}


static func _snapshot(
	revision: int,
	status: String = "active",
	next_color: String = "black",
	result: Variant = null,
	winner: Variant = null,
) -> Dictionary:
	return {
		"protocolVersion": 1, "gameId": "chinese_checkers", "matchId": MATCH_ID,
		"revision": revision, "type": "platform.snapshot",
		"payload": {
			"status": status, "board": _initial_board(),
			"blackUserId": BLACK_ID, "whiteUserId": WHITE_ID, "nextColor": next_color,
			"winnerUserId": winner, "result": result,
		},
	}


static func _move(revision: int, user_id: String, color: String, path: Array) -> Dictionary:
	return {
		"protocolVersion": 1, "gameId": "chinese_checkers", "matchId": MATCH_ID,
		"revision": revision, "type": "chinese_checkers.move.accepted", "actionId": ACTION_ID,
		"payload": {"userId": user_id, "color": color, "path": path.duplicate()},
	}


static func _initial_board() -> Array:
	var board: Array = []
	board.resize(121)
	board.fill(0)
	for index in 10:
		board[index] = 1
	for index in range(111, 121):
		board[index] = 2
	return board


static func _cleanup(scene: Control, result: bool = false) -> bool:
	if is_instance_valid(scene):
		scene.free()
	return result


static func _check(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition


class FakeMatchClient:
	extends RefCounted

	signal connection_state_changed(next_state: String)
	signal snapshot_sync_started
	signal snapshot_received(envelope: Dictionary)
	signal event_received(envelope: Dictionary)
	signal player_presence_changed(user_id: String, online: bool)
	signal match_error(code: String)
	signal return_to_lobby_requested(code: String)

	var connection_state := "closed"
	var local_user_id := ""
	var state: Variant
	var game_id := ""
	var path_requests: Array = []
	var resign_requests := 0
	var dispose_calls := 0
	var player_presence := {BLACK_ID: true, WHITE_ID: true}

	func start(_ws_url: String, _match_id: String, _ticket: String, game_state: Variant, requested_game_id: String) -> bool:
		state = game_state
		game_id = requested_game_id
		connection_state = "connecting"
		return requested_game_id == "chinese_checkers"

	func poll() -> void:
		pass

	func request_chinese_checkers_move(path: Array) -> String:
		if not state.mark_pending_path(ACTION_ID, path, local_user_id):
			return ""
		path_requests.append(path.duplicate())
		return ACTION_ID

	func request_resign() -> String:
		resign_requests += 1
		return ACTION_ID if state.mark_pending_resign(ACTION_ID, local_user_id) else ""

	func has_player_presence(user_id: String) -> bool:
		return player_presence.has(user_id)

	func is_player_online(user_id: String) -> bool:
		return bool(player_presence.get(user_id, false))

	func dispose() -> void:
		dispose_calls += 1

	func set_connection(next_state: String) -> void:
		connection_state = next_state
		connection_state_changed.emit(next_state)

	func accept_snapshot(envelope: Dictionary) -> void:
		connection_state = "connected"
		connection_state_changed.emit(connection_state)
		snapshot_received.emit(envelope)

	func accept_event(envelope: Dictionary) -> void:
		var applied: Dictionary = state.apply_event(envelope)
		if not applied.get("ok", false):
			push_error("fake event invalid")
			return
		event_received.emit(envelope)
