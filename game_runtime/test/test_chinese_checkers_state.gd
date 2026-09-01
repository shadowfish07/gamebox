extends RefCounted

const ChineseCheckersState = preload("res://games/chinese_checkers/chinese_checkers_state.gd")

const MATCH_ID := "11111111-1111-4111-8111-111111111111"
const BLACK_ID := "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
const WHITE_ID := "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
const BLACK_ACTION := "33333333-3333-4333-8333-333333333333"


static func cases() -> Array:
	return [
		{"name": "chinese checkers state restores the standard star snapshot", "run": _restores_snapshot},
		{"name": "chinese checkers state finds direct endpoints and turning jumps", "run": _finds_direct_endpoints},
		{"name": "chinese checkers state keeps submitted paths pending until authority", "run": _keeps_pending_authoritative},
		{"name": "chinese checkers state rejects illegal endpoint restrictions", "run": _rejects_endpoint_restrictions},
	]


static func _restores_snapshot() -> bool:
	var state = ChineseCheckersState.new(MATCH_ID)
	var result: Dictionary = state.apply_snapshot(_snapshot(0, _initial_board()))
	return _check(result.get("status") == "applied", "initial snapshot rejected: %s" % [result]) \
		and _check(state.board.size() == 121, "board does not have 121 holes") \
		and _check(state.board.slice(0, 10) == [1, 1, 1, 1, 1, 1, 1, 1, 1, 1], "black camp was not restored") \
		and _check(state.board.slice(111, 121) == [2, 2, 2, 2, 2, 2, 2, 2, 2, 2], "white camp was not restored") \
		and _check(state.next_color == "black" and state.black_user_id == BLACK_ID, "turn metadata was not restored")


static func _finds_direct_endpoints() -> bool:
	var state = ChineseCheckersState.new(MATCH_ID)
	if not state.apply_snapshot(_snapshot(0, _initial_board())).get("ok", false):
		return false
	var initial_paths: Dictionary = state.legal_paths_from(6, BLACK_ID)
	if not _check(initial_paths.has(14) and initial_paths[14] == [6, 14], "adjacent endpoint missing") \
		or not _check(state.legal_paths_from(3, BLACK_ID).get(16) == [3, 16], "jump endpoint missing"):
		return false

	var board := _empty_board()
	board[56] = 1
	board[57] = 2
	board[68] = 2
	# Keep the snapshot's exact ten-piece invariant without blocking the test path.
	for index in [0, 1, 2, 3, 4, 5, 7, 8, 9]:
		board[index] = 1
	for index in [23, 24, 25, 26, 27, 28, 29, 30]:
		board[index] = 2
	state = ChineseCheckersState.new(MATCH_ID)
	if not state.apply_snapshot(_snapshot(2, board)).get("ok", false):
		return _check(false, "turning-jump fixture rejected")
	var paths: Dictionary = state.legal_paths_from(56, BLACK_ID)
	return _check(paths.has(79), "turning multi-jump endpoint missing") \
		and _check(paths[79] == [56, 58, 79], "server path differs: %s" % [paths.get(79)])


static func _keeps_pending_authoritative() -> bool:
	var state = ChineseCheckersState.new(MATCH_ID)
	state.apply_snapshot(_snapshot(0, _initial_board()))
	var before: Array = state.board
	if not _check(state.can_request_path([6, 14], BLACK_ID), "legal path cannot be requested") \
		or not _check(state.mark_pending_path(BLACK_ACTION, [6, 14], BLACK_ID), "pending path rejected") \
		or not _check(state.board == before, "pending path changed the board"):
		return false
	var event := _move(1, BLACK_ACTION, BLACK_ID, "black", [6, 14])
	var result: Dictionary = state.apply_event(event)
	return _check(result.get("status") == "applied", "accepted move rejected: %s" % [result]) \
		and _check(state.board[6] == 0 and state.board[14] == 1, "accepted move not applied") \
		and _check(state.pending_action.is_empty(), "accepted action did not clear pending") \
		and _check(state.next_color == "white", "turn did not alternate")


static func _rejects_endpoint_restrictions() -> bool:
	var neutral := _empty_board()
	neutral[56] = 1
	var state = ChineseCheckersState.new(MATCH_ID)
	return _check(not state.is_legal_path(neutral, 1, [56, 46]), "neutral camp endpoint accepted") \
		and _check(not state.is_legal_path(_board_with(111, 1), 1, [111, 102]), "target camp exit accepted") \
		and _check(not state.is_legal_path(_board_with(56, 1, 57, 2), 1, [56, 58, 59]), "mixed step/jump path accepted")


static func _snapshot(revision: int, board: Array) -> Dictionary:
	return {
		"protocolVersion": 1, "gameId": "chinese_checkers", "matchId": MATCH_ID,
		"revision": revision, "type": "platform.snapshot",
		"payload": {
			"status": "active", "board": board.duplicate(),
			"blackUserId": BLACK_ID, "whiteUserId": WHITE_ID,
			"nextColor": "white" if revision % 2 == 1 else "black",
			"winnerUserId": null, "result": null,
		},
	}


static func _move(revision: int, action_id: String, user_id: String, color: String, path: Array) -> Dictionary:
	return {
		"protocolVersion": 1, "gameId": "chinese_checkers", "matchId": MATCH_ID,
		"revision": revision, "type": "chinese_checkers.move.accepted", "actionId": action_id,
		"payload": {"path": path.duplicate(), "color": color, "userId": user_id},
	}


static func _initial_board() -> Array:
	var board := _empty_board()
	for index in 10:
		board[index] = 1
	for index in range(111, 121):
		board[index] = 2
	return board


static func _empty_board() -> Array:
	var board: Array = []
	board.resize(121)
	board.fill(0)
	return board


static func _board_with(first_index: int, first_value: int, second_index: int = -1, second_value: int = 0) -> Array:
	var board := _empty_board()
	board[first_index] = first_value
	if second_index >= 0:
		board[second_index] = second_value
	return board


static func _check(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition
