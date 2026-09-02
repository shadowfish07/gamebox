extends RefCounted

const ChineseCheckersScene = preload("res://games/chinese_checkers/chinese_checkers_scene.tscn")
const ChineseCheckersTheme = preload("res://games/chinese_checkers/chinese_checkers_theme.gd")
const GameboxTokens = preload("res://design_system/generated/gamebox_tokens.gd")

const MATCH_ID := "11111111-1111-4111-8111-111111111111"
const BLACK_ID := "22222222-2222-4222-8222-222222222222"
const WHITE_ID := "33333333-3333-4333-8333-333333333333"
const ACTION_ID := "44444444-4444-4444-8444-444444444444"


static func cases() -> Array:
	return [
		{"name": "chinese checkers scene uses the direct lightweight board shell", "run": _uses_direct_lightweight_shell},
		{"name": "chinese checkers theme maps turn ownership surfaces", "run": _maps_turn_ownership_surfaces},
		{"name": "chinese checkers scene emphasizes the active player", "run": _emphasizes_active_player},
		{"name": "chinese checkers scene submits a highlighted endpoint without confirmation", "run": _submits_direct_endpoint},
		{"name": "chinese checkers scene animates the authoritative accepted path", "run": _animates_accepted_path},
		{"name": "chinese checkers scene cancels stale animation for a snapshot", "run": _cancels_stale_animation_for_snapshot},
		{"name": "chinese checkers scene queues consecutive accepted paths", "run": _queues_consecutive_accepted_paths},
		{"name": "chinese checkers scene presents the winning move before its result", "run": _presents_winning_move_before_result},
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


static func _maps_turn_ownership_surfaces() -> bool:
	for dark_mode in [false, true]:
		var colors: Dictionary = GameboxTokens.DARK if dark_mode else GameboxTokens.LIGHT
		var theme := ChineseCheckersTheme.create(dark_mode)
		var strip_style := theme.get_stylebox("panel", "ChineseCheckersTurnPlayerStrip")
		var turn_status_style := theme.get_stylebox("normal", "ChineseCheckersTurnStatus") as StyleBoxEmpty
		var local_style := theme.get_stylebox("panel", "ChineseCheckersTurnPlayerActiveLocal") as StyleBoxFlat
		var opponent_style := theme.get_stylebox("panel", "ChineseCheckersTurnPlayerActiveOpponent") as StyleBoxFlat
		if not _check(strip_style is StyleBoxEmpty, "player row introduced an outer tonal card") \
			or not _check(turn_status_style != null and turn_status_style.content_margin_left > 0 and turn_status_style.content_margin_left == turn_status_style.content_margin_right, "turn status lacks balanced horizontal breathing room") \
			or not _check(local_style != null and local_style.bg_color == colors["primary_container"], "local turn container drifted") \
			or not _check(local_style.border_width_left > 0 and local_style.border_color == colors["primary_fixed_dim"], "local active card lacks the approved subtle border") \
			or not _check(theme.get_color("font_color", "ChineseCheckersTurnPlayerActiveLocalIdentity") == colors["on_primary_container"], "local turn foreground is not paired") \
			or not _check(opponent_style != null and opponent_style.bg_color == colors["tertiary_container"], "opponent turn container drifted") \
			or not _check(opponent_style.border_width_left > 0 and opponent_style.border_color == colors["tertiary_fixed_dim"], "opponent active card lacks the approved subtle border") \
			or not _check(theme.get_color("font_color", "ChineseCheckersTurnPlayerActiveOpponentIdentity") == colors["on_tertiary_container"], "opponent turn foreground is not paired") \
			or not _check(theme.get_color("font_color", "ChineseCheckersTurnPlayerIdentity") == colors["on_surface"], "inactive player identity lost its hierarchy") \
			or not _check(theme.get_color("font_color", "ChineseCheckersTurnPlayerSupporting") == colors["on_surface_variant"], "inactive player supporting text did not use neutral emphasis") \
			or not _check(theme.get_font_size("font_size", "ChineseCheckersTurnPlayerIdentity") == 28, "player identity typography drifted from the approved prototype") \
			or not _check(theme.get_font_size("font_size", "ChineseCheckersTurnPlayerSupporting") == 24, "player supporting typography drifted from the approved prototype"):
			return false
	return true


static func _emphasizes_active_player() -> bool:
	var local_harness: Dictionary = await _scene_harness(BLACK_ID)
	var local_scene: Control = local_harness["scene"]
	var local_client: FakeMatchClient = local_harness["client"]
	local_client.accept_snapshot(_snapshot(0, "active", "black"))
	var me := local_scene.get_node("PlayerStrip/Content/Me") as PanelContainer
	var opponent := local_scene.get_node("PlayerStrip/Content/Opponent") as PanelContainer
	var turn := local_scene.get_node("PlayerStrip/Content/Turn") as Label
	var content := local_scene.get_node("PlayerStrip/Content") as HBoxContainer
	var result := _check(content.get_child(0) == opponent and content.get_child(2) == me, "player order drifted from opponent, turn, local") \
		and _check((me.get_node("Content/Identity") as HBoxContainer).alignment == BoxContainer.ALIGNMENT_END, "local player is not aligned to the right") \
		and _check((opponent.get_node("Content/Identity") as HBoxContainer).alignment == BoxContainer.ALIGNMENT_BEGIN, "opponent is not aligned to the left") \
		and _check(me.theme_type_variation == &"ChineseCheckersTurnPlayerActiveLocal", "local turn did not emphasize the local player") \
		and _check((me.get_node("Content/Identity/Name") as Label).text == "我" and (me.get_node("Content/Status") as Label).text == "正在行动", "local active-player copy drifted from the approved prototype") \
		and _check((me.get_node("Content/Identity/Piece") as Label).get_theme_color("font_color") == GameboxTokens.GAME["black_piece"], "local player marker does not match the black pieces") \
		and _check((me.get_node("Content/Identity/Piece") as Label).get_theme_color("font_outline_color") == GameboxTokens.GAME["white_piece_outline"], "black player marker is not distinguishable on dark surfaces") \
		and _check(opponent.theme_type_variation == &"ChineseCheckersTurnPlayerInactive", "local turn emphasized both players") \
		and _check((opponent.get_node("Content/Identity/Name") as Label).text == "对手" and (opponent.get_node("Content/Status") as Label).text == "在线", "inactive opponent copy drifted from the approved prototype") \
		and _check((opponent.get_node("Content/Identity/Piece") as Label).get_theme_color("font_color") == GameboxTokens.GAME["white_piece"], "opponent marker does not match the white pieces") \
		and _check(turn.theme_type_variation == &"ChineseCheckersTurnStatus", "turn status lacks its semantic style") \
		and _check(turn.text == "轮到你", "local turn status copy changed")
	local_client.accept_snapshot(_snapshot(1, "active", "white"))
	result = result \
		and _check(me.theme_type_variation == &"ChineseCheckersTurnPlayerInactive", "opponent turn retained local-player emphasis") \
		and _check((me.get_node("Content/Status") as Label).text == "先手", "inactive local copy drifted from the approved prototype") \
		and _check(opponent.theme_type_variation == &"ChineseCheckersTurnPlayerActiveOpponent", "opponent turn did not emphasize the opponent") \
		and _check((opponent.get_node("Content/Status") as Label).text == "正在行动", "active opponent copy drifted from the approved prototype") \
		and _check(turn.text == "等待中", "opponent turn status copy changed")
	_cleanup(local_scene)

	var white_harness: Dictionary = await _scene_harness(WHITE_ID)
	var white_scene: Control = white_harness["scene"]
	var white_client: FakeMatchClient = white_harness["client"]
	white_client.accept_snapshot(_snapshot(1, "active", "white"))
	result = result \
		and _check((white_scene.get_node("PlayerStrip/Content/Me") as PanelContainer).theme_type_variation == &"ChineseCheckersTurnPlayerActiveLocal", "white local turn emphasized by piece color instead of identity") \
		and _check((white_scene.get_node("PlayerStrip/Content/Me/Content/Status") as Label).text == "正在行动", "white local active-player copy drifted from the approved prototype") \
		and _check((white_scene.get_node("PlayerStrip/Content/Me/Content/Identity/Piece") as Label).get_theme_color("font_color") == GameboxTokens.GAME["white_piece"], "white local identity uses the wrong piece marker") \
		and _check((white_scene.get_node("PlayerStrip/Content/Opponent/Content/Identity/Piece") as Label).get_theme_color("font_color") == GameboxTokens.GAME["black_piece"], "white local opponent identity uses the wrong piece marker") \
		and _check((white_scene.get_node("PlayerStrip/Content/Opponent") as PanelContainer).theme_type_variation == &"ChineseCheckersTurnPlayerInactive", "white local turn emphasized the opponent")
	return _cleanup(white_scene, result)


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
		and _check((scene.get_node("PlayerStrip/Content/Me") as PanelContainer).theme_type_variation == &"ChineseCheckersTurnPlayerActiveLocal", "pending move lost local-player emphasis") \
		and _check((scene.get_node("PlayerStrip/Content/Me/Content/Status") as Label).text == "确认中", "pending move drifted from the approved player-card structure") \
		and _check((scene.get_node("PlayerStrip/Content/Turn") as Label).text == "确认中", "pending turn status changed") \
		and _check(not scene.has_node("MoveConfirmation"), "endpoint unexpectedly opened confirmation")
	return _cleanup(scene, result)


static func _animates_accepted_path() -> bool:
	var harness: Dictionary = await _scene_harness(BLACK_ID)
	var scene: Control = harness["scene"]
	var client: FakeMatchClient = harness["client"]
	client.accept_snapshot(_snapshot(0))
	scene._on_hole_pressed(3)
	scene._on_hole_pressed(16)
	var accepted := _move(1, BLACK_ID, "black", [3, 16])
	client.accept_event(accepted)
	var board = scene.get_node("Board")
	board._process(0.05)
	var progressed_position: Vector2 = board.animation_piece_position()
	client.event_received.emit(accepted)
	var result := _check(board.stone_at(3) == 0 and board.stone_at(16) == 1, "accepted board was not applied") \
		and _check(board.pending_path.is_empty(), "pending path remained after authority accepted the move") \
		and _check(board.move_animation_path == [3, 16], "controller did not animate the accepted path") \
		and _check(board.animation_piece_position().is_equal_approx(progressed_position), "duplicate event restarted the accepted-path animation")
	return _cleanup(scene, result)


static func _cancels_stale_animation_for_snapshot() -> bool:
	var harness: Dictionary = await _scene_harness(BLACK_ID)
	var scene: Control = harness["scene"]
	var client: FakeMatchClient = harness["client"]
	client.accept_snapshot(_snapshot(0))
	client.accept_event(_move(1, BLACK_ID, "black", [3, 16]))
	var board = scene.get_node("Board")
	board._process(0.05)
	var recovered_board := _initial_board()
	recovered_board[3] = 0
	recovered_board[16] = 1
	recovered_board[114] = 0
	recovered_board[106] = 2
	client.accept_snapshot(_snapshot(2, "active", "black", null, null, recovered_board))
	var result := _check(board.move_animation_path.is_empty(), "snapshot retained a stale accepted-move animation") \
		and _check(board.stone_at(16) == 1 and board.stone_at(106) == 2, "snapshot board was not presented after animation cancellation") \
		and _check(board.mouse_filter == Control.MOUSE_FILTER_STOP, "snapshot did not restore interaction for the authoritative turn")
	return _cleanup(scene, result)


static func _presents_winning_move_before_result() -> bool:
	var harness: Dictionary = await _scene_harness(BLACK_ID)
	var scene: Control = harness["scene"]
	var client: FakeMatchClient = harness["client"]
	client.accept_snapshot(_snapshot(20, "active", "black", null, null, _goal_ready_board()))
	scene._on_hole_pressed(102)
	scene._on_hole_pressed(111)
	client.accept_event(_move(21, BLACK_ID, "black", [102, 111]))
	var board = scene.get_node("Board")
	var result := _check(board.move_animation_path == [102, 111], "winning path was not animated") \
		and _check(not scene.get_node("ResultPanel").visible, "result panel covered the winning move") \
		and _check(not scene.get_node("ResultScrim").visible, "result scrim covered the winning move")
	board._process(1.0)
	await (Engine.get_main_loop() as SceneTree).process_frame
	result = result \
		and _check(board.move_animation_path.is_empty(), "winning animation did not finish") \
		and _check(scene.get_node("ResultPanel").visible, "result panel did not follow the winning move") \
		and _check(scene.get_node("ResultScrim").visible, "result scrim did not follow the winning move") \
		and _check((scene.get_node("ResultPanel/Content/Result") as Label).text == "率先抵达", "goal result copy changed")
	return _cleanup(scene, result)


static func _queues_consecutive_accepted_paths() -> bool:
	var harness: Dictionary = await _scene_harness(BLACK_ID)
	var scene: Control = harness["scene"]
	var client: FakeMatchClient = harness["client"]
	client.accept_snapshot(_snapshot(0))
	client.accept_event(_move(1, BLACK_ID, "black", [3, 16]))
	var board = scene.get_node("Board")
	var result := _check(board.move_animation_path == [3, 16], "first accepted path did not start")
	client.accept_event(_move(2, WHITE_ID, "white", [114, 106]))
	result = result \
		and _check(board.move_animation_path == [3, 16], "second accepted path replaced the in-flight animation") \
		and _check(board.stone_at(16) == 1 and board.stone_at(114) == 2, "queued event changed the visible in-flight board") \
		and _check((scene.get_node("PlayerStrip/Content/Turn") as Label).text == "等待中", "queued event advanced the turn chip before its board") \
		and _check((scene.get_node("PlayerStrip/Content/Opponent") as PanelContainer).theme_type_variation == &"ChineseCheckersTurnPlayerActiveOpponent", "queued event advanced player emphasis before its board")
	board._process(1.0)
	result = result \
		and _check(board.move_animation_path == [114, 106], "second accepted path did not start after the first") \
		and _check(board.stone_at(114) == 0 and board.stone_at(106) == 2, "queued animation did not use its authoritative board") \
		and _check((scene.get_node("PlayerStrip/Content/Turn") as Label).text == "轮到你", "queued turn chip did not advance with its board") \
		and _check((scene.get_node("PlayerStrip/Content/Me") as PanelContainer).theme_type_variation == &"ChineseCheckersTurnPlayerActiveLocal", "queued player emphasis did not advance with its board")
	board._process(1.0)
	await (Engine.get_main_loop() as SceneTree).process_frame
	result = result \
		and _check(board.move_animation_path.is_empty(), "consecutive animations did not finish") \
		and _check(board.mouse_filter == Control.MOUSE_FILTER_STOP, "latest turn did not restore board interaction")
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
		and _check((scene.get_node("PlayerStrip/Content/Me") as PanelContainer).theme_type_variation == &"ChineseCheckersTurnPlayerInactive", "terminal state retained local-player emphasis") \
		and _check((scene.get_node("PlayerStrip/Content/Opponent") as PanelContainer).theme_type_variation == &"ChineseCheckersTurnPlayerInactive", "terminal state retained opponent emphasis") \
		and _check((scene.get_node("HintLabel") as Label).text == "对局已结束，结果已由服务器确认", "terminal hint retained active-play copy") \
		and _check(scene.get_node("Board").mouse_filter == Control.MOUSE_FILTER_IGNORE, "terminal board accepts input")
	return _cleanup(scene, result)


static func _plays_confirmed_move_sound_for_either_player() -> bool:
	for local_user_id in [BLACK_ID, WHITE_ID]:
		for move_color in ["black", "white"]:
			var harness: Dictionary = await _scene_harness(local_user_id)
			var scene: Control = harness["scene"]
			var client: FakeMatchClient = harness["client"]
			var sound := scene.get_node_or_null("MoveSound") as AudioStreamPlayer
			if not _check(sound != null and sound.stream != null, "confirmed move sound is not configured"):
				return _cleanup(scene)
			var revision := 1
			var move_user_id := BLACK_ID
			var path := [6, 14]
			if move_color == "white":
				var board := _initial_board()
				board[6] = 0
				board[14] = 1
				client.accept_snapshot(_snapshot(1, "active", "white", null, null, board))
				client.event_received.emit(_move(1, BLACK_ID, "black", [6, 14]))
				revision = 2
				move_user_id = WHITE_ID
				path = [114, 106]
			else:
				client.accept_snapshot(_snapshot(0))
			if not _check(not sound.playing, "snapshot or replayed move produced sound"):
				return _cleanup(scene)
			client.accept_event(_move(revision, move_user_id, move_color, path))
			if not _check(sound.playing, "confirmed %s move was silent for local user %s" % [move_color, local_user_id]):
				return _cleanup(scene)
			sound.stop()
			client.event_received.emit(_move(revision, move_user_id, move_color, path))
			if not _check(not sound.playing, "duplicate %s move replayed its sound" % move_color):
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
	board: Array = [],
) -> Dictionary:
	return {
		"protocolVersion": 1, "gameId": "chinese_checkers", "matchId": MATCH_ID,
		"revision": revision, "type": "platform.snapshot",
		"payload": {
			"status": status, "board": _initial_board() if board.is_empty() else board.duplicate(),
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


static func _goal_ready_board() -> Array:
	var board: Array = []
	board.resize(121)
	board.fill(0)
	for index in [112, 113, 114, 115, 116, 117, 118, 119, 120, 102]:
		board[index] = 1
	for index in [23, 24, 25, 26, 27, 28, 29, 30, 31, 32]:
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
