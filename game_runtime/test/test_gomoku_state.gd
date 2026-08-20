extends RefCounted

const GomokuState = preload("res://games/gomoku/gomoku_state.gd")

const MATCH_ID := "11111111-1111-4111-8111-111111111111"
const BLACK_ID := "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
const WHITE_ID := "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
const BLACK_ACTION := "33333333-3333-4333-8333-333333333333"
const WHITE_ACTION := "44444444-4444-4444-8444-444444444444"


static func cases() -> Array:
	return [
		{"name": "gomoku state restores a strict defensive snapshot", "run": _restores_strict_snapshot},
		{"name": "gomoku state ignores stale events and requests snapshot on gaps", "run": _orders_events_by_revision},
		{"name": "gomoku state applies only canonical authoritative moves", "run": _applies_authoritative_moves},
		{"name": "gomoku state handles resignation and lifecycle terminals", "run": _applies_terminal_events},
		{"name": "gomoku state validates five and draw snapshot semantics", "run": _validates_terminal_snapshots},
		{"name": "gomoku state pending markers never place stones", "run": _keeps_pending_out_of_board},
		{"name": "gomoku state clears pending only with authoritative confirmation", "run": _clears_pending_safely},
		{"name": "gomoku state rejects malformed typed dictionary boundaries", "run": _rejects_malformed_boundaries},
	]


static func _restores_strict_snapshot() -> bool:
	var state = GomokuState.new(MATCH_ID)
	var board := _empty_board()
	board[0] = 1
	board[16] = 2
	var message := _snapshot(2, board, "active", "black", null, null)
	var result: Dictionary = state.apply_snapshot(message)
	if not _check(result.get("ok", false), "valid snapshot rejected: %s" % [result]):
		return false
	if not _check(state.revision == 2 and state.status == "active", "snapshot metadata not restored") \
		or not _check(state.black_user_id == BLACK_ID and state.white_user_id == WHITE_ID, "player colors not restored") \
		or not _check(state.next_color == "black" and state.result == null and state.winner_user_id == null, "turn/result not restored"):
		return false
	board[0] = 0
	message["payload"]["board"][16] = 0
	var first_copy: Array = state.board
	first_copy[0] = 0
	state.revision = 99
	state.status = "finished"
	state.board = []
	return _check(state.cell(0, 0) == 1 and state.cell(1, 1) == 2, "snapshot board was aliased") \
		and _check(state.board.size() == 225, "state board must contain exactly 225 cells") \
		and _check(state.revision == 2 and state.status == "active", "public properties bypassed the authoritative reducer")


static func _orders_events_by_revision() -> bool:
	var state = GomokuState.new(MATCH_ID)
	if not state.apply_snapshot(_snapshot(0)).get("ok", false):
		return false
	var first := _move(1, BLACK_ACTION, BLACK_ID, "black", 7, 7)
	if not _check(state.apply_event(first).get("status") == "applied", "next event was not applied"):
		return false
	var stale_board: Array = state.board
	if not _check(state.apply_event(first).get("status") == "ignored", "same revision must be ignored") \
		or not _check(state.apply_event(_move(0, BLACK_ACTION, BLACK_ID, "black", 7, 7)).get("status") == "ignored", "older revision must be ignored") \
		or not _check(state.board == stale_board and state.revision == 1, "ignored event changed state"):
		return false
	for _iteration in 1000:
		if state.apply_event(first).get("status") != "ignored":
			return _check(false, "high-count duplicate event stopped being idempotent")
	var gap_result: Dictionary = state.apply_event(_move(3, WHITE_ACTION, WHITE_ID, "white", 8, 8))
	return _check(gap_result.get("status") == "needs_snapshot", "revision gap must request a snapshot") \
		and _check(state.revision == 1 and state.cell(8, 8) == 0, "gap event changed the board")


static func _applies_authoritative_moves() -> bool:
	var state = GomokuState.new(MATCH_ID)
	state.apply_snapshot(_snapshot(0))
	if not _check(state.apply_event(_move(1, BLACK_ACTION, BLACK_ID, "black", 4, 5)).get("status") == "applied", "black move rejected") \
		or not _check(state.cell(4, 5) == 1 and state.next_color == "white", "black move not applied"):
		return false
	var before: Array = state.board
	var invalid_events := [
		_move(2, WHITE_ACTION, WHITE_ID, "black", 5, 5),
		_move(2, WHITE_ACTION, BLACK_ID, "white", 5, 5),
		_move(2, WHITE_ACTION, WHITE_ID, "white", 4, 5),
		_move(2, WHITE_ACTION, WHITE_ID, "white", 15, 5),
	]
	for event in invalid_events:
		var result: Dictionary = state.apply_event(event)
		if not _check(not result.get("ok", true), "invalid authoritative move accepted") \
			or not _check(state.board == before and state.revision == 1, "invalid move mutated state"):
			return false
	return _check(state.apply_event(_move(2, WHITE_ACTION, WHITE_ID, "white", 5, 5)).get("status") == "applied", "white move rejected") \
		and _check(state.cell(5, 5) == 2 and state.next_color == "black", "white move not applied")


static func _applies_terminal_events() -> bool:
	var resigned = GomokuState.new(MATCH_ID)
	var one_stone := _empty_board()
	one_stone[0] = 1
	resigned.apply_snapshot(_snapshot(1, one_stone, "active", "white"))
	var resign_result: Dictionary = resigned.apply_event(_resigned(2, WHITE_ACTION, WHITE_ID, BLACK_ID))
	if not _check(resign_result.get("status") == "applied", "valid resignation rejected") \
		or not _check(resigned.status == "finished" and resigned.result == "resignation" and resigned.winner_user_id == BLACK_ID, "resignation outcome wrong"):
		return false

	var cancelled = GomokuState.new(MATCH_ID)
	cancelled.apply_snapshot(_snapshot(0))
	if not _check(cancelled.apply_event(_lifecycle(1, "platform.match.cancelled")).get("status") == "applied", "cancel event rejected") \
		or not _check(cancelled.status == "cancelled" and cancelled.revision == 1, "cancel state wrong"):
		return false

	var abandoned = GomokuState.new(MATCH_ID)
	abandoned.apply_snapshot(_snapshot(0))
	return _check(abandoned.apply_event(_lifecycle(1, "platform.match.abandoned")).get("status") == "applied", "abandon event rejected") \
		and _check(abandoned.status == "abandoned" and abandoned.result == null, "abandon state wrong")


static func _keeps_pending_out_of_board() -> bool:
	var state = GomokuState.new(MATCH_ID)
	state.apply_snapshot(_snapshot(0))
	if not _check(state.can_request_move(7, 7, BLACK_ID), "black should be able to request first move") \
		or not _check(not state.can_request_move(7, 7, WHITE_ID), "white must not request first move"):
		return false
	var before: Array = state.board
	if not _check(state.mark_pending(BLACK_ACTION, 7, 7), "valid pending marker rejected") \
		or not _check(state.board == before and state.cell(7, 7) == 0, "pending marker placed a local stone") \
		or not _check(not state.can_request_move(8, 8, BLACK_ID), "pending action did not block a second move"):
		return false
	var pending: Dictionary = state.pending_action
	pending["x"] = 1
	return _check(state.pending_action.get("x") == 7, "pending marker was aliased")


static func _validates_terminal_snapshots() -> bool:
	var winning_board := _empty_board()
	for x in 5:
		winning_board[x] = 1
		if x < 4:
			winning_board[15 + x] = 2
	var won = GomokuState.new(MATCH_ID)
	if not _check(won.apply_snapshot(_snapshot(9, winning_board, "finished", "white", "five", BLACK_ID)).get("ok", false), "valid five snapshot rejected") \
		or not _check(won.result == "five" and won.winner_user_id == BLACK_ID, "five result not restored"):
		return false
	var impossible_active := _snapshot(9, winning_board, "active", "white", null, null)
	if not _check(not GomokuState.new(MATCH_ID).apply_snapshot(impossible_active).get("ok", true), "active snapshot containing five accepted"):
		return false
	var draw_board := _empty_board()
	for y in 15:
		for x in 15:
			draw_board[y * 15 + x] = 1 if ((x + 2 * y) % 4) < 2 else 2
	var drawn = GomokuState.new(MATCH_ID)
	return _check(drawn.apply_snapshot(_snapshot(225, draw_board, "finished", "white", "draw", null)).get("ok", false), "valid full draw rejected") \
		and _check(drawn.status == "finished" and drawn.result == "draw" and drawn.winner_user_id == null, "draw result not restored")


static func _clears_pending_safely() -> bool:
	var state = GomokuState.new(MATCH_ID)
	state.apply_snapshot(_snapshot(0))
	state.mark_pending(BLACK_ACTION, 7, 7)
	state.apply_error(_error(0, WHITE_ACTION, "not_your_turn"))
	if not _check(not state.pending_action.is_empty(), "unrelated error cleared pending") \
		or not _check(state.cell(7, 7) == 0, "error changed board"):
		return false
	state.apply_error(_error(0, BLACK_ACTION, "not_your_turn"))
	if not _check(state.pending_action.is_empty(), "matching error did not clear pending"):
		return false
	state.mark_pending(BLACK_ACTION, 7, 7)
	state.apply_event(_move(1, BLACK_ACTION, BLACK_ID, "black", 7, 7))
	if not _check(state.pending_action.is_empty(), "matching accepted action did not clear pending"):
		return false
	state.mark_pending(WHITE_ACTION, 8, 8)
	var snapshot_board: Array = state.board
	state.apply_snapshot(_snapshot(1, snapshot_board, "active", "white"))
	return _check(state.pending_action.is_empty(), "authoritative same-revision snapshot did not clear pending")


static func _rejects_malformed_boundaries() -> bool:
	var base := _snapshot(0)
	var malformed := []
	var wrong_size: Dictionary = base.duplicate(true)
	wrong_size["payload"]["board"].pop_back()
	malformed.append(wrong_size)
	var wrong_cell: Dictionary = base.duplicate(true)
	wrong_cell["payload"]["board"][0] = 1.0
	malformed.append(wrong_cell)
	var extra_payload: Dictionary = base.duplicate(true)
	extra_payload["payload"]["extra"] = true
	malformed.append(extra_payload)
	var wrong_actor: Dictionary = base.duplicate(true)
	wrong_actor["payload"]["blackUserId"] = 7
	malformed.append(wrong_actor)
	var wrong_status: Dictionary = base.duplicate(true)
	wrong_status["payload"]["status"] = "mystery"
	malformed.append(wrong_status)
	var extra_envelope: Dictionary = base.duplicate(true)
	extra_envelope["unexpected"] = true
	malformed.append(extra_envelope)
	for message in malformed:
		var state = GomokuState.new(MATCH_ID)
		if not _check(not state.apply_snapshot(message).get("ok", true), "malformed snapshot accepted") \
			or not _check(state.revision == -1 and state.board.size() == 225, "malformed snapshot partially mutated state"):
			return false
	return true


static func _snapshot(
	revision: int,
	board: Array = [],
	status: String = "active",
	next_color: String = "black",
	result: Variant = null,
	winner: Variant = null
) -> Dictionary:
	var snapshot_board := _empty_board() if board.is_empty() else board.duplicate()
	return {
		"protocolVersion": 1,
		"gameId": "gomoku",
		"matchId": MATCH_ID,
		"revision": revision,
		"type": "platform.snapshot",
		"payload": {
			"status": status,
			"board": snapshot_board,
			"boardSize": 15,
			"blackUserId": BLACK_ID,
			"whiteUserId": WHITE_ID,
			"nextColor": next_color,
			"winnerUserId": winner,
			"result": result,
		},
	}


static func _move(revision: int, action_id: String, user_id: String, color: String, x: int, y: int) -> Dictionary:
	return {
		"protocolVersion": 1, "gameId": "gomoku", "matchId": MATCH_ID,
		"revision": revision, "type": "gomoku.move.accepted", "actionId": action_id,
		"payload": {"x": x, "y": y, "color": color, "userId": user_id},
	}


static func _resigned(revision: int, action_id: String, user_id: String, winner_id: String) -> Dictionary:
	return {
		"protocolVersion": 1, "gameId": "gomoku", "matchId": MATCH_ID,
		"revision": revision, "type": "gomoku.resigned", "actionId": action_id,
		"payload": {"userId": user_id, "winnerUserId": winner_id},
	}


static func _lifecycle(revision: int, message_type: String) -> Dictionary:
	return {
		"protocolVersion": 1, "gameId": "gomoku", "matchId": MATCH_ID,
		"revision": revision, "type": message_type, "payload": {},
	}


static func _error(revision: int, action_id: String, code: String) -> Dictionary:
	return {
		"protocolVersion": 1, "gameId": "gomoku", "matchId": MATCH_ID,
		"revision": revision, "type": "platform.error", "actionId": action_id,
		"payload": {"code": code, "message": "fixed", "details": {}},
	}


static func _empty_board() -> Array:
	var board: Array = []
	board.resize(225)
	board.fill(0)
	return board


static func _check(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition
