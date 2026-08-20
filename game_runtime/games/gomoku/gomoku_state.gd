extends RefCounted

const BOARD_SIZE := 15
const BOARD_CELLS := BOARD_SIZE * BOARD_SIZE
const EMPTY := 0
const BLACK := 1
const WHITE := 2

const STATUS_ACTIVE := "active"
const STATUS_FINISHED := "finished"
const STATUS_CANCELLED := "cancelled"
const STATUS_ABANDONED := "abandoned"

var revision: int:
	get:
		return _revision
	set(_value):
		pass

var status: String:
	get:
		return _status
	set(_value):
		pass

var black_user_id: String:
	get:
		return _black_user_id
	set(_value):
		pass

var white_user_id: String:
	get:
		return _white_user_id
	set(_value):
		pass

var next_color: String:
	get:
		return _next_color
	set(_value):
		pass

var winner_user_id: Variant:
	get:
		return _winner_user_id
	set(_value):
		pass

var result: Variant:
	get:
		return _result
	set(_value):
		pass

var board: Array:
	get:
		return _board.duplicate()
	set(_value):
		pass

var pending_action: Dictionary:
	get:
		return _pending_action.duplicate(true)
	set(_value):
		pass

var _match_id := ""
var _revision := -1
var _status := ""
var _black_user_id := ""
var _white_user_id := ""
var _next_color := ""
var _winner_user_id: Variant = null
var _result: Variant = null
var _board: Array = []
var _pending_action := {}


func _init(match_id: String) -> void:
	_match_id = match_id
	_board.resize(BOARD_CELLS)
	_board.fill(EMPTY)


func cell(x: int, y: int) -> int:
	if not _in_bounds(x, y):
		return -1
	return _board[y * BOARD_SIZE + x]


func can_request_move(x: int, y: int, local_user_id: String) -> bool:
	if revision < 0 or status != STATUS_ACTIVE or not _pending_action.is_empty() or not _in_bounds(x, y):
		return false
	if _board[y * BOARD_SIZE + x] != EMPTY:
		return false
	return _user_color(local_user_id) == next_color


func can_request_resign(local_user_id: String) -> bool:
	return revision > 0 and status == STATUS_ACTIVE and _pending_action.is_empty() \
		and (local_user_id == black_user_id or local_user_id == white_user_id)


func mark_pending(action_id: String, x: int, y: int) -> bool:
	var actor_user_id := _actor_for_color(next_color)
	if not _pending_action.is_empty() or not _canonical_uuid(action_id) or not _in_bounds(x, y) \
		or status != STATUS_ACTIVE or actor_user_id.is_empty():
		return false
	_pending_action = {
		"action_id": action_id,
		"type": "gomoku.move.requested",
		"actor_user_id": actor_user_id,
		"x": x,
		"y": y,
		"expected_revision": revision,
	}
	return true


func mark_pending_resign(action_id: String, local_user_id: String = "") -> bool:
	if not _pending_action.is_empty() or not _canonical_uuid(action_id) or revision <= 0 \
		or status != STATUS_ACTIVE or local_user_id not in [black_user_id, white_user_id]:
		return false
	_pending_action = {
		"action_id": action_id,
		"type": "gomoku.resign.requested",
		"actor_user_id": local_user_id,
		"expected_revision": revision,
	}
	return true


func clear_pending(action_id: String) -> bool:
	if _pending_action.get("action_id", "") != action_id:
		return false
	_pending_action.clear()
	return true


func apply_snapshot(envelope: Dictionary) -> Dictionary:
	var validation := _validate_snapshot(envelope)
	if not validation.get("ok", false):
		return validation
	var next_revision: int = envelope["revision"]
	if next_revision < revision:
		return {"ok": true, "status": "ignored"}
	var payload: Dictionary = envelope["payload"]
	_board = payload["board"].duplicate()
	_revision = next_revision
	_status = payload["status"]
	_black_user_id = payload["blackUserId"]
	_white_user_id = payload["whiteUserId"]
	_next_color = payload["nextColor"]
	_winner_user_id = payload["winnerUserId"]
	_result = payload["result"]
	# A valid snapshot is the server's complete answer for this revision. It
	# settles an action whose delivery was ambiguous without ever replaying it.
	_pending_action.clear()
	return {"ok": true, "status": "applied"}


func apply_event(envelope: Dictionary) -> Dictionary:
	var validation := _validate_event_envelope(envelope)
	if not validation.get("ok", false):
		return validation
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

	var event_type: String = envelope["type"]
	var result_value: Dictionary
	match event_type:
		"gomoku.move.accepted":
			result_value = _apply_move(envelope)
		"gomoku.resigned":
			result_value = _apply_resignation(envelope)
		"platform.match.cancelled":
			result_value = _apply_lifecycle(envelope, STATUS_CANCELLED)
		"platform.match.abandoned":
			result_value = _apply_lifecycle(envelope, STATUS_ABANDONED)
		_:
			return _failure("invalid_event")
	if not result_value.get("ok", false):
		return result_value
	_revision = event_revision
	if confirmation.get("status") == "matching":
		_pending_action.clear()
	if status != STATUS_ACTIVE:
		_pending_action.clear()
	return {"ok": true, "status": "applied"}


func apply_error(envelope: Dictionary) -> Dictionary:
	var expected_keys := ["gameId", "matchId", "payload", "protocolVersion", "revision", "type"]
	if envelope.has("actionId"):
		expected_keys.append("actionId")
	if not _exact_keys(envelope, expected_keys) or not _valid_bound_envelope(envelope, "platform.error"):
		return _failure("invalid_error")
	if envelope.has("actionId") and not _canonical_uuid(envelope["actionId"]):
		return _failure("invalid_error")
	var payload: Variant = envelope["payload"]
	if not payload is Dictionary or not _exact_keys(payload, ["code", "details", "message"]):
		return _failure("invalid_error")
	if not payload["code"] is String or payload["code"].is_empty() or payload["code"].length() > 64 \
		or not payload["message"] is String or payload["message"].is_empty() or payload["message"].length() > 256 \
		or not payload["details"] is Dictionary or not payload["details"].is_empty():
		return _failure("invalid_error")
	var error_revision: int = envelope["revision"]
	var code: String = payload["code"]
	var matching_pending: bool = envelope.has("actionId") \
		and envelope["actionId"] == _pending_action.get("action_id", "")
	if code == "stale_revision":
		if error_revision < revision \
			or (matching_pending and error_revision <= _pending_action.get("expected_revision", -1)):
			return _failure("invalid_error")
		if matching_pending:
			_pending_action.clear()
		return {"ok": true, "status": "needs_snapshot", "code": code}
	if error_revision != revision \
		or (matching_pending and error_revision != _pending_action.get("expected_revision", -1)):
		return _failure("invalid_error")
	if matching_pending:
		_pending_action.clear()
	return {"ok": true, "status": "handled", "code": code}


func _pending_confirmation(envelope: Dictionary) -> Dictionary:
	if _pending_action.is_empty() or not envelope.has("actionId") \
		or envelope["actionId"] != _pending_action.get("action_id", ""):
		return {"ok": true, "status": "unrelated"}
	var payload: Dictionary = envelope["payload"]
	var actor_user_id: String = payload.get("userId", "")
	if actor_user_id != _pending_action.get("actor_user_id", ""):
		return {"ok": true, "status": "unrelated"}
	if envelope["revision"] != _pending_action.get("expected_revision", -1) + 1:
		return _failure("invalid_event")
	match _pending_action.get("type", ""):
		"gomoku.move.requested":
			if envelope["type"] != "gomoku.move.accepted" \
				or payload.get("x") != _pending_action.get("x") \
				or payload.get("y") != _pending_action.get("y"):
				return _failure("invalid_event")
		"gomoku.resign.requested":
			if envelope["type"] != "gomoku.resigned" or payload.get("userId") != actor_user_id:
				return _failure("invalid_event")
		_:
			return _failure("invalid_event")
	return {"ok": true, "status": "matching"}


func _apply_move(envelope: Dictionary) -> Dictionary:
	var payload: Dictionary = envelope["payload"]
	var x: int = payload["x"]
	var y: int = payload["y"]
	var color: String = payload["color"]
	var user_id: String = payload["userId"]
	if not _in_bounds(x, y) or _board[y * BOARD_SIZE + x] != EMPTY \
		or color != next_color or _user_color(user_id) != color:
		return _failure("invalid_event")
	var stone := BLACK if color == "black" else WHITE
	_board[y * BOARD_SIZE + x] = stone
	_next_color = "white" if color == "black" else "black"
	if _has_five(x, y, stone):
		_status = STATUS_FINISHED
		_result = "five"
		_winner_user_id = user_id
	elif not _board.has(EMPTY):
		_status = STATUS_FINISHED
		_result = "draw"
		_winner_user_id = null
	return {"ok": true}


func _apply_resignation(envelope: Dictionary) -> Dictionary:
	if revision <= 0:
		return _failure("invalid_event")
	var payload: Dictionary = envelope["payload"]
	var user_id: String = payload["userId"]
	var winner_id: String = payload["winnerUserId"]
	if user_id == winner_id or not (user_id == black_user_id or user_id == white_user_id) \
		or not (winner_id == black_user_id or winner_id == white_user_id):
		return _failure("invalid_event")
	_status = STATUS_FINISHED
	_result = "resignation"
	_winner_user_id = winner_id
	return {"ok": true}


func _apply_lifecycle(envelope: Dictionary, lifecycle_status: String) -> Dictionary:
	if not envelope["payload"].is_empty():
		return _failure("invalid_event")
	if lifecycle_status == STATUS_CANCELLED and revision != 0:
		return _failure("invalid_event")
	_status = lifecycle_status
	_result = null
	_winner_user_id = null
	return {"ok": true}


func _validate_snapshot(envelope: Dictionary) -> Dictionary:
	if not _exact_keys(envelope, ["gameId", "matchId", "payload", "protocolVersion", "revision", "type"]) \
		or not _valid_bound_envelope(envelope, "platform.snapshot"):
		return _failure("invalid_snapshot")
	var payload: Variant = envelope["payload"]
	if not payload is Dictionary or not _exact_keys(payload, [
		"blackUserId", "board", "boardSize", "nextColor", "result", "status", "whiteUserId", "winnerUserId",
	]):
		return _failure("invalid_snapshot")
	if typeof(payload["boardSize"]) != TYPE_INT or payload["boardSize"] != BOARD_SIZE \
		or not payload["board"] is Array or payload["board"].size() != BOARD_CELLS:
		return _failure("invalid_snapshot")
	var black_count := 0
	var white_count := 0
	for cell_value in payload["board"]:
		if typeof(cell_value) != TYPE_INT or cell_value < EMPTY or cell_value > WHITE:
			return _failure("invalid_snapshot")
		black_count += 1 if cell_value == BLACK else 0
		white_count += 1 if cell_value == WHITE else 0
	if black_count < white_count or black_count > white_count + 1:
		return _failure("invalid_snapshot")
	if not _canonical_uuid(payload["blackUserId"]) or not _canonical_uuid(payload["whiteUserId"]) \
		or payload["blackUserId"] == payload["whiteUserId"]:
		return _failure("invalid_snapshot")
	var expected_next := "white" if black_count > white_count else "black"
	if not payload["nextColor"] is String or payload["nextColor"] != expected_next:
		return _failure("invalid_snapshot")
	if not payload["status"] is String:
		return _failure("invalid_snapshot")
	var move_count := black_count + white_count
	var snapshot_revision: int = envelope["revision"]
	var black_has_five := _array_has_five(payload["board"], BLACK)
	var white_has_five := _array_has_five(payload["board"], WHITE)
	match payload["status"]:
		STATUS_ACTIVE:
			if payload["result"] != null or payload["winnerUserId"] != null or snapshot_revision != move_count \
				or move_count == BOARD_CELLS or black_has_five or white_has_five:
				return _failure("invalid_snapshot")
		STATUS_FINISHED:
			if not payload["result"] is String or not payload["result"] in ["five", "draw", "resignation"]:
				return _failure("invalid_snapshot")
			if payload["result"] == "draw":
				if payload["winnerUserId"] != null or snapshot_revision != move_count \
					or move_count != BOARD_CELLS or black_has_five or white_has_five:
					return _failure("invalid_snapshot")
			elif not payload["winnerUserId"] is String \
				or not payload["winnerUserId"] in [payload["blackUserId"], payload["whiteUserId"]] \
				or snapshot_revision != move_count + (1 if payload["result"] == "resignation" else 0):
				return _failure("invalid_snapshot")
			elif payload["result"] == "five":
				var winner_is_black: bool = payload["winnerUserId"] == payload["blackUserId"]
				if winner_is_black != black_has_five or winner_is_black == white_has_five \
					or (winner_is_black and black_count != white_count + 1) \
					or (not winner_is_black and black_count != white_count):
					return _failure("invalid_snapshot")
			elif move_count == BOARD_CELLS or black_has_five or white_has_five:
				return _failure("invalid_snapshot")
			if payload["result"] == "resignation" and move_count == 0:
				return _failure("invalid_snapshot")
		STATUS_CANCELLED:
			if payload["result"] != null or payload["winnerUserId"] != null or move_count != 0 or snapshot_revision != 1:
				return _failure("invalid_snapshot")
		STATUS_ABANDONED:
			if payload["result"] != null or payload["winnerUserId"] != null or snapshot_revision != move_count + 1 \
				or move_count == BOARD_CELLS or black_has_five or white_has_five:
				return _failure("invalid_snapshot")
		_:
			return _failure("invalid_snapshot")
	return {"ok": true}


func _validate_event_envelope(envelope: Dictionary) -> Dictionary:
	if not envelope is Dictionary or not envelope.has("type") or not envelope["type"] is String:
		return _failure("invalid_event")
	var event_type: String = envelope["type"]
	var expected_keys := ["gameId", "matchId", "payload", "protocolVersion", "revision", "type"]
	if event_type in ["gomoku.move.accepted", "gomoku.resigned"]:
		expected_keys.append("actionId")
	if not _exact_keys(envelope, expected_keys) or not _valid_bound_envelope(envelope, event_type):
		return _failure("invalid_event")
	var payload: Variant = envelope["payload"]
	if not payload is Dictionary:
		return _failure("invalid_event")
	match event_type:
		"gomoku.move.accepted":
			if not _canonical_uuid(envelope["actionId"]) or not _exact_keys(payload, ["color", "userId", "x", "y"]) \
				or typeof(payload["x"]) != TYPE_INT or typeof(payload["y"]) != TYPE_INT \
				or not payload["color"] is String or not payload["color"] in ["black", "white"] \
				or not _canonical_uuid(payload["userId"]):
				return _failure("invalid_event")
		"gomoku.resigned":
			if not _canonical_uuid(envelope["actionId"]) or not _exact_keys(payload, ["userId", "winnerUserId"]) \
				or not _canonical_uuid(payload["userId"]) or not _canonical_uuid(payload["winnerUserId"]):
				return _failure("invalid_event")
		"platform.match.cancelled", "platform.match.abandoned":
			if not payload.is_empty():
				return _failure("invalid_event")
		_:
			return _failure("invalid_event")
	return {"ok": true}


func _valid_bound_envelope(envelope: Dictionary, expected_type: String) -> bool:
	return typeof(envelope.get("protocolVersion")) == TYPE_INT and envelope["protocolVersion"] == 1 \
		and envelope.get("gameId") == "gomoku" and envelope.get("matchId") == _match_id \
		and _canonical_uuid(_match_id) and typeof(envelope.get("revision")) == TYPE_INT \
		and envelope["revision"] >= 0 and envelope.get("type") == expected_type


func _user_color(user_id: String) -> String:
	if user_id == black_user_id:
		return "black"
	if user_id == white_user_id:
		return "white"
	return ""


func _actor_for_color(color: String) -> String:
	if color == "black":
		return black_user_id
	if color == "white":
		return white_user_id
	return ""


func _has_five(x: int, y: int, stone: int) -> bool:
	for direction in [Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(1, -1)]:
		var count := 1 + _ray_count(x, y, direction.x, direction.y, stone) \
			+ _ray_count(x, y, -direction.x, -direction.y, stone)
		if count >= 5:
			return true
	return false


func _ray_count(x: int, y: int, dx: int, dy: int, stone: int) -> int:
	var count := 0
	x += dx
	y += dy
	while _in_bounds(x, y) and _board[y * BOARD_SIZE + x] == stone:
		count += 1
		x += dx
		y += dy
	return count


static func _array_has_five(cells: Array, stone: int) -> bool:
	for y in BOARD_SIZE:
		for x in BOARD_SIZE:
			if cells[y * BOARD_SIZE + x] != stone:
				continue
			for direction in [Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(1, -1)]:
				var previous_x: int = x - direction.x
				var previous_y: int = y - direction.y
				if previous_x >= 0 and previous_x < BOARD_SIZE and previous_y >= 0 and previous_y < BOARD_SIZE \
					and cells[previous_y * BOARD_SIZE + previous_x] == stone:
					continue
				var run := 0
				var scan_x: int = x
				var scan_y: int = y
				while scan_x >= 0 and scan_x < BOARD_SIZE and scan_y >= 0 and scan_y < BOARD_SIZE \
					and cells[scan_y * BOARD_SIZE + scan_x] == stone:
					run += 1
					scan_x += direction.x
					scan_y += direction.y
				if run >= 5:
					return true
	return false


func _in_bounds(x: int, y: int) -> bool:
	return x >= 0 and x < BOARD_SIZE and y >= 0 and y < BOARD_SIZE


static func _exact_keys(value: Dictionary, expected: Array) -> bool:
	if value.size() != expected.size():
		return false
	for key in value:
		if not key is String or not expected.has(key):
			return false
	return true


static func _canonical_uuid(value: Variant) -> bool:
	if not value is String:
		return false
	var pattern := RegEx.create_from_string("^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
	return pattern.search(value) != null


static func _failure(code: String) -> Dictionary:
	return {"ok": false, "code": code, "message": "Invalid authoritative match state."}
