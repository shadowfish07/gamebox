extends RefCounted

const VERSION := 1
const MAX_SAFE_JSON_INTEGER := 9007199254740991
const MAX_MESSAGE_BYTES := 64 * 1024
const MAX_JSON_DEPTH := 32
const MAX_NUMBER_TOKEN_BYTES := 128

const TYPE_PLATFORM_CONNECT := "platform.connect"
const TYPE_PLATFORM_CONNECTED := "platform.connected"
const TYPE_PLATFORM_PING := "platform.ping"
const TYPE_PLATFORM_PONG := "platform.pong"
const TYPE_PLATFORM_SNAPSHOT := "platform.snapshot"
const TYPE_PLATFORM_SNAPSHOT_REQUESTED := "platform.snapshot.requested"
const TYPE_PLATFORM_ERROR := "platform.error"
const TYPE_PLATFORM_MATCH_CANCELLED := "platform.match.cancelled"
const TYPE_PLATFORM_MATCH_ABANDONED := "platform.match.abandoned"
const TYPE_GOMOKU_MOVE_REQUESTED := "gomoku.move.requested"
const TYPE_GOMOKU_MOVE_ACCEPTED := "gomoku.move.accepted"
const TYPE_GOMOKU_RESIGN_REQUESTED := "gomoku.resign.requested"
const TYPE_GOMOKU_RESIGNED := "gomoku.resigned"

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
	TYPE_PLATFORM_SNAPSHOT: true,
	TYPE_PLATFORM_SNAPSHOT_REQUESTED: true,
	TYPE_PLATFORM_ERROR: true,
	TYPE_PLATFORM_MATCH_CANCELLED: true,
	TYPE_PLATFORM_MATCH_ABANDONED: true,
	TYPE_GOMOKU_MOVE_REQUESTED: true,
	TYPE_GOMOKU_MOVE_ACCEPTED: true,
	TYPE_GOMOKU_RESIGN_REQUESTED: true,
	TYPE_GOMOKU_RESIGNED: true,
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
	if parser.parse(text) != OK:
		return _failure("invalid_json", "Message is not valid JSON")
	if not parser.data is Dictionary:
		return _failure("invalid_envelope", "Message must be a JSON object")

	var envelope: Dictionary = _normalize_json_numbers(parser.data)
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
	payload: Variant
) -> Dictionary:
	if not payload is Dictionary:
		return _failure("invalid_payload", "payload must be a JSON object")
	if not _is_json_safe(payload, [], 2):
		return _failure("invalid_payload", "payload contains a value that cannot be represented safely in JSON")
	var envelope := {
		"protocolVersion": VERSION,
		"gameId": "gomoku",
		"matchId": match_id,
		"expectedRevision": revision,
		"type": message_type,
		"actionId": action_id,
		"payload": payload,
	}
	var validation := _validate_envelope(envelope)
	if not validation.get("ok", false):
		return validation
	var text := JSON.stringify(envelope, "", true, true)
	if text.length() > MAX_MESSAGE_BYTES or text.to_utf8_buffer().size() > MAX_MESSAGE_BYTES:
		return _failure("message_too_large", "Message exceeds the size limit")
	var verification := decode(text)
	if not verification.get("ok", false):
		return _failure("encoding_failed", "Encoded action did not satisfy the protocol contract")
	return {"ok": true, "text": text}


static func _is_json_safe(value: Variant, ancestors: Array, depth: int) -> bool:
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_STRING:
			return true
		TYPE_INT:
			return value >= -MAX_SAFE_JSON_INTEGER and value <= MAX_SAFE_JSON_INTEGER
		TYPE_FLOAT:
			if not is_finite(value):
				return false
			if value == floor(value):
				return value >= -MAX_SAFE_JSON_INTEGER and value <= MAX_SAFE_JSON_INTEGER
			return true
		TYPE_ARRAY, TYPE_DICTIONARY:
			if depth > MAX_JSON_DEPTH:
				return false
			for ancestor in ancestors:
				if is_same(ancestor, value):
					return false
			var nested_ancestors := ancestors.duplicate()
			nested_ancestors.append(value)
			if value is Array:
				for item in value:
					if not _is_json_safe(item, nested_ancestors, depth + 1):
						return false
			else:
				for key in value:
					if not key is String or not _is_json_safe(value[key], nested_ancestors, depth + 1):
						return false
			return true
		_:
			return false


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


static func _is_client_action(message_type: String) -> bool:
	return message_type == TYPE_GOMOKU_MOVE_REQUESTED or message_type == TYPE_GOMOKU_RESIGN_REQUESTED


static func _is_revisionless_control(message_type: String) -> bool:
	return message_type in [
		TYPE_PLATFORM_CONNECT,
		TYPE_PLATFORM_PONG,
		TYPE_PLATFORM_SNAPSHOT_REQUESTED,
	]


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
		return {"ok": true}


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
		while true:
			if _at_end() or _character() != '"':
				return _fail("Expected a JSON object key")
			var key_result := _parse_string()
			if not key_result.get("ok", false):
				return false
			var key: String = key_result["value"]
			if top_level:
				if key_result.get("raw", "") != key:
					return _fail("Message envelope is invalid", "invalid_envelope")
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
				_position += 1
				var decoded = JSON.parse_string('"' + raw + '"')
				if not decoded is String:
					_fail("Invalid JSON string")
					return {"ok": false}
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
