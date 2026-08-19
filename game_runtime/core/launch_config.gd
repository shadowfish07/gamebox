class_name LaunchConfig
extends RefCounted

const GAME_ID := "gomoku"
const REQUIRED_KEYS := ["--game-id", "--match-id", "--launch-ticket", "--ws-url"]
const SAFE_ERROR_MESSAGE := "Invalid launch configuration."


static func parse(args: PackedStringArray) -> Dictionary:
	var values := {}
	var index := 0
	while index < args.size():
		var key := args[index]
		if not REQUIRED_KEYS.has(key):
			return _failure("unknown_argument")
		if values.has(key):
			return _failure("duplicate_argument")
		if index + 1 >= args.size() or args[index + 1].begins_with("--"):
			return _failure("missing_required_argument")
		values[key] = args[index + 1]
		index += 2

	for key in REQUIRED_KEYS:
		if not values.has(key):
			return _failure("missing_required_argument")

	if values["--game-id"] != GAME_ID:
		return _failure("unsupported_game_id")
	if not _is_canonical_uuid(values["--match-id"]):
		return _failure("invalid_match_id")
	if values["--launch-ticket"].is_empty():
		return _failure("invalid_launch_ticket")
	if not _is_valid_ws_url(values["--ws-url"]):
		return _failure("invalid_ws_url")

	return {
		"ok": true,
		"code": "",
		"message": "",
		"config": {
			"game_id": values["--game-id"],
			"match_id": values["--match-id"],
			"launch_ticket": values["--launch-ticket"],
			"ws_url": values["--ws-url"],
		},
	}


static func _failure(code: String) -> Dictionary:
	return {"ok": false, "code": code, "message": SAFE_ERROR_MESSAGE}


static func _is_canonical_uuid(value: String) -> bool:
	var uuid_pattern := RegEx.new()
	uuid_pattern.compile("^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
	return uuid_pattern.search(value) != null


static func _is_valid_ws_url(value: String) -> bool:
	if value.contains(" "):
		return false
	var ws_pattern := RegEx.new()
	ws_pattern.compile("^wss?://([^/?#:]+|\\[[0-9A-Fa-f:.]+\\])(?::[0-9]+)?(?:[/?#].*)?$")
	return ws_pattern.search(value) != null
