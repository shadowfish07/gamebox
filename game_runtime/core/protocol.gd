extends RefCounted

const VERSION := 1
const MAX_SAFE_JSON_INTEGER := 9007199254740991
const MAX_MESSAGE_BYTES := 64 * 1024
const MAX_JSON_DEPTH := 32
const MAX_NUMBER_TOKEN_BYTES := 128
const _SCANNED_STRING_PREFIX := "gbox-json-v1:"

const TYPE_PLATFORM_CONNECT := "platform.connect"
const TYPE_PLATFORM_CONNECTED := "platform.connected"
const TYPE_PLATFORM_PING := "platform.ping"
const TYPE_PLATFORM_PONG := "platform.pong"
const TYPE_PLATFORM_PRESENCE_CHANGED := "platform.presence.changed"
const TYPE_PLATFORM_SNAPSHOT := "platform.snapshot"
const TYPE_PLATFORM_SNAPSHOT_REQUESTED := "platform.snapshot.requested"
const TYPE_PLATFORM_ERROR := "platform.error"
const TYPE_PLATFORM_MATCH_CANCELLED := "platform.match.cancelled"
const TYPE_PLATFORM_MATCH_ABANDONED := "platform.match.abandoned"
const TYPE_CHINESE_CHECKERS_MOVE_REQUESTED := "chinese_checkers.move.requested"
const TYPE_CHINESE_CHECKERS_MOVE_ACCEPTED := "chinese_checkers.move.accepted"
const TYPE_CHINESE_CHECKERS_RESIGN_REQUESTED := "chinese_checkers.resign.requested"
const TYPE_CHINESE_CHECKERS_RESIGNED := "chinese_checkers.resigned"
const TYPE_FLIGHT_CHESS_ROLL_REQUESTED := "flight_chess.roll.requested"
const TYPE_FLIGHT_CHESS_ROLL_ACCEPTED := "flight_chess.roll.accepted"
const TYPE_FLIGHT_CHESS_MOVE_REQUESTED := "flight_chess.move.requested"
const TYPE_FLIGHT_CHESS_MOVE_ACCEPTED := "flight_chess.move.accepted"
const TYPE_FLIGHT_CHESS_RESIGN_REQUESTED := "flight_chess.resign.requested"
const TYPE_FLIGHT_CHESS_RESIGNED := "flight_chess.resigned"
const TYPE_GOMOKU_MOVE_REQUESTED := "gomoku.move.requested"
const TYPE_GOMOKU_MOVE_ACCEPTED := "gomoku.move.accepted"
const TYPE_GOMOKU_RESIGN_REQUESTED := "gomoku.resign.requested"
const TYPE_GOMOKU_RESIGNED := "gomoku.resigned"
const TYPE_RPS_CHOICE_REQUESTED := "rps.choice.requested"
const TYPE_RPS_CHOICE_LOCKED := "rps.choice.locked"
const TYPE_RPS_ROUND_REVEALED := "rps.round.revealed"
const TYPE_RPS_RESIGN_REQUESTED := "rps.resign.requested"
const TYPE_RPS_RESIGNED := "rps.resigned"
const CAPABILITY_PLAYER_PRESENCE := "player_presence_v1"

const _ALLOWED_FIELDS := {
	"protocolVersion": true,
	"gameId": true,
	"matchId": true,
	"revision": true,
	"expectedRevision": true,
	"type": true,
	"actionId": true,
	"payload": true,
}

const _KNOWN_TYPES := {
	TYPE_PLATFORM_CONNECT: true,
	TYPE_PLATFORM_CONNECTED: true,
	TYPE_PLATFORM_PING: true,
	TYPE_PLATFORM_PONG: true,
	TYPE_PLATFORM_PRESENCE_CHANGED: true,
	TYPE_PLATFORM_SNAPSHOT: true,
	TYPE_PLATFORM_SNAPSHOT_REQUESTED: true,
	TYPE_PLATFORM_ERROR: true,
	TYPE_PLATFORM_MATCH_CANCELLED: true,
	TYPE_PLATFORM_MATCH_ABANDONED: true,
	TYPE_CHINESE_CHECKERS_MOVE_REQUESTED: true,
	TYPE_CHINESE_CHECKERS_MOVE_ACCEPTED: true,
	TYPE_CHINESE_CHECKERS_RESIGN_REQUESTED: true,
	TYPE_CHINESE_CHECKERS_RESIGNED: true,
	TYPE_FLIGHT_CHESS_ROLL_REQUESTED: true,
	TYPE_FLIGHT_CHESS_ROLL_ACCEPTED: true,
	TYPE_FLIGHT_CHESS_MOVE_REQUESTED: true,
	TYPE_FLIGHT_CHESS_MOVE_ACCEPTED: true,
	TYPE_FLIGHT_CHESS_RESIGN_REQUESTED: true,
	TYPE_FLIGHT_CHESS_RESIGNED: true,
	TYPE_GOMOKU_MOVE_REQUESTED: true,
	TYPE_GOMOKU_MOVE_ACCEPTED: true,
	TYPE_GOMOKU_RESIGN_REQUESTED: true,
	TYPE_GOMOKU_RESIGNED: true,
	TYPE_RPS_CHOICE_REQUESTED: true,
	TYPE_RPS_CHOICE_LOCKED: true,
	TYPE_RPS_ROUND_REVEALED: true,
	TYPE_RPS_RESIGN_REQUESTED: true,
	TYPE_RPS_RESIGNED: true,
}


static func decode(text: String) -> Dictionary:
	if text.length() > MAX_MESSAGE_BYTES or text.to_utf8_buffer().size() > MAX_MESSAGE_BYTES:
		return _failure("message_too_large", "Message exceeds the size limit")
	var strict_scan := _StrictJSONScanner.new(
		text,
		_ALLOWED_FIELDS,
		MAX_JSON_DEPTH,
		MAX_NUMBER_TOKEN_BYTES
	).scan()
	if not strict_scan.get("ok", false):
		return strict_scan
	var parser := JSON.new()
	if parser.parse(strict_scan.get("sanitized_text", text)) != OK:
		return _failure("invalid_json", "Message is not valid JSON")
	var restored := _restore_scanned_strings(parser.data)
	if not restored.get("ok", false):
		return _failure("invalid_json", "Message is not valid JSON")
	if not restored["value"] is Dictionary:
		return _failure("invalid_envelope", "Message must be a JSON object")

	var envelope: Dictionary = _normalize_json_numbers(restored["value"])
	return _validate_envelope(envelope)


static func _validate_envelope(envelope: Dictionary) -> Dictionary:
	for field in envelope:
		if not _ALLOWED_FIELDS.has(field):
			return _failure("invalid_envelope", "Message contains an unknown envelope field")
	if not envelope.has("protocolVersion") or typeof(envelope["protocolVersion"]) != TYPE_INT:
		return _failure("invalid_version", "protocolVersion must be an integer")
	if envelope["protocolVersion"] != VERSION:
		return _failure("unsupported_version", "Only protocol version 1 is supported")
	if not envelope.has("type") or not envelope["type"] is String or envelope["type"].is_empty():
		return _failure("invalid_type", "type is required")
	var message_type: String = envelope["type"]
	if not _KNOWN_TYPES.has(message_type):
		return _failure("invalid_type", "Message type is not supported")
	if not envelope.has("payload") or not envelope["payload"] is Dictionary:
		return _failure("invalid_payload", "payload must be a JSON object")

	if not _validate_optional_string(envelope, "gameId") \
		or not _validate_optional_string(envelope, "matchId") \
		or not _validate_optional_string(envelope, "actionId"):
		return _failure("invalid_envelope", "Envelope identifiers must be non-empty strings")
	if not _validate_optional_revision(envelope, "revision") \
		or not _validate_optional_revision(envelope, "expectedRevision"):
		return _failure("invalid_revision", "Revision fields must be non-negative integers")
	if envelope.has("revision") and envelope.has("expectedRevision"):
		return _failure("invalid_revision", "revision and expectedRevision are mutually exclusive")

	var has_game := envelope.has("gameId")
	var has_match := envelope.has("matchId")
	if has_game != has_match:
		return _failure("invalid_envelope", "gameId and matchId must appear together")
	if message_type == TYPE_PLATFORM_CONNECT:
		if has_game:
			return _failure("invalid_envelope", "platform.connect is not match-bound")
	elif message_type == TYPE_PLATFORM_ERROR and not has_game:
		pass
	elif not has_game:
		return _failure("invalid_envelope", "Match-bound message requires gameId and matchId")

	if _is_client_action(message_type):
		if not envelope.has("actionId"):
			return _failure("invalid_action", "Client action requires actionId")
		if not envelope.has("expectedRevision"):
			return _failure("invalid_action", "Client action requires expectedRevision")
		if envelope.has("revision"):
			return _failure("invalid_action", "Client action must not contain revision")
	elif _is_revisionless_control(message_type):
		if envelope.has("revision") or envelope.has("expectedRevision") or envelope.has("actionId"):
			return _failure("invalid_envelope", "Control message contains match action fields")
	elif message_type == TYPE_PLATFORM_ERROR and not has_game:
		if envelope.has("revision") or envelope.has("expectedRevision") or envelope.has("actionId"):
			return _failure("invalid_envelope", "Unbound error contains match action fields")
	else:
		if not envelope.has("revision"):
			return _failure("invalid_revision", "Bound server message requires revision")
		if envelope.has("expectedRevision"):
			return _failure("invalid_revision", "Server message must not contain expectedRevision")

	return {"ok": true, "envelope": envelope}


static func encode_action(
	message_type: String,
	match_id: String,
	revision: int,
	action_id: String,
	payload: Variant,
	game_id: String = "gomoku"
) -> Dictionary:
	if not payload is Dictionary:
		return _failure("invalid_payload", "payload must be a JSON object")
	if not _is_canonical_uuid(match_id) or not _is_canonical_uuid(action_id):
		return _failure("invalid_action", "Action identifiers are invalid")
	var envelope := {
		"protocolVersion": VERSION,
		"gameId": game_id,
		"matchId": match_id,
		"expectedRevision": revision,
		"type": message_type,
		"actionId": action_id,
		"payload": payload,
	}
	var validation := _validate_envelope(envelope)
	if not validation.get("ok", false):
		return validation
	return _encode_envelope(envelope)


static func encode_connect(credential_name: String, credential: String) -> Dictionary:
	if credential_name not in ["launchTicket", "resumeToken"] or credential.is_empty() \
		or credential.length() > 256 or credential.to_utf8_buffer().size() > 256:
		return _failure("invalid_connect", "Connection credential is invalid")
	return _encode_envelope({
		"protocolVersion": VERSION,
		"type": TYPE_PLATFORM_CONNECT,
		"payload": {
			credential_name: credential,
			"capabilities": [CAPABILITY_PLAYER_PRESENCE],
		},
	})


static func encode_pong(match_id: String, nonce: String, game_id: String = "gomoku") -> Dictionary:
	if not _is_canonical_uuid(match_id) or not _is_canonical_uuid(nonce):
		return _failure("invalid_control", "Control message is invalid")
	return _encode_envelope({
		"protocolVersion": VERSION,
		"gameId": game_id,
		"matchId": match_id,
		"type": TYPE_PLATFORM_PONG,
		"payload": {"nonce": nonce},
	})


static func encode_snapshot_request(match_id: String, current_revision: int, game_id: String = "gomoku") -> Dictionary:
	if not _is_canonical_uuid(match_id) or current_revision < 0:
		return _failure("invalid_control", "Control message is invalid")
	return _encode_envelope({
		"protocolVersion": VERSION,
		"gameId": game_id,
		"matchId": match_id,
		"type": TYPE_PLATFORM_SNAPSHOT_REQUESTED,
		"payload": {"currentRevision": current_revision},
	})


static func _encode_envelope(envelope: Dictionary) -> Dictionary:
	var validation := _validate_envelope(envelope)
	if not validation.get("ok", false):
		return validation
	var preflight := _preflight_json(envelope, [], 1, MAX_MESSAGE_BYTES)
	if not preflight.get("ok", false):
		return preflight
	var text := JSON.stringify(envelope, "", true, true)
	if text.length() > MAX_MESSAGE_BYTES or text.to_utf8_buffer().size() > MAX_MESSAGE_BYTES:
		return _failure("message_too_large", "Message exceeds the size limit")
	var verification := decode(text)
	if not verification.get("ok", false):
		return _failure("encoding_failed", "Encoded action did not satisfy the protocol contract")
	return {"ok": true, "text": text}


static func _preflight_json(value: Variant, ancestors: Array, depth: int, remaining: int) -> Dictionary:
	match typeof(value):
		TYPE_NIL:
			return _consume_json_budget(remaining, 4)
		TYPE_BOOL:
			return _consume_json_budget(remaining, 4 if value else 5)
		TYPE_STRING:
			return _preflight_json_string(value, remaining)
		TYPE_INT:
			if value < -MAX_SAFE_JSON_INTEGER or value > MAX_SAFE_JSON_INTEGER:
				return _invalid_json_payload()
			return _consume_json_budget(remaining, str(value).length())
		TYPE_FLOAT:
			if not is_finite(value):
				return _invalid_json_payload()
			if value == floor(value) and (value < -MAX_SAFE_JSON_INTEGER or value > MAX_SAFE_JSON_INTEGER):
				return _invalid_json_payload()
			var encoded_number := JSON.stringify(value, "", true, true)
			return _consume_json_budget(remaining, encoded_number.length())
		TYPE_ARRAY, TYPE_DICTIONARY:
			if depth > MAX_JSON_DEPTH:
				return _invalid_json_payload()
			for ancestor in ancestors:
				if is_same(ancestor, value):
					return _invalid_json_payload()

			var item_count: int = value.size()
			var minimum_bytes := 2
			if item_count > 0:
				minimum_bytes = (2 * item_count + 1) if value is Array else (5 * item_count + 1)
			if minimum_bytes > remaining:
				return _message_too_large()

			var nested_ancestors := ancestors.duplicate()
			nested_ancestors.append(value)
			var budget_result := _consume_json_budget(remaining, 1)
			if not budget_result.get("ok", false):
				return budget_result
			var remaining_bytes: int = budget_result["remaining"]
			var first := true
			if value is Array:
				for item in value:
					if not first:
						budget_result = _consume_json_budget(remaining_bytes, 1)
						if not budget_result.get("ok", false):
							return budget_result
						remaining_bytes = budget_result["remaining"]
					first = false
					budget_result = _preflight_json(item, nested_ancestors, depth + 1, remaining_bytes)
					if not budget_result.get("ok", false):
						return budget_result
					remaining_bytes = budget_result["remaining"]
			else:
				for key in value:
					if not first:
						budget_result = _consume_json_budget(remaining_bytes, 1)
						if not budget_result.get("ok", false):
							return budget_result
						remaining_bytes = budget_result["remaining"]
					first = false
					if not key is String:
						return _invalid_json_payload()
					budget_result = _preflight_json_string(key, remaining_bytes)
					if not budget_result.get("ok", false):
						return budget_result
					remaining_bytes = budget_result["remaining"]
					budget_result = _consume_json_budget(remaining_bytes, 1)
					if not budget_result.get("ok", false):
						return budget_result
					remaining_bytes = budget_result["remaining"]
					budget_result = _preflight_json(value[key], nested_ancestors, depth + 1, remaining_bytes)
					if not budget_result.get("ok", false):
						return budget_result
					remaining_bytes = budget_result["remaining"]
			return _consume_json_budget(remaining_bytes, 1)
		_:
			return _invalid_json_payload()


static func _preflight_json_string(value: String, remaining: int) -> Dictionary:
	# Every character needs at least one byte, plus the two JSON quotes. This
	# O(1) lower bound rejects giant strings before any UTF-8 conversion.
	if value.length() + 2 > remaining:
		return _message_too_large()
	var remaining_bytes := remaining - 2
	for character in value:
		var codepoint := character.unicode_at(0)
		var byte_count := 1
		if character == '"' or character == "\\" or character in ["\b", "\f", "\n", "\r", "\t"]:
			byte_count = 2
		elif codepoint < 0x20:
			byte_count = 6
		elif codepoint <= 0x7f:
			byte_count = 1
		elif codepoint <= 0x7ff:
			byte_count = 2
		elif codepoint <= 0xffff:
			byte_count = 3
		else:
			byte_count = 4
		if byte_count > remaining_bytes:
			return _message_too_large()
		remaining_bytes -= byte_count
	return {"ok": true, "remaining": remaining_bytes}


static func _consume_json_budget(remaining: int, byte_count: int) -> Dictionary:
	if byte_count > remaining:
		return _message_too_large()
	return {"ok": true, "remaining": remaining - byte_count}


static func _message_too_large() -> Dictionary:
	return _failure("message_too_large", "Message exceeds the size limit")


static func _invalid_json_payload() -> Dictionary:
	return _failure("invalid_payload", "payload contains a value that cannot be represented safely in JSON")


static func _validate_optional_string(envelope: Dictionary, field: String) -> bool:
	return not envelope.has(field) or (envelope[field] is String and not envelope[field].is_empty())


static func _validate_optional_revision(envelope: Dictionary, field: String) -> bool:
	return not envelope.has(field) or (typeof(envelope[field]) == TYPE_INT and envelope[field] >= 0)


static func _normalize_json_numbers(value: Variant) -> Variant:
	# Godot's JSON parser represents every number as a float. Convert whole
	# values back to integers so shared fixtures retain the wire-level integer
	# semantics used by Go, while fractional payload values remain floats.
	if value is float and is_finite(value) and value == floor(value):
		return int(value)
	if value is Array:
		var normalized_array: Array = value
		for index in normalized_array.size():
			normalized_array[index] = _normalize_json_numbers(normalized_array[index])
		return normalized_array
	if value is Dictionary:
		var normalized_dictionary: Dictionary = value
		for key in normalized_dictionary:
			normalized_dictionary[key] = _normalize_json_numbers(normalized_dictionary[key])
		return normalized_dictionary
	return value


static func _restore_scanned_strings(value: Variant) -> Dictionary:
	if value is String:
		if not value.begins_with(_SCANNED_STRING_PREFIX):
			return {"ok": false}
		var encoded: String = (value as String).substr(_SCANNED_STRING_PREFIX.length())
		if encoded.length() < 2 or encoded[1] != ":":
			return {"ok": false}
		var kind := encoded[0]
		var payload := encoded.substr(2)
		if kind == "b":
			if payload.length() % 2 != 0:
				return {"ok": false}
			# Godot String rejects U+0000 at construction time. Preserve a valid
			# JSON string containing NUL as its exact UTF-8 bytes instead of
			# silently replacing data or emitting an engine diagnostic.
			var decoded_bytes := PackedByteArray()
			for offset in range(0, payload.length(), 2):
				decoded_bytes.append(("0x" + payload.substr(offset, 2)).hex_to_int())
			return {"ok": true, "value": decoded_bytes}
		if kind != "s" or payload.length() % 6 != 0:
			return {"ok": false}
		var decoded_parts := PackedStringArray()
		for offset in range(0, payload.length(), 6):
			var codepoint := ("0x" + payload.substr(offset, 6)).hex_to_int()
			if codepoint <= 0 or codepoint > 0x10ffff:
				return {"ok": false}
			decoded_parts.append(String.chr(codepoint))
		return {"ok": true, "value": "".join(decoded_parts)}
	if value is Array:
		var restored_array: Array = []
		restored_array.resize(value.size())
		for index in value.size():
			var restored_item := _restore_scanned_strings(value[index])
			if not restored_item.get("ok", false):
				return {"ok": false}
			restored_array[index] = restored_item["value"]
		return {"ok": true, "value": restored_array}
	if value is Dictionary:
		var restored_dictionary := {}
		for key in value:
			var restored_key := _restore_scanned_strings(key)
			var restored_value := _restore_scanned_strings(value[key])
			if not restored_key.get("ok", false) or not restored_key["value"] is String \
				or not restored_value.get("ok", false) or restored_dictionary.has(restored_key["value"]):
				return {"ok": false}
			restored_dictionary[restored_key["value"]] = restored_value["value"]
		return {"ok": true, "value": restored_dictionary}
	return {"ok": true, "value": value}


static func _is_client_action(message_type: String) -> bool:
	return message_type in [
		TYPE_CHINESE_CHECKERS_MOVE_REQUESTED,
		TYPE_CHINESE_CHECKERS_RESIGN_REQUESTED,
		TYPE_FLIGHT_CHESS_ROLL_REQUESTED,
		TYPE_FLIGHT_CHESS_MOVE_REQUESTED,
		TYPE_FLIGHT_CHESS_RESIGN_REQUESTED,
		TYPE_GOMOKU_MOVE_REQUESTED,
		TYPE_GOMOKU_RESIGN_REQUESTED,
		TYPE_RPS_CHOICE_REQUESTED,
		TYPE_RPS_RESIGN_REQUESTED,
	]


static func _is_revisionless_control(message_type: String) -> bool:
	return message_type in [
		TYPE_PLATFORM_CONNECT,
		TYPE_PLATFORM_PONG,
		TYPE_PLATFORM_SNAPSHOT_REQUESTED,
	]


static func _is_canonical_uuid(value: String) -> bool:
	var pattern := RegEx.create_from_string("^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
	return pattern.search(value) != null


static func _failure(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "message": message}


class _StrictJSONScanner:
	var _text: String
	var _allowed_top_level_keys: Dictionary
	var _max_depth: int
	var _max_number_token_bytes: int
	var _position := 0
	var _depth := 0
	var _top_level_keys := {}
	var _string_replacements: Array = []
	var _error := ""
	var _error_code := "invalid_json"


	func _init(
		text: String,
		allowed_top_level_keys: Dictionary,
		max_depth: int,
		max_number_token_bytes: int
	) -> void:
		_text = text
		_allowed_top_level_keys = allowed_top_level_keys
		_max_depth = max_depth
		_max_number_token_bytes = max_number_token_bytes


	func scan() -> Dictionary:
		_skip_whitespace()
		if not _parse_object(true):
			return {"ok": false, "code": _error_code, "message": _error}
		_skip_whitespace()
		if _position != _text.length():
			return {"ok": false, "code": "invalid_json", "message": "Message contains trailing data"}
		return {"ok": true, "sanitized_text": _materialize_sanitized_text()}


	func _parse_value() -> bool:
		_skip_whitespace()
		if _at_end():
			return _fail("Expected a JSON value")
		var character := _character()
		if character == "{":
			return _parse_object(false)
		if character == "[":
			return _parse_array()
		if character == '"':
			return _parse_string().get("ok", false)
		if character == "t":
			return _consume_literal("true")
		if character == "f":
			return _consume_literal("false")
		if character == "n":
			return _consume_literal("null")
		if character == "-" or _is_digit(character):
			return _parse_number()
		return _fail("Unexpected character in JSON value")


	func _parse_object(top_level: bool) -> bool:
		if not _consume("{"):
			return _fail("Expected JSON object")
		_depth += 1
		if _depth > _max_depth:
			return _fail("JSON exceeds the nesting limit", "json_too_deep")
		_skip_whitespace()
		if _consume("}"):
			_depth -= 1
			return true
		var object_keys := {}
		while true:
			if _at_end() or _character() != '"':
				return _fail("Expected a JSON object key")
			var key_result := _parse_string()
			if not key_result.get("ok", false):
				return false
			var key_value: Variant = key_result["value"]
			if not key_value is String:
				return _fail("Message object is invalid", "invalid_envelope")
			var key: String = key_value
			# Every object is required to use literal, unique keys. This mirrors
			# Go's strict payload decoder and prevents nested duplicate-key
			# smuggling before a typed message boundary sees the Dictionary.
			if key_result.get("raw", "") != key or object_keys.has(key):
				return _fail("Message object is invalid", "invalid_envelope")
			object_keys[key] = true
			if top_level:
				if not _allowed_top_level_keys.has(key):
					return _fail("Message envelope is invalid", "invalid_envelope")
				if _top_level_keys.has(key):
					return _fail("Message envelope is invalid", "invalid_envelope")
				_top_level_keys[key] = true
			_skip_whitespace()
			if not _consume(":"):
				return _fail("Expected colon after JSON object key")
			if not _parse_value():
				return false
			_skip_whitespace()
			if _consume("}"):
				_depth -= 1
				return true
			if not _consume(","):
				return _fail("Expected comma or closing brace in JSON object")
			_skip_whitespace()
			if not _at_end() and _character() == "}":
				return _fail("Trailing commas are not valid JSON")
		return _fail("Unterminated JSON object")


	func _parse_array() -> bool:
		if not _consume("["):
			return _fail("Expected JSON array")
		_depth += 1
		if _depth > _max_depth:
			return _fail("JSON exceeds the nesting limit", "json_too_deep")
		_skip_whitespace()
		if _consume("]"):
			_depth -= 1
			return true
		while true:
			if not _parse_value():
				return false
			_skip_whitespace()
			if _consume("]"):
				_depth -= 1
				return true
			if not _consume(","):
				return _fail("Expected comma or closing bracket in JSON array")
			_skip_whitespace()
			if not _at_end() and _character() == "]":
				return _fail("Trailing commas are not valid JSON")
		return _fail("Unterminated JSON array")


	func _parse_string() -> Dictionary:
		if not _consume('"'):
			_fail("Expected JSON string")
			return {"ok": false}
		var content_start := _position
		while not _at_end():
			var character := _character()
			if character == '"':
				var raw := _text.substr(content_start, _position - content_start)
				var token_start := content_start - 1
				var token_end := _position + 1
				_position += 1
				var decoded_result := _decode_json_string(raw)
				if not decoded_result.get("ok", false):
					_fail("Invalid JSON string")
					return {"ok": false}
				var decoded: Variant = decoded_result["value"]
				var safe_token := _encode_safe_json_string(decoded, decoded_result["encoded"])
				_string_replacements.append({"start": token_start, "end": token_end, "text": safe_token})
				return {"ok": true, "value": decoded, "raw": raw}
			if character == "\\":
				_position += 1
				if _at_end():
					_fail("Unterminated JSON escape")
					return {"ok": false}
				var escape := _character()
				if escape == "u":
					for _index in 4:
						_position += 1
						if _at_end() or not _is_hex_digit(_character()):
							_fail("Invalid JSON unicode escape")
							return {"ok": false}
				elif not escape in ['"', "\\", "/", "b", "f", "n", "r", "t"]:
					_fail("Invalid JSON escape")
					return {"ok": false}
			elif character.unicode_at(0) < 0x20:
				_fail("Unescaped control character in JSON string")
				return {"ok": false}
			_position += 1
		_fail("Unterminated JSON string")
		return {"ok": false}


	func _decode_json_string(raw: String) -> Dictionary:
		var codepoints: Array[int] = []
		var index := 0
		while index < raw.length():
			var character := raw[index]
			if character != "\\":
				var raw_codepoint := character.unicode_at(0)
				if raw_codepoint < 0x20:
					return {"ok": false}
				codepoints.append(raw_codepoint)
				index += 1
				continue
			if index + 1 >= raw.length():
				return {"ok": false}
			var escape := raw[index + 1]
			match escape:
				'"', "\\", "/":
					codepoints.append(escape.unicode_at(0))
					index += 2
				"b":
					codepoints.append(8)
					index += 2
				"f":
					codepoints.append(12)
					index += 2
				"n":
					codepoints.append(10)
					index += 2
				"r":
					codepoints.append(13)
					index += 2
				"t":
					codepoints.append(9)
					index += 2
				"u":
					if index + 6 > raw.length():
						return {"ok": false}
					var code_unit := _decode_hex_code_unit(raw.substr(index + 2, 4))
					if code_unit < 0:
						return {"ok": false}
					if code_unit >= 0xd800 and code_unit <= 0xdbff:
						var next_escape := index + 6
						if next_escape + 6 <= raw.length() and raw.substr(next_escape, 2) == "\\u":
							var low := _decode_hex_code_unit(raw.substr(next_escape + 2, 4))
							if low >= 0xdc00 and low <= 0xdfff:
								var codepoint := 0x10000 + ((code_unit - 0xd800) << 10) + (low - 0xdc00)
								codepoints.append(codepoint)
								index += 12
								continue
						codepoints.append(0xfffd)
					elif code_unit >= 0xdc00 and code_unit <= 0xdfff:
						codepoints.append(0xfffd)
					else:
						codepoints.append(code_unit)
					index += 6
				_:
					return {"ok": false}
		return _materialize_codepoints(codepoints)


	func _materialize_codepoints(codepoints: Array[int]) -> Dictionary:
		var encoded_parts := PackedStringArray()
		var text_parts := PackedStringArray()
		var has_nul := false
		for codepoint in codepoints:
			encoded_parts.append("%06x" % codepoint)
			has_nul = has_nul or codepoint == 0
			if codepoint != 0:
				text_parts.append(String.chr(codepoint))
		if not has_nul:
			return {"ok": true, "value": "".join(text_parts), "encoded": "".join(encoded_parts)}
		var utf8_bytes := PackedByteArray()
		for codepoint in codepoints:
			if codepoint <= 0x7f:
				utf8_bytes.append(codepoint)
			elif codepoint <= 0x7ff:
				utf8_bytes.append(0xc0 | (codepoint >> 6))
				utf8_bytes.append(0x80 | (codepoint & 0x3f))
			elif codepoint <= 0xffff:
				utf8_bytes.append(0xe0 | (codepoint >> 12))
				utf8_bytes.append(0x80 | ((codepoint >> 6) & 0x3f))
				utf8_bytes.append(0x80 | (codepoint & 0x3f))
			else:
				utf8_bytes.append(0xf0 | (codepoint >> 18))
				utf8_bytes.append(0x80 | ((codepoint >> 12) & 0x3f))
				utf8_bytes.append(0x80 | ((codepoint >> 6) & 0x3f))
				utf8_bytes.append(0x80 | (codepoint & 0x3f))
		return {"ok": true, "value": utf8_bytes, "encoded": "".join(encoded_parts)}


	func _decode_hex_code_unit(value: String) -> int:
		if value.length() != 4:
			return -1
		var result := 0
		for character in value:
			var code := character.unicode_at(0)
			var digit := -1
			if code >= 48 and code <= 57:
				digit = code - 48
			elif code >= 65 and code <= 70:
				digit = code - 65 + 10
			elif code >= 97 and code <= 102:
				digit = code - 97 + 10
			else:
				return -1
			result = (result << 4) | digit
		return result


	func _encode_safe_json_string(value: Variant, encoded_codepoints: String) -> String:
		if value is PackedByteArray:
			var encoded_bytes := PackedStringArray()
			for byte in value:
				encoded_bytes.append("%02x" % byte)
			return '"%sb:%s"' % [_SCANNED_STRING_PREFIX, "".join(encoded_bytes)]
		return '"%ss:%s"' % [_SCANNED_STRING_PREFIX, encoded_codepoints]


	func _materialize_sanitized_text() -> String:
		if _string_replacements.is_empty():
			return _text
		var parts := PackedStringArray()
		var cursor := 0
		for replacement in _string_replacements:
			var start: int = replacement["start"]
			var end: int = replacement["end"]
			parts.append(_text.substr(cursor, start - cursor))
			parts.append(replacement["text"])
			cursor = end
		parts.append(_text.substr(cursor))
		return "".join(parts)


	func _parse_number() -> bool:
		var start := _position
		_consume("-")
		if _at_end():
			return _fail("Incomplete JSON number")
		if _consume("0"):
			if not _at_end() and _is_digit(_character()):
				return _fail("JSON numbers cannot have leading zeroes")
		elif _is_nonzero_digit(_character()):
			while not _at_end() and _is_digit(_character()):
				_position += 1
		else:
			return _fail("Invalid JSON number")

		if _consume("."):
			if _at_end() or not _is_digit(_character()):
				return _fail("JSON fraction requires digits")
			while not _at_end() and _is_digit(_character()):
				_position += 1
		if not _at_end() and _character() in ["e", "E"]:
			_position += 1
			if not _at_end() and _character() in ["+", "-"]:
				_position += 1
			if _at_end() or not _is_digit(_character()):
				return _fail("JSON exponent requires digits")
			while not _at_end() and _is_digit(_character()):
				_position += 1

		var token := _text.substr(start, _position - start)
		if token.length() > _max_number_token_bytes:
			return _fail("JSON number token exceeds the size limit", "number_token_too_long")
		if not _number_is_cross_runtime_safe(token):
			return _fail("JSON number is not cross-runtime safe", "unsafe_number")
		return true


	func _number_is_cross_runtime_safe(token: String) -> bool:
		var parsed := token.to_float()
		if not is_finite(parsed):
			return false
		var integer_result := _normalized_integer_digits(token)
		if not integer_result.get("integer", false):
			# Reject any mathematical fraction that binary64 silently rounds to an
			# integer, including underflow to zero and values near 2^53.
			return parsed != floor(parsed)
		var digits: String = integer_result.get("digits", "0")
		if digits.length() < 16:
			return true
		if digits.length() > 16:
			return false
		return digits <= "9007199254740991"


	func _normalized_integer_digits(token: String) -> Dictionary:
		var unsigned := token.trim_prefix("-")
		var exponent := 0
		var exponent_position := unsigned.find("e")
		if exponent_position < 0:
			exponent_position = unsigned.find("E")
		if exponent_position >= 0:
			var exponent_text := unsigned.substr(exponent_position + 1)
			unsigned = unsigned.substr(0, exponent_position)
			var exponent_negative := exponent_text.begins_with("-")
			var exponent_digits := exponent_text.trim_prefix("+").trim_prefix("-")
			exponent_digits = _trim_leading_zeroes(exponent_digits)
			if exponent_digits.length() > 6:
				var mantissa_nonzero := _contains_nonzero_digit(unsigned)
				if not mantissa_nonzero:
					return {"integer": true, "digits": "0", "nonzero": false}
				return {"integer": not exponent_negative, "digits": "99999999999999999", "nonzero": true}
			if not exponent_digits.is_empty():
				exponent = exponent_digits.to_int() * (-1 if exponent_negative else 1)

		var decimal_position := unsigned.find(".")
		var fraction_digits := 0
		if decimal_position >= 0:
			fraction_digits = unsigned.length() - decimal_position - 1
			unsigned = unsigned.erase(decimal_position, 1)
		var digits := _trim_leading_zeroes(unsigned)
		if digits.is_empty():
			return {"integer": true, "digits": "0", "nonzero": false}

		var scale := exponent - fraction_digits
		if scale >= 0:
			if digits.length() + scale > 16:
				return {"integer": true, "digits": "99999999999999999", "nonzero": true}
			return {"integer": true, "digits": digits + "0".repeat(scale), "nonzero": true}

		var zeroes_to_remove := -scale
		if zeroes_to_remove > digits.length():
			return {"integer": false, "nonzero": true}
		for offset in zeroes_to_remove:
			if digits[digits.length() - 1 - offset] != "0":
				return {"integer": false, "nonzero": true}
		digits = digits.left(digits.length() - zeroes_to_remove)
		return {"integer": true, "digits": "0" if digits.is_empty() else digits, "nonzero": true}


	func _trim_leading_zeroes(text: String) -> String:
		var first_nonzero := 0
		while first_nonzero < text.length() and text[first_nonzero] == "0":
			first_nonzero += 1
		return text.substr(first_nonzero)


	func _contains_nonzero_digit(text: String) -> bool:
		for character in text:
			if character >= "1" and character <= "9":
				return true
		return false


	func _consume_literal(literal: String) -> bool:
		if _text.substr(_position, literal.length()) != literal:
			return _fail("Invalid JSON literal")
		_position += literal.length()
		return true


	func _consume(character: String) -> bool:
		if _at_end() or _character() != character:
			return false
		_position += 1
		return true


	func _skip_whitespace() -> void:
		while not _at_end() and _character() in [" ", "\t", "\n", "\r"]:
			_position += 1


	func _character() -> String:
		return _text[_position]


	func _at_end() -> bool:
		return _position >= _text.length()


	func _fail(message: String, code: String = "invalid_json") -> bool:
		if _error.is_empty():
			_error = message
			_error_code = code
		return false


	func _is_digit(character: String) -> bool:
		return character >= "0" and character <= "9"


	func _is_nonzero_digit(character: String) -> bool:
		return character >= "1" and character <= "9"


	func _is_hex_digit(character: String) -> bool:
		return _is_digit(character) or (character >= "a" and character <= "f") or (character >= "A" and character <= "F")
