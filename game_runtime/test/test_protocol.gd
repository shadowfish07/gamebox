extends RefCounted

const Protocol = preload("res://core/protocol.gd")

const MATCH_ID := "11111111-1111-4111-8111-111111111111"
const ACTION_ID := "33333333-3333-4333-8333-333333333333"


static func cases() -> Array:
	return [
		{"name": "protocol decodes the four shared fixtures", "run": _decodes_shared_fixtures},
		{"name": "protocol preserves snapshot integers and nulls", "run": _preserves_snapshot_values},
		{"name": "protocol rejects malformed and unknown envelope fields", "run": _rejects_malformed_envelopes},
		{"name": "protocol enforces revision and action requirements", "run": _enforces_message_field_combinations},
		{"name": "protocol action encoding uses canonical camelCase fields", "run": _encodes_action_with_camel_case},
	]


static func _decodes_shared_fixtures() -> bool:
	var expected_types := {
		"snapshot.json": "platform.snapshot",
		"move_action.json": "gomoku.move.requested",
		"move_accepted.json": "gomoku.move.accepted",
		"error.json": "platform.error",
	}
	for filename in expected_types:
		var result: Dictionary = Protocol.decode(_read_fixture(filename))
		if not _check(result.get("ok", false), "expected %s to decode: %s" % [filename, result]):
			return false
		var envelope: Dictionary = result.get("envelope", {})
		if not _check(envelope.get("protocolVersion") == 1, "expected protocolVersion in %s" % filename):
			return false
		if not _check(envelope.get("type") == expected_types[filename], "unexpected type in %s" % filename):
			return false
		if envelope.has("revision") and envelope.has("expectedRevision"):
			return _check(false, "revision fields overlap in %s" % filename)
	return true


static func _preserves_snapshot_values() -> bool:
	var result: Dictionary = Protocol.decode(_read_fixture("snapshot.json"))
	if not _check(result.get("ok", false), "expected snapshot to decode: %s" % [result]):
		return false
	var payload: Dictionary = result["envelope"]["payload"]
	var board: Array = payload.get("board", [])
	if not _check(board.size() == 225, "expected exactly 225 cells"):
		return false
	for index in board.size():
		if not _check(typeof(board[index]) == TYPE_INT and board[index] == 0, "expected integer zero at board[%d]" % index):
			return false
	return _check(typeof(payload.get("boardSize")) == TYPE_INT and payload.get("boardSize") == 15, "expected integer boardSize") \
		and _check(payload.has("winnerUserId") and payload["winnerUserId"] == null, "expected explicit null winnerUserId") \
		and _check(payload.has("result") and payload["result"] == null, "expected explicit null result")


static func _rejects_malformed_envelopes() -> bool:
	var invalid_messages := [
		"not-json",
		"[]",
		'{"protocolVersion":2,"type":"platform.connect","payload":{}}',
		'{"protocolVersion":1,"payload":{}}',
		'{"protocolVersion":1,"type":"platform.connect"}',
		'{"protocolVersion":1,"type":"platform.connect","payload":null}',
		'{"protocolVersion":1,"type":"unknown.message","payload":{}}',
		'{"protocolVersion":1,"type":"platform.connect","payload":{},"unexpected":true}',
		'{"protocolVersion":1,"gameId":"gomoku","matchId":"%s","type":"platform.ping","payload":{"nonce":"n1"}}' % MATCH_ID,
	]
	for message in invalid_messages:
		if not _check(not Protocol.decode(message).get("ok", true), "expected invalid envelope to fail: %s" % message):
			return false
	return true


static func _enforces_message_field_combinations() -> bool:
	var valid_action := '{"protocolVersion":1,"gameId":"gomoku","matchId":"%s","expectedRevision":3,"type":"gomoku.move.requested","actionId":"%s","payload":{"x":7,"y":7}}' % [MATCH_ID, ACTION_ID]
	var invalid_messages := [
		valid_action.replace('"expectedRevision":3', '"revision":3,"expectedRevision":3'),
		valid_action.replace(',"expectedRevision":3', ""),
		valid_action.replace(',"actionId":"%s"' % ACTION_ID, ""),
		'{"protocolVersion":1,"gameId":"gomoku","matchId":"%s","type":"platform.snapshot","payload":{}}' % MATCH_ID,
		'{"protocolVersion":1,"gameId":"gomoku","matchId":"%s","revision":3,"expectedRevision":3,"type":"platform.snapshot","payload":{}}' % MATCH_ID,
	]
	for message in invalid_messages:
		if not _check(not Protocol.decode(message).get("ok", true), "expected field combination to fail: %s" % message):
			return false
	return true


static func _encodes_action_with_camel_case() -> bool:
	var encoded: String = Protocol.encode_action(
		"gomoku.move.requested",
		MATCH_ID,
		3,
		ACTION_ID,
		{"x": 7, "y": 7, "nullable": null}
	)
	var parsed = JSON.parse_string(encoded)
	if not _check(parsed is Dictionary, "expected encoded action JSON object"):
		return false
	var envelope: Dictionary = parsed
	var keys := envelope.keys()
	keys.sort()
	var expected_keys := ["actionId", "expectedRevision", "gameId", "matchId", "payload", "protocolVersion", "type"]
	expected_keys.sort()
	return _check(keys == expected_keys, "unexpected action envelope keys: %s" % [keys]) \
		and _check(envelope.get("protocolVersion") == 1, "expected version one") \
		and _check(envelope.get("gameId") == "gomoku", "expected gomoku gameId") \
		and _check(envelope.get("matchId") == MATCH_ID, "expected camelCase matchId") \
		and _check(envelope.get("expectedRevision") == 3, "expected camelCase expectedRevision") \
		and _check(envelope.get("actionId") == ACTION_ID, "expected camelCase actionId") \
		and _check(envelope["payload"].has("nullable") and envelope["payload"]["nullable"] == null, "expected payload null to survive") \
		and _check(not encoded.contains("match_id") and not encoded.contains("action_id") and not encoded.contains("expected_revision"), "snake_case leaked into wire JSON")


static func _read_fixture(filename: String) -> String:
	var project_root := ProjectSettings.globalize_path("res://")
	var path := project_root.path_join("../protocol/fixtures").path_join(filename)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("unable to read shared fixture %s" % path)
		return ""
	return file.get_as_text()


static func _check(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition
