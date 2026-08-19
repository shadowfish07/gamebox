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
		{"name": "protocol allows semantically omitted match fields", "run": _allows_omitted_match_fields},
		{"name": "protocol requires canonical unique envelope keys", "run": _requires_canonical_unique_keys},
		{"name": "protocol enforces safe JSON integer range", "run": _enforces_safe_integer_range},
		{"name": "protocol action encoding uses canonical camelCase fields", "run": _encodes_action_with_camel_case},
		{"name": "protocol encodes both client action types", "run": _encodes_both_client_actions},
		{"name": "protocol action encoding fails closed", "run": _rejects_invalid_action_encoding},
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


static func _allows_omitted_match_fields() -> bool:
	var valid_messages := [
		'{"protocolVersion":1,"type":"platform.connect","payload":{"launchTicket":"opaque"}}',
		'{"protocolVersion":1,"type":"platform.error","payload":{"code":"ticket_invalid","message":"invalid","details":{}}}',
	]
	for message in valid_messages:
		if not _check(Protocol.decode(message).get("ok", false), "rejected semantically omitted match fields"):
			return false
	return true


static func _requires_canonical_unique_keys() -> bool:
	var action := '{"protocolVersion":1,"gameId":"gomoku","matchId":"%s","expectedRevision":3,"type":"gomoku.move.requested","actionId":"%s","payload":{"x":7,"y":7}}' % [MATCH_ID, ACTION_ID]
	var snapshot := '{"protocolVersion":1,"gameId":"gomoku","matchId":"%s","revision":3,"type":"platform.snapshot","payload":{}}' % MATCH_ID
	var case_variants := {
		"protocolVersion": "ProtocolVersion",
		"gameId": "GameId",
		"matchId": "MatchId",
		"revision": "Revision",
		"expectedRevision": "ExpectedRevision",
		"type": "Type",
		"actionId": "ActionId",
		"payload": "Payload",
	}
	for canonical in case_variants:
		var base: String = snapshot if canonical == "revision" else action
		var changed := base.replace('"%s":' % canonical, '"%s":' % case_variants[canonical])
		if not _check(not Protocol.decode(changed).get("ok", true), "accepted non-canonical key %s" % case_variants[canonical]):
			return false

	var duplicates := [
		action.replace('"protocolVersion":1', '"protocolVersion":2,"protocolVersion":1'),
		action.replace('"gameId":"gomoku"', '"gameId":null,"gameId":"gomoku"'),
		action.replace('"matchId":"%s"' % MATCH_ID, '"matchId":"","matchId":"%s"' % MATCH_ID),
		snapshot.replace('"revision":3', '"revision":-1,"revision":3'),
		action.replace('"expectedRevision":3', '"expectedRevision":-1,"expectedRevision":3'),
		action.replace('"type":"gomoku.move.requested"', '"type":"unknown.message","type":"gomoku.move.requested"'),
		action.replace('"actionId":"%s"' % ACTION_ID, '"actionId":"","actionId":"%s"' % ACTION_ID),
		action.replace('"payload":{"x":7,"y":7}', '"payload":null,"payload":{"x":7,"y":7}'),
	]
	for duplicate in duplicates:
		if not _check(not Protocol.decode(duplicate).get("ok", true), "accepted duplicate top-level key: %s" % duplicate):
			return false

	var invalid := [
		action.left(-1) + ",}",
		action.replace('"gameId":', '"game\\u0049d":'),
		'{"protocolVersion":1,"gameId":"","type":"platform.connect","payload":{}}',
		'{"protocolVersion":1,"gameId":"","matchId":"","type":"platform.error","payload":{}}',
	]
	for message in invalid:
		if not _check(not Protocol.decode(message).get("ok", true), "accepted non-canonical envelope: %s" % message):
			return false

	var key_like_string := JSON.stringify({
		"protocolVersion": 1,
		"gameId": "gomoku",
		"matchId": MATCH_ID,
		"expectedRevision": 3,
		"type": "gomoku.move.requested",
		"actionId": ACTION_ID,
		"payload": {"text": "escaped quote: \" and key text: \"revision\":999, {}[]"},
	})
	return _check(Protocol.decode(key_like_string).get("ok", false), "key-like string content was misclassified")


static func _enforces_safe_integer_range() -> bool:
	var prefix := '{"protocolVersion":1,"gameId":"gomoku","matchId":"%s","expectedRevision":3,"type":"gomoku.move.requested","actionId":"%s","payload":' % [MATCH_ID, ACTION_ID]
	var valid := [
		prefix + '{"minimum":-9007199254740991,"maximum":9007199254740991,"fraction":1.25,"nested":[0,{"fraction":-0.5}]}}',
		prefix + '{"decimalBoundary":9007199254740991.0,"exponentBoundary":90071992547409910e-1}}',
		prefix + '{"largeIntegerAsString":"9007199254740992"}}',
	]
	for message in valid:
		if not _check(Protocol.decode(message).get("ok", false), "rejected safe numeric payload: %s" % message):
			return false

	var invalid := [
		prefix + '{"tooLarge":9007199254740992}}',
		prefix + '{"tooSmall":-9007199254740992}}',
		prefix + '{"nested":[{"tooLarge":9007199254740992}]}}',
		prefix + '{"decimalTooLarge":9007199254740992.0}}',
		prefix + '{"exponentTooLarge":90071992547409920e-1}}',
		prefix + '{"duplicate":9007199254740992,"duplicate":1}}',
		'{"protocolVersion":1,"gameId":"gomoku","matchId":"%s","expectedRevision":9007199254740992,"type":"gomoku.move.requested","actionId":"%s","payload":{}}' % [MATCH_ID, ACTION_ID],
	]
	for message in invalid:
		if not _check(not Protocol.decode(message).get("ok", true), "accepted unsafe JSON integer: %s" % message):
			return false
	return true


static func _encodes_action_with_camel_case() -> bool:
	var result: Dictionary = Protocol.encode_action(
		"gomoku.move.requested",
		MATCH_ID,
		3,
		ACTION_ID,
		{"x": 7, "y": 7, "nullable": null}
	)
	if not _check(result.get("ok", false), "expected valid action to encode: %s" % [result]):
		return false
	var encoded: String = result.get("text", "")
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
		and _check(not encoded.contains("match_id") and not encoded.contains("action_id") and not encoded.contains("expected_revision"), "snake_case leaked into wire JSON") \
		and _check(Protocol.decode(encoded).get("ok", false), "successful encoding must pass strict decode")


static func _encodes_both_client_actions() -> bool:
	for message_type in ["gomoku.move.requested", "gomoku.resign.requested"]:
		var payload := {"x": 7, "y": 7} if message_type == "gomoku.move.requested" else {}
		var result: Dictionary = Protocol.encode_action(message_type, MATCH_ID, 3, ACTION_ID, payload)
		if not _check(result.get("ok", false), "expected %s to encode" % message_type):
			return false
		if not _check(Protocol.decode(result.get("text", "")).get("ok", false), "encoded %s must decode" % message_type):
			return false
	return true


static func _rejects_invalid_action_encoding() -> bool:
	var cyclic: Array = []
	cyclic.append(cyclic)
	var invalid_results := [
		Protocol.encode_action("unknown.message", MATCH_ID, 3, ACTION_ID, {}),
		Protocol.encode_action("gomoku.move.accepted", MATCH_ID, 3, ACTION_ID, {}),
		Protocol.encode_action("gomoku.move.requested", "", 3, ACTION_ID, {}),
		Protocol.encode_action("gomoku.move.requested", MATCH_ID, 3, "", {}),
		Protocol.encode_action("gomoku.move.requested", MATCH_ID, -1, ACTION_ID, {}),
		Protocol.encode_action("gomoku.move.requested", MATCH_ID, 3, ACTION_ID, {"nan": NAN}),
		Protocol.encode_action("gomoku.move.requested", MATCH_ID, 3, ACTION_ID, {"infinity": INF}),
		Protocol.encode_action("gomoku.move.requested", MATCH_ID, 3, ACTION_ID, {"object": RefCounted.new()}),
		Protocol.encode_action("gomoku.move.requested", MATCH_ID, 3, ACTION_ID, {1: "non-string key"}),
		Protocol.encode_action("gomoku.move.requested", MATCH_ID, 3, ACTION_ID, {"cycle": cyclic}),
		Protocol.encode_action("gomoku.move.requested", MATCH_ID, 3, ACTION_ID, {"tooLarge": 9007199254740992}),
	]
	for result in invalid_results:
		if not _check(result is Dictionary and not result.get("ok", true), "invalid action encoding did not fail closed"):
			return false
	return true


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
