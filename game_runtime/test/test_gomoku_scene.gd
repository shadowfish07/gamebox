extends RefCounted

const GomokuScene = preload("res://games/gomoku/gomoku_scene.tscn")
const GomokuState = preload("res://games/gomoku/gomoku_state.gd")

const MATCH_ID := "11111111-1111-4111-8111-111111111111"
const BLACK_ID := "22222222-2222-4222-8222-222222222222"
const WHITE_ID := "33333333-3333-4333-8333-333333333333"
const ACTION_ID := "44444444-4444-4444-8444-444444444444"


static func cases() -> Array:
	return [
		{"name": "gomoku scene renders connection turns and safe errors", "run": _renders_live_states},
		{"name": "gomoku scene renders every terminal outcome", "run": _renders_terminal_states},
		{"name": "gomoku scene blocks actions while stale snapshot is pending", "run": _blocks_stale_actions},
		{"name": "gomoku scene gates resign and keeps back non-destructive", "run": _gates_resign_and_back},
		{"name": "gomoku scene wires move once and shows pending marker", "run": _wires_move_once},
		{"name": "gomoku scene keeps fixed portrait board and touch targets", "run": _keeps_portrait_touch_layout},
		{"name": "gomoku scene disposes client and callbacks once", "run": _disposes_once},
	]


static func _renders_live_states() -> bool:
	var harness: Dictionary = await _scene_harness(BLACK_ID)
	var scene: Control = harness["scene"]
	var client: FakeMatchClient = harness["client"]
	if not _check(_status(scene) == "连接中", "initial connecting copy changed"):
		return _cleanup(scene)
	client.set_connection("reconnecting")
	if not _check(_status(scene) == "重连中", "reconnecting copy changed"):
		return _cleanup(scene)
	client.accept_snapshot(_snapshot(0))
	if not _check(_status(scene) == "轮到我", "local turn copy changed") \
		or not _check((scene.get_node("Board") as Control).mouse_filter == Control.MOUSE_FILTER_STOP, "board not interactive on local turn"):
		return _cleanup(scene)
	var one_stone := _empty_board()
	one_stone[0] = 1
	client.accept_snapshot(_snapshot(1, one_stone, "active", "white"))
	if not _check(_status(scene) == "等待对手", "opponent turn copy changed"):
		return _cleanup(scene)
	client.emit_error("cell_occupied")
	if not _check(_error(scene) == "这个位置已经有棋子", "cell occupied copy changed"):
		return _cleanup(scene)
	client.emit_error("stale_revision")
	if not _check(_error(scene) == "棋盘已更新，正在同步", "stale revision copy changed"):
		return _cleanup(scene)
	client.accept_snapshot(_snapshot(1, one_stone, "active", "white"))
	var result := _check(_error(scene).is_empty(), "authoritative snapshot did not clear stale error")
	return _cleanup(scene, result)


static func _renders_terminal_states() -> bool:
	var five := _five_board()
	if not await _assert_terminal(BLACK_ID, _snapshot(9, five, "finished", "white", "five", BLACK_ID), "你赢了"):
		return false
	if not await _assert_terminal(WHITE_ID, _snapshot(9, five, "finished", "white", "five", BLACK_ID), "你输了"):
		return false
	if not await _assert_terminal(BLACK_ID, _snapshot(225, _draw_board(), "finished", "white", "draw", null), "和棋"):
		return false
	return await _assert_terminal(BLACK_ID, _snapshot(1, _empty_board(), "abandoned", "black", null, null), "对局已作废")


static func _blocks_stale_actions() -> bool:
	var harness: Dictionary = await _scene_harness(BLACK_ID)
	var scene: Control = harness["scene"]
	var client: FakeMatchClient = harness["client"]
	client.accept_snapshot(_snapshot(0))
	client.emit_error("stale_revision")
	scene._on_cell_pressed(7, 7)
	if not _check(client.move_requests.is_empty(), "stale state accepted a move before snapshot"):
		return _cleanup(scene)
	client.accept_snapshot(_snapshot(0))
	scene._on_cell_pressed(7, 7)
	return _cleanup(scene, _check(client.move_requests == [Vector2i(7, 7)], "fresh snapshot did not restore move input"))


static func _assert_terminal(local_user_id: String, snapshot: Dictionary, expected_status: String) -> bool:
	var harness: Dictionary = await _scene_harness(local_user_id)
	var scene: Control = harness["scene"]
	var client: FakeMatchClient = harness["client"]
	client.accept_snapshot(snapshot)
	var result := _check(_status(scene) == expected_status, "terminal copy changed: %s" % expected_status) \
		and _check(_back_text(scene) == "返回大厅", "terminal back copy changed") \
		and _check(not scene.get_node("ResignButton").visible, "resign visible after terminal state")
	return _cleanup(scene, result)


static func _gates_resign_and_back() -> bool:
	var harness: Dictionary = await _scene_harness(BLACK_ID)
	var scene: Control = harness["scene"]
	var client: FakeMatchClient = harness["client"]
	var quit_calls: Array[int] = harness["quit_calls"]
	client.accept_snapshot(_snapshot(0))
	if not _check(not scene.get_node("ResignButton").visible, "resign visible before first move"):
		return _cleanup(scene)
	var one_stone := _empty_board()
	one_stone[0] = 1
	client.accept_snapshot(_snapshot(1, one_stone, "active", "white"))
	if not _check(scene.get_node("ResignButton").visible, "resign hidden after first move"):
		return _cleanup(scene)
	scene._on_resign_pressed()
	if not _check(client.resign_requests == 1, "visible resign did not submit exactly once") \
		or not _check(not scene.get_node("ResignButton").visible, "pending resignation left resign enabled"):
		return _cleanup(scene)
	var resigns_before_back := client.resign_requests
	scene._on_back_pressed()
	scene._on_back_pressed()
	var result := _check(client.resign_requests == resigns_before_back, "ordinary back sent resignation") \
		and _check(quit_calls.size() == 1, "ordinary back did not quit exactly once")
	return _cleanup(scene, result)


static func _wires_move_once() -> bool:
	var harness: Dictionary = await _scene_harness(BLACK_ID)
	var scene: Control = harness["scene"]
	var client: FakeMatchClient = harness["client"]
	client.accept_snapshot(_snapshot(0))
	scene._on_cell_pressed(7, 7)
	scene._on_cell_pressed(8, 8)
	var board = scene.get_node("Board")
	if not (_check(client.move_requests == [Vector2i(7, 7)], "pending move allowed duplicate request") \
		and _check(board.stone_at(7, 7) == 0, "local request mutated authoritative board") \
		and _check(board.pending_cell == Vector2i(7, 7), "pending marker not refreshed")):
		return _cleanup(scene)
	client.accept_event(_move(1, BLACK_ID, "black", 7, 7))
	var result := _check(board.stone_at(7, 7) == 1, "accepted event did not place authoritative stone") \
		and _check(board.pending_cell == Vector2i(-1, -1), "accepted event did not clear pending marker") \
		and _check(board.last_move_cell == Vector2i(7, 7), "accepted event did not mark last move")
	return _cleanup(scene, result)


static func _keeps_portrait_touch_layout() -> bool:
	var harness: Dictionary = await _scene_harness(BLACK_ID)
	var scene: Control = harness["scene"]
	var board: Control = scene.get_node("Board")
	var back: Button = scene.get_node("BackButton")
	var resign: Button = scene.get_node("ResignButton")
	var result := _check(board.position.is_equal_approx(Vector2(60.0, 360.0)), "fixed board origin changed: %s" % board.position) \
		and _check(board.size.is_equal_approx(Vector2(960.0, 960.0)), "fixed board stopped being square: %s" % board.size) \
		and _check(back.size.x >= 192.0 and back.size.y >= 96.0, "back touch target too small") \
		and _check(resign.size.x >= 372.0 and resign.size.y >= 104.0, "resign touch target too small") \
		and _check(back.position.x >= 48.0 and back.position.y >= 72.0, "back button left portrait safe margin")
	return _cleanup(scene, result)


static func _disposes_once() -> bool:
	var harness: Dictionary = await _scene_harness(BLACK_ID)
	var scene: Control = harness["scene"]
	var client: FakeMatchClient = harness["client"]
	scene._exit_tree()
	scene._exit_tree()
	var result := _check(client.dispose_calls == 1, "client disposed more than once")
	return _cleanup(scene, result)


static func _scene_harness(local_user_id: String) -> Dictionary:
	var tree := Engine.get_main_loop() as SceneTree
	var fake := FakeMatchClient.new()
	fake.local_user_id = local_user_id
	var scene := GomokuScene.instantiate()
	scene.configure_launch(_launch_config())
	scene.set_match_client_factory(func() -> Variant: return fake)
	var quit_calls: Array[int] = []
	scene.set_quit_callback(func() -> void: quit_calls.append(1))
	tree.root.add_child(scene)
	await tree.process_frame
	return {"scene": scene, "client": fake, "quit_calls": quit_calls}


static func _cleanup(scene: Control, result: bool = false) -> bool:
	if is_instance_valid(scene):
		scene.free()
	return result


static func _status(scene: Control) -> String:
	return (scene.get_node("StatusLabel") as Label).text


static func _error(scene: Control) -> String:
	return (scene.get_node("ErrorLabel") as Label).text


static func _back_text(scene: Control) -> String:
	return (scene.get_node("BackButton") as Button).text


static func _launch_config() -> Dictionary:
	return {"game_id": "gomoku", "match_id": MATCH_ID, "launch_ticket": "opaque-test-ticket", "ws_url": "ws://127.0.0.1:8080/v1/ws"}


static func _snapshot(
	revision: int,
	board: Array = [],
	status: String = "active",
	next_color: String = "black",
	result: Variant = null,
	winner: Variant = null
) -> Dictionary:
	return {
		"protocolVersion": 1, "gameId": "gomoku", "matchId": MATCH_ID,
		"revision": revision, "type": "platform.snapshot",
		"payload": {
			"status": status, "board": _empty_board() if board.is_empty() else board.duplicate(), "boardSize": 15,
			"blackUserId": BLACK_ID, "whiteUserId": WHITE_ID, "nextColor": next_color,
			"winnerUserId": winner, "result": result,
		},
	}


static func _move(revision: int, user_id: String, color: String, x: int, y: int) -> Dictionary:
	return {
		"protocolVersion": 1, "gameId": "gomoku", "matchId": MATCH_ID,
		"revision": revision, "type": "gomoku.move.accepted", "actionId": ACTION_ID,
		"payload": {"userId": user_id, "color": color, "x": x, "y": y},
	}


static func _empty_board() -> Array:
	var board: Array = []
	board.resize(225)
	board.fill(0)
	return board


static func _five_board() -> Array:
	var board := _empty_board()
	for x in 5:
		board[x] = 1
	for x in 4:
		board[15 + x] = 2
	return board


static func _draw_board() -> Array:
	var board := _empty_board()
	for y in 15:
		for x in 15:
			board[y * 15 + x] = 1 if ((x + 2 * y) % 4) < 2 else 2
	return board


static func _check(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition


class FakeMatchClient:
	extends RefCounted

	signal connection_state_changed(next_state: String)
	signal snapshot_received(envelope: Dictionary)
	signal event_received(envelope: Dictionary)
	signal match_error(code: String)
	signal return_to_lobby_requested(code: String)

	var connection_state := "closed"
	var local_user_id := ""
	var state: Variant
	var move_requests: Array[Vector2i] = []
	var resign_requests := 0
	var dispose_calls := 0

	func start(_ws_url: String, _match_id: String, _ticket: String, game_state: Variant) -> bool:
		state = game_state
		connection_state = "connecting"
		return true

	func poll() -> void:
		pass

	func request_move(x: int, y: int) -> String:
		if not state.can_request_move(x, y, local_user_id):
			return ""
		if not state.mark_pending(ACTION_ID, x, y):
			return ""
		move_requests.append(Vector2i(x, y))
		return ACTION_ID

	func request_resign() -> String:
		resign_requests += 1
		return ACTION_ID if state.mark_pending_resign(ACTION_ID, local_user_id) else ""

	func dispose() -> void:
		dispose_calls += 1

	func set_connection(next_state: String) -> void:
		connection_state = next_state
		connection_state_changed.emit(next_state)

	func accept_snapshot(envelope: Dictionary) -> void:
		var applied: Dictionary = state.apply_snapshot(envelope)
		if not applied.get("ok", false):
			push_error("fake snapshot invalid")
			return
		connection_state = "connected"
		connection_state_changed.emit(connection_state)
		snapshot_received.emit(envelope)

	func emit_error(code: String) -> void:
		match_error.emit(code)

	func accept_event(envelope: Dictionary) -> void:
		var applied: Dictionary = state.apply_event(envelope)
		if not applied.get("ok", false):
			push_error("fake event invalid")
			return
		event_received.emit(envelope)
