extends RefCounted

const BOARD_CELLS := 121
const EMPTY := 0
const BLACK := 1
const WHITE := 2
const STATUS_ACTIVE := "active"
const STATUS_FINISHED := "finished"
const STATUS_CANCELLED := "cancelled"
const STATUS_ABANDONED := "abandoned"
const ROW_LENGTHS := [1, 2, 3, 4, 13, 12, 11, 10, 9, 10, 11, 12, 13, 4, 3, 2, 1]
const ROW_STARTS := [12, 11, 10, 9, 0, 1, 2, 3, 4, 3, 2, 1, 0, 9, 10, 11, 12]
const ADJACENT_DELTAS := [Vector2i(-2, 0), Vector2i(2, 0), Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1)]
const JUMP_DELTAS := [Vector2i(-4, 0), Vector2i(4, 0), Vector2i(-2, -2), Vector2i(2, -2), Vector2i(-2, 2), Vector2i(2, 2)]

var revision: int:
	get: return _revision
	set(_value): pass
var status: String:
	get: return _status
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
var winner_user_id: Variant:
	get: return _winner_user_id
	set(_value): pass
var result: Variant:
	get: return _result
	set(_value): pass
var board: Array:
	get: return _board.duplicate()
	set(_value): pass
var pending_action: Dictionary:
	get: return _pending_action.duplicate(true)
	set(_value): pass

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


func can_request_path(path: Array, local_user_id: String) -> bool:
	var color := _user_stone(local_user_id)
	return revision >= 0 and status == STATUS_ACTIVE and _pending_action.is_empty() \
		and color != EMPTY and _color_name(color) == next_color \
		and is_legal_path(_board, color, path)


func can_request_resign(local_user_id: String) -> bool:
	return revision > 0 and status == STATUS_ACTIVE and _pending_action.is_empty() \
		and local_user_id in [black_user_id, white_user_id]


func mark_pending_path(action_id: String, path: Array, local_user_id: String) -> bool:
	if not can_request_path(path, local_user_id) or not _canonical_uuid(action_id):
		return false
	_pending_action = {
		"action_id": action_id,
		"type": "chinese_checkers.move.requested",
		"actor_user_id": local_user_id,
		"path": path.duplicate(),
		"expected_revision": revision,
	}
	return true


func mark_pending_resign(action_id: String, local_user_id: String = "") -> bool:
	if not can_request_resign(local_user_id) or not _canonical_uuid(action_id):
		return false
	_pending_action = {
		"action_id": action_id,
		"type": "chinese_checkers.resign.requested",
		"actor_user_id": local_user_id,
		"expected_revision": revision,
	}
	return true


func clear_pending(action_id: String) -> bool:
	if _pending_action.get("action_id", "") != action_id:
		return false
	_pending_action.clear()
	return true


func legal_paths_from(source: int, local_user_id: String) -> Dictionary:
	var color := _user_stone(local_user_id)
	if revision < 0 or status != STATUS_ACTIVE or not _pending_action.is_empty() \
		or color == EMPTY or _color_name(color) != next_color or source < 0 or source >= BOARD_CELLS \
		or _board[source] != color:
		return {}
	var paths := {}
	var source_point := point_for_index(source)
	for delta in ADJACENT_DELTAS:
		var destination := index_for_point(source_point + delta)
		if destination >= 0 and is_legal_path(_board, color, [source, destination]):
			paths[destination] = [source, destination]

	var occupancy := _board.duplicate()
	occupancy[source] = EMPTY
	var queue: Array = [[source]]
	var visited := {}
	visited[source] = true
	while not queue.is_empty():
		var path: Array = queue.pop_front()
		var current: int = path.back()
		var current_point := point_for_index(current)
		for delta in JUMP_DELTAS:
			var destination := index_for_point(current_point + delta)
			var middle := index_for_point(current_point + Vector2i(int(delta.x / 2), int(delta.y / 2)))
			if destination < 0 or middle < 0 or visited.has(destination) \
				or occupancy[destination] != EMPTY or occupancy[middle] == EMPTY:
				continue
			var next_path: Array = path.duplicate()
			next_path.append(destination)
			visited[destination] = true
			queue.append(next_path)
			if _valid_endpoint(source, destination, color):
				paths[destination] = next_path
	return paths


func is_legal_path(cells: Array, color: int, path: Array) -> bool:
	if not _valid_board(cells) or color not in [BLACK, WHITE] or path.size() < 2 or path.size() > BOARD_CELLS:
		return false
	var seen := {}
	for value in path:
		if typeof(value) != TYPE_INT or value < 0 or value >= BOARD_CELLS or seen.has(value):
			return false
		seen[value] = true
	var source: int = path[0]
	var destination: int = path.back()
	if cells[source] != color or cells[destination] != EMPTY or not _valid_endpoint(source, destination, color):
		return false
	var simulated := cells.duplicate()
	simulated[source] = EMPTY
	var current := source
	for path_index in range(1, path.size()):
		var next: int = path[path_index]
		if simulated[next] != EMPTY:
			return false
		var delta := point_for_index(next) - point_for_index(current)
		if delta in ADJACENT_DELTAS:
			if path.size() != 2:
				return false
		elif delta in JUMP_DELTAS:
			var middle := index_for_point(point_for_index(current) + Vector2i(int(delta.x / 2), int(delta.y / 2)))
			if middle < 0 or simulated[middle] == EMPTY:
				return false
		else:
			return false
		simulated[current] = EMPTY
		simulated[next] = color
		current = next
	return true


func apply_snapshot(envelope: Dictionary) -> Dictionary:
	var validation := _validate_snapshot(envelope)
	if not validation.get("ok", false):
		return validation
	if envelope["revision"] < revision:
		return {"ok": true, "status": "ignored"}
	var payload: Dictionary = envelope["payload"]
	_board = payload["board"].duplicate()
	_revision = envelope["revision"]
	_status = payload["status"]
	_black_user_id = payload["blackUserId"]
	_white_user_id = payload["whiteUserId"]
	_next_color = payload["nextColor"]
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
		"chinese_checkers.move.accepted":
			applied = _apply_move(envelope)
		"chinese_checkers.resigned":
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
		if envelope["revision"] < revision or matching and envelope["revision"] <= _pending_action.get("expected_revision", -1):
			return _failure("invalid_error")
		if matching:
			_pending_action.clear()
		return {"ok": true, "status": "needs_snapshot", "code": payload["code"]}
	if envelope["revision"] != revision or matching and envelope["revision"] != _pending_action.get("expected_revision", -1):
		return _failure("invalid_error")
	if matching:
		_pending_action.clear()
	return {"ok": true, "status": "handled", "code": payload["code"]}


func _apply_move(envelope: Dictionary) -> Dictionary:
	var payload: Variant = envelope["payload"]
	if not payload is Dictionary or not _exact_keys(payload, ["color", "path", "userId"]) \
		or not payload["color"] is String or payload["color"] != next_color \
		or not _canonical_uuid(payload["userId"]):
		return _failure("invalid_event")
	var color := BLACK if payload["color"] == "black" else WHITE if payload["color"] == "white" else EMPTY
	if color == EMPTY or _user_stone(payload["userId"]) != color or not payload["path"] is Array \
		or not is_legal_path(_board, color, payload["path"]):
		return _failure("invalid_event")
	var path: Array = payload["path"]
	_board[path[0]] = EMPTY
	_board[path.back()] = color
	_next_color = "white" if color == BLACK else "black"
	if _completed_camp(_board, color):
		_status = STATUS_FINISHED
		_result = "goal"
		_winner_user_id = payload["userId"]
	return {"ok": true}


func _apply_resignation(envelope: Dictionary) -> Dictionary:
	var payload: Variant = envelope["payload"]
	if revision <= 0 or not payload is Dictionary or not _exact_keys(payload, ["userId", "winnerUserId"]) \
		or not _canonical_uuid(payload["userId"]) or not _canonical_uuid(payload["winnerUserId"]) \
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
		"chinese_checkers.move.requested":
			if envelope["type"] != "chinese_checkers.move.accepted" or payload.get("path") != _pending_action.get("path"):
				return _failure("invalid_event")
		"chinese_checkers.resign.requested":
			if envelope["type"] != "chinese_checkers.resigned":
				return _failure("invalid_event")
		_:
			return _failure("invalid_event")
	return {"ok": true, "status": "matching"}


func _validate_snapshot(envelope: Dictionary) -> Dictionary:
	if not _exact_keys(envelope, ["gameId", "matchId", "payload", "protocolVersion", "revision", "type"]) \
		or not _valid_bound(envelope, "platform.snapshot"):
		return _failure("invalid_snapshot")
	var payload: Variant = envelope["payload"]
	if not payload is Dictionary or not _exact_keys(payload, ["blackUserId", "board", "nextColor", "result", "status", "whiteUserId", "winnerUserId"]) \
		or not _valid_board(payload.get("board")) \
		or not _canonical_uuid(payload.get("blackUserId")) or not _canonical_uuid(payload.get("whiteUserId")) \
		or payload["blackUserId"] == payload["whiteUserId"] \
		or payload.get("nextColor") not in ["black", "white"] or not payload.get("status") is String:
		return _failure("invalid_snapshot")
	var black_count: int = payload["board"].count(BLACK)
	var white_count: int = payload["board"].count(WHITE)
	if black_count != 10 or white_count != 10:
		return _failure("invalid_snapshot")
	var move_revision: int = envelope["revision"]
	if payload["status"] in [STATUS_CANCELLED, STATUS_ABANDONED] \
		or payload["status"] == STATUS_FINISHED and payload["result"] == "resignation":
		move_revision -= 1
	if move_revision < 0 or payload["nextColor"] != ("white" if move_revision % 2 == 1 else "black"):
		return _failure("invalid_snapshot")
	var black_complete := _completed_camp(payload["board"], BLACK)
	var white_complete := _completed_camp(payload["board"], WHITE)
	match payload["status"]:
		STATUS_ACTIVE:
			if payload["result"] != null or payload["winnerUserId"] != null or black_complete or white_complete:
				return _failure("invalid_snapshot")
		STATUS_FINISHED:
			if payload["result"] == "goal":
				if payload["winnerUserId"] not in [payload["blackUserId"], payload["whiteUserId"]] \
					or black_complete == white_complete \
					or black_complete != (payload["winnerUserId"] == payload["blackUserId"]):
					return _failure("invalid_snapshot")
			elif payload["result"] == "resignation":
				if envelope["revision"] < 2 or payload["winnerUserId"] not in [payload["blackUserId"], payload["whiteUserId"]] \
					or black_complete or white_complete:
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
	var has_action: bool = message_type in ["chinese_checkers.move.accepted", "chinese_checkers.resigned"]
	var expected := ["actionId", "gameId", "matchId", "payload", "protocolVersion", "revision", "type"] if has_action \
		else ["gameId", "matchId", "payload", "protocolVersion", "revision", "type"]
	return _exact_keys(envelope, expected) and _valid_bound(envelope, message_type) \
		and envelope["payload"] is Dictionary and (not has_action or _canonical_uuid(envelope["actionId"]))


func _valid_bound(envelope: Dictionary, message_type: String) -> bool:
	return envelope.get("protocolVersion") == 1 and envelope.get("gameId") == "chinese_checkers" \
		and envelope.get("matchId") == _match_id and envelope.get("type") == message_type \
		and typeof(envelope.get("revision")) == TYPE_INT and envelope["revision"] >= 0 \
		and not envelope.has("expectedRevision")


static func point_for_index(index: int) -> Vector2i:
	if index < 0 or index >= BOARD_CELLS:
		return Vector2i(-1000, -1000)
	var offset := 0
	for row in ROW_LENGTHS.size():
		if index < offset + ROW_LENGTHS[row]:
			return Vector2i(ROW_STARTS[row] + 2 * (index - offset), row)
		offset += ROW_LENGTHS[row]
	return Vector2i(-1000, -1000)


static func index_for_point(point: Vector2i) -> int:
	if point.y < 0 or point.y >= ROW_LENGTHS.size():
		return -1
	var delta: int = point.x - ROW_STARTS[point.y]
	if delta < 0 or delta % 2 != 0:
		return -1
	var column := int(delta / 2)
	if column < 0 or column >= ROW_LENGTHS[point.y]:
		return -1
	var offset := 0
	for row in point.y:
		offset += ROW_LENGTHS[row]
	return offset + column


static func _valid_endpoint(source: int, destination: int, color: int) -> bool:
	return not _is_neutral_camp(destination) \
		and (not _is_target_camp(source, color) or _is_target_camp(destination, color))


static func _is_target_camp(index: int, color: int) -> bool:
	return color == BLACK and index >= 111 and index < 121 or color == WHITE and index >= 0 and index <= 9


static func _is_neutral_camp(index: int) -> bool:
	var point := point_for_index(index)
	var row := point.y
	if row < 4 or row > 12 or row == 8:
		return false
	var row_offset := 0
	for current in row:
		row_offset += ROW_LENGTHS[current]
	var column := index - row_offset
	var depth := 8 - row if row <= 7 else row - 8
	return column < depth or column >= ROW_LENGTHS[row] - depth


static func _completed_camp(cells: Array, color: int) -> bool:
	var start := 111 if color == BLACK else 0
	for index in range(start, start + 10):
		if cells[index] != color:
			return false
	return color in [BLACK, WHITE]


static func _valid_board(value: Variant) -> bool:
	if not value is Array or value.size() != BOARD_CELLS:
		return false
	for cell in value:
		if typeof(cell) != TYPE_INT or cell < EMPTY or cell > WHITE:
			return false
	return true


func _user_stone(user_id: String) -> int:
	if user_id == black_user_id:
		return BLACK
	if user_id == white_user_id:
		return WHITE
	return EMPTY


static func _color_name(color: int) -> String:
	return "black" if color == BLACK else "white" if color == WHITE else ""


static func _canonical_uuid(value: Variant) -> bool:
	return value is String and RegEx.create_from_string("^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$").search(value) != null


static func _exact_keys(value: Dictionary, expected: Array) -> bool:
	if value.size() != expected.size():
		return false
	for key in value:
		if not key is String or not expected.has(key):
			return false
	return true


static func _failure(code: String) -> Dictionary:
	return {"ok": false, "code": code}
