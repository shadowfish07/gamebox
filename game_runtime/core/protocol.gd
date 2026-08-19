extends RefCounted

const VERSION := 1

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
	var parser := JSON.new()
	if parser.parse(text) != OK:
		return _failure("invalid_json", "Message is not valid JSON")
	if not parser.data is Dictionary:
		return _failure("invalid_envelope", "Message must be a JSON object")

	var envelope: Dictionary = _normalize_json_numbers(parser.data)
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
	payload: Dictionary
) -> String:
	var envelope := {
		"protocolVersion": VERSION,
		"gameId": "gomoku",
		"matchId": match_id,
		"expectedRevision": revision,
		"type": message_type,
		"actionId": action_id,
		"payload": payload,
	}
	return JSON.stringify(envelope)


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
