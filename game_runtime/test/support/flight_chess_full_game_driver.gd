class_name FlightChessFullGameDriver
extends RefCounted

const FlightChessState = preload("res://games/flight_chess/flight_chess_state.gd")

const BLACK := "black"
const WHITE := "white"
const ROLL_ACTION_ID := "44444444-4444-4444-8444-444444444444"
const MOVE_ACTION_ID := "55555555-5555-4555-8555-555555555555"


static func initial_snapshot(match_id: String, black_user_id: String, white_user_id: String) -> Dictionary:
	var pieces := {BLACK: [], WHITE: []}
	for color in pieces:
		for piece_index in 4:
			pieces[color].append({"zone": "hangar", "index": piece_index})
	return {
		"protocolVersion": 1,
		"gameId": "flight_chess",
		"matchId": match_id,
		"revision": 0,
		"type": "platform.snapshot",
		"payload": {
			"status": "active",
			"phase": "awaiting_roll",
			"blackUserId": black_user_id,
			"whiteUserId": white_user_id,
			"nextColor": BLACK,
			"dice": 0,
			"pieces": pieces,
			"winnerUserId": null,
			"result": null,
		},
	}


static func next_event(state: Variant, match_id: String) -> Dictionary:
	if state == null or state.status != "active":
		return {}
	if state.phase == "awaiting_roll":
		return _roll_event(state, match_id)
	if state.phase == "awaiting_move":
		return _move_event(state, match_id)
	return {}


static func _roll_event(state: Variant, match_id: String) -> Dictionary:
	var color: String = state.next_color
	var value := _choose_roll(state, color)
	var movable := _movable_indices(state, color, value)
	return {
		"protocolVersion": 1,
		"gameId": "flight_chess",
		"matchId": match_id,
		"revision": state.revision + 1,
		"type": "flight_chess.roll.accepted",
		"actionId": ROLL_ACTION_ID,
		"payload": {
			"color": color,
			"userId": state.black_user_id if color == BLACK else state.white_user_id,
			"value": value,
			"movablePieceIndices": movable,
		},
	}


static func _move_event(state: Variant, match_id: String) -> Dictionary:
	var color: String = state.next_color
	var pieces: Dictionary = state.pieces
	var piece_index := _choose_piece(state, color)
	if piece_index < 0:
		return {}
	var from: Dictionary = pieces[color][piece_index].duplicate()
	var resolution: Dictionary = FlightChessState._resolve_move(color, from, state.dice)
	if not resolution.get("ok", false):
		return {}
	var captured: Array = []
	var opponent := WHITE if color == BLACK else BLACK
	if resolution["to"]["zone"] == "main":
		for opponent_index in 4:
			if pieces[opponent][opponent_index] == resolution["to"]:
				captured.append(opponent_index)
	return {
		"protocolVersion": 1,
		"gameId": "flight_chess",
		"matchId": match_id,
		"revision": state.revision + 1,
		"type": "flight_chess.move.accepted",
		"actionId": MOVE_ACTION_ID,
		"payload": {
			"color": color,
			"userId": state.black_user_id if color == BLACK else state.white_user_id,
			"pieceIndex": piece_index,
			"roll": state.dice,
			"from": from,
			"to": resolution["to"].duplicate(),
			"effect": resolution["effect"],
			"capturedPieceIndices": captured,
		},
	}


static func _choose_roll(state: Variant, color: String) -> int:
	# Six is now always legal in home; choose an exact finish instead of bouncing forever.
	for piece in state.pieces[color]:
		if piece["zone"] == "home":
			return 6 - int(piece["index"])
	for value in [6, 5, 4, 3, 2, 1]:
		for piece_index in _movable_indices(state, color, value):
			var resolution: Dictionary = FlightChessState._resolve_move(
				color,
				state.pieces[color][piece_index],
				value,
			)
			if resolution.get("effect", "") in ["shortcut", "jump_shortcut"]:
				return value
	if not _movable_indices(state, color, 6).is_empty():
		return 6
	for value in [5, 4, 3, 2, 1]:
		if not _movable_indices(state, color, value).is_empty():
			return value
	return 1


static func _choose_piece(state: Variant, color: String) -> int:
	var best_index := -1
	var best_score := -1
	var pieces: Dictionary = state.pieces
	for piece_index in state.movable_piece_indices():
		var resolution: Dictionary = FlightChessState._resolve_move(color, pieces[color][piece_index], state.dice)
		var score := _destination_score(color, resolution.get("to", {}))
		if score > best_score:
			best_score = score
			best_index = piece_index
	return best_index


static func _movable_indices(state: Variant, color: String, value: int) -> Array:
	var result: Array = []
	var pieces: Dictionary = state.pieces
	for piece_index in 4:
		if FlightChessState._resolve_move(color, pieces[color][piece_index], value).get("ok", false):
			result.append(piece_index)
	return result


static func _destination_score(color: String, destination: Dictionary) -> int:
	match destination.get("zone", ""):
		"finished": return 1000
		"home": return 100 + int(destination["index"])
		"main": return FlightChessState._progress_for_index(color, int(destination["index"]))
		"launch": return 0
	return -1
