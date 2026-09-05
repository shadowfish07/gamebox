extends RefCounted

const FlightChessState = preload("res://games/flight_chess/flight_chess_state.gd")
const Protocol = preload("res://core/protocol.gd")
const MATCH_ID := "11111111-1111-4111-8111-111111111111"
const BLACK_ID := "22222222-2222-4222-8222-222222222222"
const WHITE_ID := "33333333-3333-4333-8333-333333333333"
const ACTION_ID := "44444444-4444-4444-8444-444444444444"


static func cases() -> Array:
	return [
		{"name": "flight chess restores an authoritative roll snapshot", "run": _restores_snapshot},
		{"name": "flight chess confirms roll then selected move", "run": _confirms_roll_and_move},
		{"name": "flight chess keeps repeated sixes without penalty", "run": _keeps_repeated_sixes},
		{"name": "flight chess applies jump shortcut capture", "run": _applies_jump_shortcut_capture},
		{"name": "flight chess rejects malformed or out-of-order events", "run": _rejects_invalid_events},
		{"name": "flight chess maps platform colors to board colors", "run": _maps_board_colors},
	]


static func _restores_snapshot() -> bool:
	var state = FlightChessState.new(MATCH_ID)
	var pieces := _initial_pieces()
	pieces["black"][2] = {"zone": "launch", "index": 0}
	var restored: Dictionary = state.apply_snapshot(_snapshot(7, "awaiting_move", "black", 4, pieces))
	return _check(restored.get("status") == "applied", "valid snapshot was not applied") \
		and _check(state.revision == 7 and state.dice == 4, "roll snapshot lost revision or die") \
		and _check(state.movable_piece_indices() == [2], "only the launched plane should be movable") \
		and _check(state.can_request_piece(2, BLACK_ID), "authoritative move was not enabled") \
		and _check(not state.can_request_roll(BLACK_ID), "roll stayed enabled during selection")


static func _confirms_roll_and_move() -> bool:
	var state = FlightChessState.new(MATCH_ID)
	if not state.apply_snapshot(_snapshot(0, "awaiting_roll", "black", 0, _initial_pieces())).get("ok", false):
		return _check(false, "initial snapshot rejected")
	if not state.mark_pending_roll(ACTION_ID, BLACK_ID):
		return _check(false, "roll was not marked pending")
	var rolled := state.apply_event(_event(1, "flight_chess.roll.accepted", {
		"color": "black", "userId": BLACK_ID, "value": 6,
		"movablePieceIndices": [0, 1, 2, 3],
	}, ACTION_ID))
	if not rolled.get("ok", false) or not state.pending_action.is_empty() or state.phase != "awaiting_move":
		return _check(false, "accepted roll did not unlock selection")
	var move_action := "55555555-5555-4555-8555-555555555555"
	if not state.mark_pending_move(move_action, 1, BLACK_ID):
		return _check(false, "move was not marked pending")
	var moved := state.apply_event(_event(2, "flight_chess.move.accepted", {
		"color": "black", "userId": BLACK_ID, "pieceIndex": 1, "roll": 6,
		"from": {"zone": "hangar", "index": 1}, "to": {"zone": "launch", "index": 0},
		"effect": "none", "capturedPieceIndices": [],
	}, move_action))
	return _check(moved.get("ok", false), "accepted launch was rejected") \
		and _check(state.pieces["black"][1] == {"zone": "launch", "index": 0}, "launch did not update the plane") \
		and _check(state.next_color == "black" and state.phase == "awaiting_roll", "six did not preserve the turn")


static func _keeps_repeated_sixes() -> bool:
	var state = FlightChessState.new(MATCH_ID)
	if not state.apply_snapshot(_snapshot(0, "awaiting_roll", "black", 0, _initial_pieces())).get("ok", false):
		return _check(false, "initial snapshot rejected")
	for roll_number in 3:
		var movable: Array = []
		for piece_index in 4:
			if FlightChessState._resolve_move("black", state.pieces["black"][piece_index], 6).get("ok", false):
				movable.append(piece_index)
		var rolled := state.apply_event(_event(state.revision + 1, "flight_chess.roll.accepted", {
			"color": "black", "userId": BLACK_ID, "value": 6,
			"movablePieceIndices": movable,
		}, ACTION_ID))
		if not rolled.get("ok", false) or state.phase != "awaiting_move":
			return _check(false, "repeated six %d was rejected" % (roll_number + 1))
		var from: Dictionary = state.pieces["black"][0]
		var resolution: Dictionary = FlightChessState._resolve_move("black", from, 6)
		var moved := state.apply_event(_event(state.revision + 1, "flight_chess.move.accepted", {
			"color": "black", "userId": BLACK_ID, "pieceIndex": 0, "roll": 6,
			"from": from, "to": resolution["to"], "effect": resolution["effect"],
			"capturedPieceIndices": [],
		}, ACTION_ID))
		if not moved.get("ok", false):
			return _check(false, "move after repeated six %d was rejected" % (roll_number + 1))
	return _check(state.next_color == "black", "repeated sixes changed the turn") \
		and _check(state.pieces["black"][0]["zone"] != "hangar", "repeated sixes returned the plane")


static func _applies_jump_shortcut_capture() -> bool:
	var state = FlightChessState.new(MATCH_ID)
	var pieces := _initial_pieces()
	pieces["black"][0] = {"zone": "main", "index": 35}
	pieces["white"][0] = {"zone": "main", "index": 3}
	pieces["white"][1] = {"zone": "main", "index": 3}
	if not state.apply_snapshot(_snapshot(10, "awaiting_move", "black", 4, pieces)).get("ok", false):
		return _check(false, "setup snapshot rejected")
	var applied := state.apply_event(_event(11, "flight_chess.move.accepted", {
		"color": "black", "userId": BLACK_ID, "pieceIndex": 0, "roll": 4,
		"from": {"zone": "main", "index": 35}, "to": {"zone": "main", "index": 3},
		"effect": "jump_shortcut", "capturedPieceIndices": [0, 1],
	}, ACTION_ID))
	return _check(applied.get("ok", false), "jump shortcut event rejected") \
		and _check(state.pieces["black"][0]["index"] == 3, "plane missed shortcut destination") \
		and _check(state.pieces["white"][0]["zone"] == "hangar" and state.pieces["white"][1]["zone"] == "hangar", "captured stack did not return")


static func _rejects_invalid_events() -> bool:
	var state = FlightChessState.new(MATCH_ID)
	if not state.apply_snapshot(_snapshot(0, "awaiting_roll", "black", 0, _initial_pieces())).get("ok", false):
		return false
	var gap := _event(2, "flight_chess.roll.accepted", {
		"color": "black", "userId": BLACK_ID, "value": 6,
		"movablePieceIndices": [0, 1, 2, 3],
	}, ACTION_ID)
	if state.apply_event(gap).get("status") != "needs_snapshot":
		return _check(false, "revision gap did not request a snapshot")
	var forged := gap.duplicate(true)
	forged["revision"] = 1
	forged["payload"]["movablePieceIndices"] = [0]
	return _check(not state.apply_event(forged).get("ok", true), "forged movable list was accepted") \
		and _check(state.revision == 0, "invalid event partially mutated state")


static func _maps_board_colors() -> bool:
	var state = FlightChessState.new(MATCH_ID)
	if not state.apply_snapshot(_snapshot(0, "awaiting_roll", "black", 0, _initial_pieces())).get("ok", false):
		return false
	var visual: Dictionary = state.visual_pieces()
	return _check(visual.has("red") and visual.has("yellow"), "platform colors were not mapped") \
		and _check(visual["red"].size() == 4 and visual["yellow"].size() == 4, "visual piece count changed") \
		and _check(state.board_color_for_user(BLACK_ID) == "red" and state.board_color_for_user(WHITE_ID) == "yellow", "player board colors are wrong")


static func _snapshot(revision: int, phase: String, next_color: String, dice: int, pieces: Dictionary) -> Dictionary:
	return {
		"protocolVersion": 1, "gameId": "flight_chess", "matchId": MATCH_ID,
		"revision": revision, "type": "platform.snapshot",
		"payload": {
			"status": "active", "phase": phase,
			"blackUserId": BLACK_ID, "whiteUserId": WHITE_ID,
			"nextColor": next_color, "dice": dice, "pieces": pieces,
			"winnerUserId": null, "result": null,
		},
	}


static func _event(revision: int, event_type: String, payload: Dictionary, action_id: String = "") -> Dictionary:
	var envelope := {
		"protocolVersion": 1, "gameId": "flight_chess", "matchId": MATCH_ID,
		"revision": revision, "type": event_type, "payload": payload,
	}
	if not action_id.is_empty():
		envelope["actionId"] = action_id
	return envelope


static func _initial_pieces() -> Dictionary:
	var pieces := {"black": [], "white": []}
	for color in pieces:
		for index in 4:
			pieces[color].append({"zone": "hangar", "index": index})
	return pieces


static func _check(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition
