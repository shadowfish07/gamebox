extends RefCounted

const CHOICES := ["rock", "paper", "scissors"]
const FORMATS := ["single_round", "best_of_three"]
const TERMINAL_STATUSES := ["finished", "cancelled", "abandoned"]

var revision := -1
var status := ""
var format := ""
var round_number := 0
var me_user_id := ""
var opponent_user_id := ""
var me_score := 0
var opponent_score := 0
var me_locked := false
var opponent_locked := false
var me_choice: Variant = null
var last_reveal: Variant = null
var winner_user_id: Variant = null
var result: Variant = null
var pending_action := {}

# MatchClient uses these shared participant slots for membership validation.
var black_user_id: String:
	get: return me_user_id
var white_user_id: String:
	get: return opponent_user_id

var _match_id := ""


func _init(match_id: String) -> void:
	_match_id = match_id


func can_request_choice(choice: String, local_user_id: String) -> bool:
	return revision >= 0 and status == "active" and local_user_id == me_user_id \
		and choice in CHOICES and not me_locked and pending_action.is_empty()


func mark_pending_choice(action_id: String, choice: String, local_user_id: String) -> bool:
	if not can_request_choice(choice, local_user_id) or not _uuid(action_id):
		return false
	pending_action = {
		"action_id": action_id,
		"type": "rps.choice.requested",
		"choice": choice,
		"actor_user_id": local_user_id,
		"expected_revision": revision,
	}
	return true


func can_request_resign(local_user_id: String) -> bool:
	return revision > 0 and status == "active" and pending_action.is_empty() \
		and local_user_id in [me_user_id, opponent_user_id]


func mark_pending_resign(action_id: String, local_user_id: String) -> bool:
	if not can_request_resign(local_user_id) or not _uuid(action_id):
		return false
	pending_action = {
		"action_id": action_id,
		"type": "rps.resign.requested",
		"actor_user_id": local_user_id,
		"expected_revision": revision,
	}
	return true


func clear_pending(action_id: String) -> bool:
	if pending_action.get("action_id", "") != action_id:
		return false
	pending_action.clear()
	return true


func apply_snapshot(envelope: Dictionary) -> Dictionary:
	if not _valid_bound(envelope, "platform.snapshot"):
		return _failure("invalid_snapshot")
	var payload: Variant = envelope.get("payload")
	if not payload is Dictionary or not _exact(payload, [
		"format", "lastReveal", "me", "opponent", "result", "round", "status", "winnerUserId",
	]):
		return _failure("invalid_snapshot")
	if payload["format"] not in FORMATS or typeof(payload["round"]) != TYPE_INT or payload["round"] < 1 \
		or payload["status"] not in ["active", "finished", "cancelled", "abandoned"] \
		or not _valid_player(payload["me"], true) or not _valid_player(payload["opponent"], false):
		return _failure("invalid_snapshot")
	var me: Dictionary = payload["me"]
	var opponent: Dictionary = payload["opponent"]
	if me["userId"] == opponent["userId"] or not _nullable_uuid(payload["winnerUserId"]) \
		or not _nullable_string(payload["result"]) or not _valid_reveal(payload["lastReveal"], me["userId"], opponent["userId"]):
		return _failure("invalid_snapshot")
	if envelope["revision"] < revision:
		return {"ok": true, "status": "ignored"}
	revision = envelope["revision"]
	status = payload["status"]
	format = payload["format"]
	round_number = payload["round"]
	me_user_id = me["userId"]
	opponent_user_id = opponent["userId"]
	me_score = me["score"]
	opponent_score = opponent["score"]
	me_locked = me["locked"]
	opponent_locked = opponent["locked"]
	me_choice = me.get("choice")
	last_reveal = payload["lastReveal"].duplicate(true) if payload["lastReveal"] is Dictionary else null
	winner_user_id = payload["winnerUserId"]
	result = payload["result"]
	pending_action.clear()
	return {"ok": true, "status": "applied"}


func apply_event(envelope: Dictionary) -> Dictionary:
	if not _valid_bound(envelope, envelope.get("type", "")):
		return _failure("invalid_event")
	if envelope["revision"] <= revision:
		return {"ok": true, "status": "ignored"}
	if envelope["revision"] != revision + 1:
		return {"ok": true, "status": "needs_snapshot"}
	if status != "active":
		return _failure("invalid_event")
	var event_type: String = envelope["type"]
	var applied := false
	match event_type:
		"rps.choice.locked":
			applied = _apply_locked(envelope)
		"rps.round.revealed":
			applied = _apply_reveal(envelope)
		"rps.resigned":
			applied = _apply_resigned(envelope)
		"platform.match.cancelled":
			applied = envelope["payload"].is_empty() and revision == 0
			if applied: status = "cancelled"
		"platform.match.abandoned":
			applied = envelope["payload"].is_empty()
			if applied: status = "abandoned"
		_:
			return _failure("invalid_event")
	if not applied:
		return _failure("invalid_event")
	revision = envelope["revision"]
	if envelope.get("actionId", "") == pending_action.get("action_id", ""):
		pending_action.clear()
	if status != "active":
		pending_action.clear()
	return {"ok": true, "status": "applied"}


func apply_error(envelope: Dictionary) -> Dictionary:
	if not _valid_bound(envelope, "platform.error"):
		return _failure("invalid_error")
	var payload: Variant = envelope.get("payload")
	if not payload is Dictionary or not _exact(payload, ["code", "details", "message"]) \
		or not payload["code"] is String or not payload["message"] is String or not payload["details"] is Dictionary:
		return _failure("invalid_error")
	var matching: bool = envelope.get("actionId", "") == pending_action.get("action_id", "")
	if matching:
		pending_action.clear()
	if payload["code"] == "stale_revision":
		return {"ok": true, "status": "needs_snapshot", "code": payload["code"]}
	if envelope["revision"] != revision:
		return _failure("invalid_error")
	return {"ok": true, "status": "handled", "code": payload["code"]}


func _apply_locked(envelope: Dictionary) -> bool:
	var payload: Variant = envelope.get("payload")
	if not payload is Dictionary or not _exact(payload, ["locked", "round", "userId"]) \
		or payload["locked"] != true or payload["round"] != round_number \
		or payload["userId"] not in [me_user_id, opponent_user_id]:
		return false
	if payload["userId"] == me_user_id:
		if me_locked:
			return false
		me_locked = true
		if envelope.get("actionId", "") == pending_action.get("action_id", ""):
			me_choice = pending_action.get("choice")
	else:
		if opponent_locked:
			return false
		opponent_locked = true
	return true


func _apply_reveal(envelope: Dictionary) -> bool:
	var payload: Variant = envelope.get("payload")
	if not _valid_reveal(payload, me_user_id, opponent_user_id) or payload["round"] != round_number:
		return false
	last_reveal = payload.duplicate(true)
	me_score = payload["scores"].get(me_user_id, 0)
	opponent_score = payload["scores"].get(opponent_user_id, 0)
	me_locked = false
	opponent_locked = false
	me_choice = null
	winner_user_id = payload["matchWinnerUserId"]
	result = payload["result"]
	if winner_user_id != null:
		status = "finished"
	else:
		round_number += 1
	return true


func _apply_resigned(envelope: Dictionary) -> bool:
	var payload: Variant = envelope.get("payload")
	if revision <= 0 or not payload is Dictionary or not _exact(payload, ["userId", "winnerUserId"]) \
		or payload["userId"] not in [me_user_id, opponent_user_id] \
		or payload["winnerUserId"] not in [me_user_id, opponent_user_id] \
		or payload["userId"] == payload["winnerUserId"]:
		return false
	status = "finished"
	winner_user_id = payload["winnerUserId"]
	result = "resignation"
	return true


static func _valid_player(value: Variant, allow_choice: bool) -> bool:
	if not value is Dictionary:
		return false
	var keys := ["locked", "score", "userId"]
	if value.has("choice"):
		keys.append("choice")
	if not _exact(value, keys) or not _uuid(value.get("userId")) \
		or typeof(value.get("score")) != TYPE_INT or value["score"] < 0 or value["score"] > 2 \
		or typeof(value.get("locked")) != TYPE_BOOL:
		return false
	return not value.has("choice") or (allow_choice and value["locked"] and value["choice"] in CHOICES)


static func _valid_reveal(value: Variant, me_id: String, opponent_id: String) -> bool:
	if value == null:
		return true
	if not value is Dictionary or not _exact(value, [
		"choices", "draw", "matchWinnerUserId", "result", "round", "roundWinnerUserId", "scores",
	]) or typeof(value["round"]) != TYPE_INT or value["round"] < 1 or typeof(value["draw"]) != TYPE_BOOL \
		or not value["choices"] is Dictionary or not value["scores"] is Dictionary:
		return false
	for user_id in [me_id, opponent_id]:
		if not value["choices"].has(user_id) or value["choices"][user_id] not in CHOICES:
			return false
	for user_id in value["scores"]:
		if user_id not in [me_id, opponent_id] or typeof(value["scores"][user_id]) != TYPE_INT \
			or value["scores"][user_id] < 0 or value["scores"][user_id] > 2:
			return false
	return _nullable_uuid(value["roundWinnerUserId"]) and _nullable_uuid(value["matchWinnerUserId"]) \
		and _nullable_string(value["result"])


func _valid_bound(envelope: Dictionary, message_type: String) -> bool:
	return envelope.get("protocolVersion") == 1 and envelope.get("gameId") == "rps" \
		and envelope.get("matchId") == _match_id and envelope.get("type") == message_type \
		and typeof(envelope.get("revision")) == TYPE_INT and envelope["revision"] >= 0 \
		and envelope.get("payload") is Dictionary


static func _exact(value: Dictionary, keys: Array) -> bool:
	if value.size() != keys.size():
		return false
	for key in value:
		if key not in keys:
			return false
	return true


static func _uuid(value: Variant) -> bool:
	return value is String and RegEx.create_from_string(
		"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
	).search(value) != null


static func _nullable_uuid(value: Variant) -> bool:
	return value == null or _uuid(value)


static func _nullable_string(value: Variant) -> bool:
	return value == null or value is String


static func _failure(code: String) -> Dictionary:
	return {"ok": false, "code": code}
