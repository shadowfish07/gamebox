extends RefCounted

const GAME_ID := "flight_chess"
const BLACK := "black"
const WHITE := "white"
const STATUS_ACTIVE := "active"
const STATUS_FINISHED := "finished"
const STATUS_CANCELLED := "cancelled"
const STATUS_ABANDONED := "abandoned"
const PHASE_AWAITING_ROLL := "awaiting_roll"
const PHASE_AWAITING_MOVE := "awaiting_move"
const ZONE_HANGAR := "hangar"
const ZONE_LAUNCH := "launch"
const ZONE_MAIN := "main"
const ZONE_HOME := "home"
const ZONE_FINISHED := "finished"
const PIECE_COUNT := 4
const MAIN_CELL_COUNT := 52
const HOME_CELL_COUNT := 6
const START_INDICES := {BLACK: 26, WHITE: 0}

var revision: int:
	get: return _revision
	set(_value): pass
var status: String:
	get: return _status
	set(_value): pass
var phase: String:
	get: return _phase
	set(_value): pass
var black_user_id: String:
	get: return _black_user_id
	set(_value): pass
var white_user_id: String:
	get: return _white_user_id
	set(_value): pass
var next_color: String:
	get: return _next_color
	set(_value): pass
var dice: int:
	get: return _dice
	set(_value): pass
var consecutive_sixes: int:
	get: return _consecutive_sixes
	set(_value): pass
var six_moved_piece_indices: Array:
	get: return _six_moved_piece_indices.duplicate()
	set(_value): pass
var pieces: Dictionary:
	get: return _pieces.duplicate(true)
	set(_value): pass
var winner_user_id: Variant:
	get: return _winner_user_id
	set(_value): pass
var result: Variant:
	get: return _result
	set(_value): pass
var pending_action: Dictionary:
	get: return _pending_action.duplicate(true)
	set(_value): pass

var _match_id := ""
var _revision := -1
var _status := ""
var _phase := ""
var _black_user_id := ""
var _white_user_id := ""
var _next_color := ""
var _dice := 0
var _consecutive_sixes := 0
var _six_moved_piece_indices: Array = []
var _pieces: Dictionary = {BLACK: [], WHITE: []}
var _winner_user_id: Variant = null
var _result: Variant = null
var _pending_action := {}


func _init(match_id: String) -> void:
	_match_id = match_id


func can_request_roll(local_user_id: String) -> bool:
	return revision >= 0 and status == STATUS_ACTIVE and phase == PHASE_AWAITING_ROLL \
		and _pending_action.is_empty() and _color_for_user(local_user_id) == next_color


func can_request_piece(piece_index: int, local_user_id: String) -> bool:
	return revision >= 0 and status == STATUS_ACTIVE and phase == PHASE_AWAITING_MOVE \
		and _pending_action.is_empty() and _color_for_user(local_user_id) == next_color \
		and movable_piece_indices().has(piece_index)


func can_request_resign(local_user_id: String) -> bool:
	return revision > 0 and status == STATUS_ACTIVE and _pending_action.is_empty() \
		and local_user_id in [black_user_id, white_user_id]


func mark_pending_roll(action_id: String, local_user_id: String) -> bool:
	if not can_request_roll(local_user_id) or not _canonical_uuid(action_id):
		return false
	_pending_action = {
		"action_id": action_id,
		"type": "flight_chess.roll.requested",
		"actor_user_id": local_user_id,
		"expected_revision": revision,
	}
	return true


func mark_pending_move(action_id: String, piece_index: int, local_user_id: String) -> bool:
	if not can_request_piece(piece_index, local_user_id) or not _canonical_uuid(action_id):
		return false
	_pending_action = {
		"action_id": action_id,
		"type": "flight_chess.move.requested",
		"actor_user_id": local_user_id,
		"piece_index": piece_index,
		"expected_revision": revision,
	}
	return true


func mark_pending_resign(action_id: String, local_user_id: String = "") -> bool:
	if not can_request_resign(local_user_id) or not _canonical_uuid(action_id):
		return false
	_pending_action = {
		"action_id": action_id,
		"type": "flight_chess.resign.requested",
		"actor_user_id": local_user_id,
		"expected_revision": revision,
	}
	return true


func clear_pending(action_id: String) -> bool:
	if _pending_action.get("action_id", "") != action_id:
		return false
	_pending_action.clear()
	return true


func movable_piece_indices() -> Array:
	if status != STATUS_ACTIVE or phase != PHASE_AWAITING_MOVE or dice < 1 or dice > 6 \
		or not _pieces.has(next_color):
		return []
	return _movable_pieces(next_color, _pieces[next_color], dice)


func visual_pieces() -> Dictionary:
	return {"red": _pieces[BLACK].duplicate(true), "yellow": _pieces[WHITE].duplicate(true)}


func board_color_for_user(user_id: String) -> String:
	var color := _color_for_user(user_id)
	return "red" if color == BLACK else "yellow" if color == WHITE else ""


func apply_snapshot(envelope: Dictionary) -> Dictionary:
	var validation := _validate_snapshot(envelope)
	if not validation.get("ok", false):
		return validation
	if envelope["revision"] < revision:
		return {"ok": true, "status": "ignored"}
	var payload: Dictionary = envelope["payload"]
	_revision = envelope["revision"]
	_status = payload["status"]
	_phase = payload["phase"]
	_black_user_id = payload["blackUserId"]
	_white_user_id = payload["whiteUserId"]
	_next_color = payload["nextColor"]
	_dice = payload["dice"]
	_consecutive_sixes = payload["consecutiveSixes"]
	_six_moved_piece_indices = payload["sixMovedPieceIndices"].duplicate()
	_pieces = payload["pieces"].duplicate(true)
	_winner_user_id = payload["winnerUserId"]
	_result = payload["result"]
	_pending_action.clear()
	return {"ok": true, "status": "applied"}


func apply_event(envelope: Dictionary) -> Dictionary:
	if not _valid_event_envelope(envelope):
		return _failure("invalid_event")
	var event_revision: int = envelope["revision"]
	if event_revision <= revision:
		return {"ok": true, "status": "ignored"}
	if event_revision != revision + 1:
		return {"ok": true, "status": "needs_snapshot"}
	if status != STATUS_ACTIVE:
		return _failure("invalid_event")
	var confirmation := _pending_confirmation(envelope)
	if not confirmation.get("ok", false):
		return confirmation
	var applied := {}
	match envelope["type"]:
		"flight_chess.roll.accepted":
			applied = _apply_roll(envelope)
		"flight_chess.move.accepted":
			applied = _apply_move(envelope)
		"flight_chess.resigned":
			applied = _apply_resignation(envelope)
		"platform.match.cancelled":
			applied = _apply_lifecycle(envelope, STATUS_CANCELLED)
		"platform.match.abandoned":
			applied = _apply_lifecycle(envelope, STATUS_ABANDONED)
		_:
			return _failure("invalid_event")
	if not applied.get("ok", false):
		return applied
	_revision = event_revision
	if confirmation.get("status") == "matching" or status != STATUS_ACTIVE:
		_pending_action.clear()
	return {"ok": true, "status": "applied"}


func apply_error(envelope: Dictionary) -> Dictionary:
	var expected := ["gameId", "matchId", "payload", "protocolVersion", "revision", "type"]
	if envelope.has("actionId"):
		expected.append("actionId")
	if not _exact_keys(envelope, expected) or not _valid_bound(envelope, "platform.error"):
		return _failure("invalid_error")
	if envelope.has("actionId") and not _canonical_uuid(envelope["actionId"]):
		return _failure("invalid_error")
	var payload: Variant = envelope["payload"]
	if not payload is Dictionary or not _exact_keys(payload, ["code", "details", "message"]) \
		or not payload["code"] is String or payload["code"].is_empty() \
		or not payload["message"] is String or payload["message"].is_empty() \
		or not payload["details"] is Dictionary or not payload["details"].is_empty():
		return _failure("invalid_error")
	var matching: bool = envelope.has("actionId") and envelope["actionId"] == _pending_action.get("action_id", "")
	if payload["code"] == "stale_revision":
		if envelope["revision"] < revision \
			or matching and envelope["revision"] <= _pending_action.get("expected_revision", -1):
			return _failure("invalid_error")
		if matching:
			_pending_action.clear()
		return {"ok": true, "status": "needs_snapshot", "code": payload["code"]}
	if envelope["revision"] != revision \
		or matching and envelope["revision"] != _pending_action.get("expected_revision", -1):
		return _failure("invalid_error")
	if matching:
		_pending_action.clear()
	return {"ok": true, "status": "handled", "code": payload["code"]}


func _apply_roll(envelope: Dictionary) -> Dictionary:
	var payload: Variant = envelope["payload"]
	if not payload is Dictionary or not _exact_keys(payload, [
		"color", "movablePieceIndices", "penalizedPieceIndices", "userId", "value",
	]) or payload.get("color") != next_color or _color_for_user(payload.get("userId", "")) != next_color \
		or typeof(payload.get("value")) != TYPE_INT or payload["value"] < 1 or payload["value"] > 6 \
		or not _valid_indices(payload.get("movablePieceIndices")) \
		or not _valid_indices(payload.get("penalizedPieceIndices")) \
		or phase != PHASE_AWAITING_ROLL or dice != 0:
		return _failure("invalid_event")
	var color := next_color
	var value: int = payload["value"]
	var expected_penalized: Array = []
	var expected_movable: Array = []
	var next_sixes := consecutive_sixes
	var next_moved := six_moved_piece_indices
	var next_phase := PHASE_AWAITING_ROLL
	var next_dice := 0
	var next_turn := next_color
	var next_pieces := _pieces.duplicate(true)
	if value == 6:
		next_sixes += 1
		if next_sixes == 3:
			expected_penalized = next_moved.duplicate()
			for piece_index in expected_penalized:
				next_pieces[color][piece_index] = {"zone": ZONE_HANGAR, "index": piece_index}
			next_sixes = 0
			next_moved = []
			next_turn = _opposite(color)
		else:
			expected_movable = _movable_pieces(color, next_pieces[color], value)
			if not expected_movable.is_empty():
				next_phase = PHASE_AWAITING_MOVE
				next_dice = value
	else:
		next_sixes = 0
		next_moved = []
		expected_movable = _movable_pieces(color, next_pieces[color], value)
		if not expected_movable.is_empty():
			next_phase = PHASE_AWAITING_MOVE
			next_dice = value
		else:
			next_turn = _opposite(color)
	if payload["movablePieceIndices"] != expected_movable \
		or payload["penalizedPieceIndices"] != expected_penalized:
		return _failure("invalid_event")
	_consecutive_sixes = next_sixes
	_six_moved_piece_indices = next_moved
	_phase = next_phase
	_dice = next_dice
	_next_color = next_turn
	_pieces = next_pieces
	return {"ok": true}


func _apply_move(envelope: Dictionary) -> Dictionary:
	var payload: Variant = envelope["payload"]
	if not payload is Dictionary or not _exact_keys(payload, [
		"capturedPieceIndices", "color", "effect", "from", "pieceIndex", "roll", "to", "userId",
	]) or payload.get("color") != next_color or _color_for_user(payload.get("userId", "")) != next_color \
		or typeof(payload.get("pieceIndex")) != TYPE_INT or payload["pieceIndex"] < 0 or payload["pieceIndex"] >= PIECE_COUNT \
		or typeof(payload.get("roll")) != TYPE_INT or payload["roll"] != dice \
		or not _valid_piece(payload.get("from"), payload["pieceIndex"]) \
		or not _valid_piece(payload.get("to"), payload["pieceIndex"]) \
		or payload.get("effect") not in ["none", "jump", "shortcut", "jump_shortcut"] \
		or not _valid_indices(payload.get("capturedPieceIndices")) \
		or phase != PHASE_AWAITING_MOVE:
		return _failure("invalid_event")
	var color := next_color
	var piece_index: int = payload["pieceIndex"]
	var from: Dictionary = _pieces[color][piece_index]
	var resolution := _resolve_move(color, from, dice)
	if not resolution.get("ok", false) or payload["from"] != from \
		or payload["to"] != resolution["to"] or payload["effect"] != resolution["effect"]:
		return _failure("invalid_event")
	var next_pieces := _pieces.duplicate(true)
	next_pieces[color][piece_index] = resolution["to"]
	var opponent := _opposite(color)
	var expected_captured: Array = []
	if resolution["to"]["zone"] == ZONE_MAIN:
		for opponent_index in PIECE_COUNT:
			if next_pieces[opponent][opponent_index] == resolution["to"]:
				next_pieces[opponent][opponent_index] = {"zone": ZONE_HANGAR, "index": opponent_index}
				expected_captured.append(opponent_index)
	if payload["capturedPieceIndices"] != expected_captured:
		return _failure("invalid_event")
	var roll := dice
	var next_sixes := consecutive_sixes
	var next_moved := six_moved_piece_indices
	if roll == 6:
		if not next_moved.has(piece_index):
			next_moved.append(piece_index)
	else:
		next_sixes = 0
		next_moved = []
	_pieces = next_pieces
	_dice = 0
	_phase = PHASE_AWAITING_ROLL
	_consecutive_sixes = next_sixes
	_six_moved_piece_indices = next_moved
	if _all_finished(next_pieces[color]):
		_status = STATUS_FINISHED
		_result = "goal"
		_winner_user_id = payload["userId"]
	elif roll != 6:
		_next_color = opponent
	return {"ok": true}


func _apply_resignation(envelope: Dictionary) -> Dictionary:
	var payload: Variant = envelope["payload"]
	if revision <= 0 or not payload is Dictionary or not _exact_keys(payload, ["userId", "winnerUserId"]) \
		or not _canonical_uuid(payload.get("userId")) or not _canonical_uuid(payload.get("winnerUserId")) \
		or payload["userId"] == payload["winnerUserId"] \
		or payload["userId"] not in [black_user_id, white_user_id] \
		or payload["winnerUserId"] not in [black_user_id, white_user_id]:
		return _failure("invalid_event")
	_status = STATUS_FINISHED
	_result = "resignation"
	_winner_user_id = payload["winnerUserId"]
	return {"ok": true}


func _apply_lifecycle(envelope: Dictionary, lifecycle_status: String) -> Dictionary:
	if not envelope["payload"].is_empty() or lifecycle_status == STATUS_CANCELLED and revision != 0:
		return _failure("invalid_event")
	_status = lifecycle_status
	_result = null
	_winner_user_id = null
	return {"ok": true}


func _pending_confirmation(envelope: Dictionary) -> Dictionary:
	if _pending_action.is_empty() or not envelope.has("actionId") \
		or envelope["actionId"] != _pending_action.get("action_id", ""):
		return {"ok": true, "status": "unrelated"}
	var payload: Dictionary = envelope["payload"]
	if payload.get("userId", "") != _pending_action.get("actor_user_id", ""):
		return {"ok": true, "status": "unrelated"}
	if envelope["revision"] != _pending_action.get("expected_revision", -1) + 1:
		return _failure("invalid_event")
	match _pending_action.get("type", ""):
		"flight_chess.roll.requested":
			if envelope["type"] != "flight_chess.roll.accepted":
				return _failure("invalid_event")
		"flight_chess.move.requested":
			if envelope["type"] != "flight_chess.move.accepted" \
				or payload.get("pieceIndex") != _pending_action.get("piece_index"):
				return _failure("invalid_event")
		"flight_chess.resign.requested":
			if envelope["type"] != "flight_chess.resigned":
				return _failure("invalid_event")
		_:
			return _failure("invalid_event")
	return {"ok": true, "status": "matching"}


func _validate_snapshot(envelope: Dictionary) -> Dictionary:
	if not _exact_keys(envelope, ["gameId", "matchId", "payload", "protocolVersion", "revision", "type"]) \
		or not _valid_bound(envelope, "platform.snapshot"):
		return _failure("invalid_snapshot")
	var payload: Variant = envelope["payload"]
	if not payload is Dictionary or not _exact_keys(payload, [
		"blackUserId", "consecutiveSixes", "dice", "nextColor", "phase", "pieces", "result", \
		"sixMovedPieceIndices", "status", "whiteUserId", "winnerUserId",
	]) or not _canonical_uuid(payload.get("blackUserId")) or not _canonical_uuid(payload.get("whiteUserId")) \
		or payload["blackUserId"] == payload["whiteUserId"] \
		or payload.get("nextColor") not in [BLACK, WHITE] \
		or payload.get("phase") not in [PHASE_AWAITING_ROLL, PHASE_AWAITING_MOVE] \
		or typeof(payload.get("dice")) != TYPE_INT \
		or typeof(payload.get("consecutiveSixes")) != TYPE_INT \
		or payload["consecutiveSixes"] < 0 or payload["consecutiveSixes"] > 2 \
		or not _valid_indices(payload.get("sixMovedPieceIndices")) \
		or not _valid_pieces(payload.get("pieces")):
		return _failure("invalid_snapshot")
	if payload["phase"] == PHASE_AWAITING_ROLL and payload["dice"] != 0:
		return _failure("invalid_snapshot")
	if payload["phase"] == PHASE_AWAITING_MOVE:
		if payload["dice"] < 1 or payload["dice"] > 6 \
			or _movable_pieces(payload["nextColor"], payload["pieces"][payload["nextColor"]], payload["dice"]).is_empty():
			return _failure("invalid_snapshot")
	var black_finished := _all_finished(payload["pieces"][BLACK])
	var white_finished := _all_finished(payload["pieces"][WHITE])
	match payload.get("status"):
		STATUS_ACTIVE:
			if payload["result"] != null or payload["winnerUserId"] != null or black_finished or white_finished:
				return _failure("invalid_snapshot")
		STATUS_FINISHED:
			if payload["result"] == "goal":
				if payload["winnerUserId"] not in [payload["blackUserId"], payload["whiteUserId"]] \
					or black_finished == white_finished \
					or black_finished != (payload["winnerUserId"] == payload["blackUserId"]):
					return _failure("invalid_snapshot")
			elif payload["result"] == "resignation":
				if envelope["revision"] < 2 or payload["winnerUserId"] not in [payload["blackUserId"], payload["whiteUserId"]] \
					or black_finished or white_finished:
					return _failure("invalid_snapshot")
			else:
				return _failure("invalid_snapshot")
		STATUS_CANCELLED:
			if envelope["revision"] != 1 or payload["result"] != null or payload["winnerUserId"] != null:
				return _failure("invalid_snapshot")
		STATUS_ABANDONED:
			if payload["result"] != null or payload["winnerUserId"] != null:
				return _failure("invalid_snapshot")
		_:
			return _failure("invalid_snapshot")
	return {"ok": true}


func _valid_event_envelope(envelope: Dictionary) -> bool:
	var message_type: Variant = envelope.get("type")
	var has_action: bool = message_type in [
		"flight_chess.roll.accepted", "flight_chess.move.accepted", "flight_chess.resigned",
	]
	var expected := ["actionId", "gameId", "matchId", "payload", "protocolVersion", "revision", "type"] if has_action \
		else ["gameId", "matchId", "payload", "protocolVersion", "revision", "type"]
	return _exact_keys(envelope, expected) and _valid_bound(envelope, message_type) \
		and envelope["payload"] is Dictionary and (not has_action or _canonical_uuid(envelope["actionId"]))


func _valid_bound(envelope: Dictionary, message_type: String) -> bool:
	return envelope.get("protocolVersion") == 1 and envelope.get("gameId") == GAME_ID \
		and envelope.get("matchId") == _match_id and envelope.get("type") == message_type \
		and typeof(envelope.get("revision")) == TYPE_INT and envelope["revision"] >= 0 \
		and not envelope.has("expectedRevision")


func _color_for_user(user_id: String) -> String:
	if user_id == black_user_id:
		return BLACK
	if user_id == white_user_id:
		return WHITE
	return ""


static func _resolve_move(color: String, piece: Dictionary, roll: int) -> Dictionary:
	if roll < 1 or roll > 6:
		return {"ok": false}
	match piece["zone"]:
		ZONE_HANGAR:
			if roll != 6:
				return {"ok": false}
			return {"ok": true, "to": {"zone": ZONE_LAUNCH, "index": 0}, "effect": "none"}
		ZONE_LAUNCH:
			return _resolve_main_progress(color, roll)
		ZONE_MAIN:
			var progress := _progress_for_index(color, piece["index"])
			if progress < 1:
				return {"ok": false}
			return _resolve_progress(color, progress + roll)
		ZONE_HOME:
			var target: int = piece["index"] + roll
			if target < HOME_CELL_COUNT:
				return {"ok": true, "to": {"zone": ZONE_HOME, "index": target}, "effect": "none"}
			if target == HOME_CELL_COUNT:
				return {"ok": true, "to": {"zone": ZONE_FINISHED, "index": 0}, "effect": "none"}
	return {"ok": false}


static func _resolve_progress(color: String, progress: int) -> Dictionary:
	if progress <= 0:
		return {"ok": false}
	if progress <= 50:
		return _resolve_main_progress(color, progress)
	if progress <= 50 + HOME_CELL_COUNT:
		return {"ok": true, "to": {"zone": ZONE_HOME, "index": progress - 51}, "effect": "none"}
	if progress == 51 + HOME_CELL_COUNT:
		return {"ok": true, "to": {"zone": ZONE_FINISHED, "index": 0}, "effect": "none"}
	return {"ok": false}


static func _resolve_main_progress(color: String, progress: int) -> Dictionary:
	if progress < 1 or progress > 50:
		return _resolve_progress(color, progress)
	var effect := "none"
	var resolved := progress
	if resolved == 18:
		resolved = 30
		effect = "shortcut"
	elif resolved % 4 == 2 and resolved < 50:
		resolved += 4
		effect = "jump"
		if resolved == 18:
			resolved = 30
			effect = "jump_shortcut"
	return {
		"ok": true,
		"to": {"zone": ZONE_MAIN, "index": _index_for_progress(color, resolved)},
		"effect": effect,
	}


static func _movable_pieces(color: String, color_pieces: Array, roll: int) -> Array:
	var result: Array = []
	for piece_index in color_pieces.size():
		if _resolve_move(color, color_pieces[piece_index], roll).get("ok", false):
			result.append(piece_index)
	return result


static func _progress_for_index(color: String, index: int) -> int:
	if color not in START_INDICES or index < 0 or index >= MAIN_CELL_COUNT:
		return -1
	var progress: int = (index - int(START_INDICES[color]) + MAIN_CELL_COUNT) % MAIN_CELL_COUNT + 1
	return progress if progress <= 50 else -1


static func _index_for_progress(color: String, progress: int) -> int:
	return (int(START_INDICES[color]) + progress - 1) % MAIN_CELL_COUNT


static func _opposite(color: String) -> String:
	return WHITE if color == BLACK else BLACK


static func _all_finished(color_pieces: Array) -> bool:
	if color_pieces.size() != PIECE_COUNT:
		return false
	for piece in color_pieces:
		if piece["zone"] != ZONE_FINISHED:
			return false
	return true


static func _valid_pieces(value: Variant) -> bool:
	if not value is Dictionary or not _exact_keys(value, [BLACK, WHITE]):
		return false
	for color in [BLACK, WHITE]:
		if not value[color] is Array or value[color].size() != PIECE_COUNT:
			return false
		for piece_index in PIECE_COUNT:
			if not _valid_piece(value[color][piece_index], piece_index):
				return false
			if value[color][piece_index]["zone"] == ZONE_MAIN \
				and _progress_for_index(color, value[color][piece_index]["index"]) < 1:
				return false
	return true


static func _valid_piece(value: Variant, slot: int) -> bool:
	if not value is Dictionary or not _exact_keys(value, ["index", "zone"]) \
		or not value["zone"] is String or typeof(value["index"]) != TYPE_INT:
		return false
	match value["zone"]:
		ZONE_HANGAR:
			return value["index"] == slot
		ZONE_LAUNCH, ZONE_FINISHED:
			return value["index"] == 0
		ZONE_MAIN:
			return value["index"] >= 0 and value["index"] < MAIN_CELL_COUNT
		ZONE_HOME:
			return value["index"] >= 0 and value["index"] < HOME_CELL_COUNT
	return false


static func _valid_indices(value: Variant) -> bool:
	if not value is Array:
		return false
	var seen := {}
	for index in value:
		if typeof(index) != TYPE_INT or index < 0 or index >= PIECE_COUNT or seen.has(index):
			return false
		seen[index] = true
	return true


static func _canonical_uuid(value: Variant) -> bool:
	return value is String and RegEx.create_from_string(
		"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
	).search(value) != null


static func _exact_keys(value: Dictionary, expected: Array) -> bool:
	if value.size() != expected.size():
		return false
	for key in value:
		if not key is String or not expected.has(key):
			return false
	return true


static func _failure(code: String) -> Dictionary:
	return {"ok": false, "code": code}
