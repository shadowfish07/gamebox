extends RefCounted

const LaunchConfig = preload("res://core/launch_config.gd")

const VALID_MATCH_ID := "11111111-1111-4111-8111-111111111111"
const SECRET_TICKET := "ticket-must-not-appear-in-errors"


static func cases() -> Array:
	return [
		{"name": "launch config parses valid arguments in any order", "run": _parses_valid_args_in_any_order},
		{"name": "launch config rejects each missing required argument", "run": _rejects_missing_required_argument},
		{"name": "launch config rejects duplicate arguments", "run": _rejects_duplicate_arguments},
		{"name": "launch config rejects unknown arguments", "run": _rejects_unknown_arguments},
		{"name": "launch config errors do not reveal launch tickets", "run": _errors_do_not_reveal_launch_tickets},
		{"name": "launch config rejects non UUID match ids", "run": _rejects_non_uuid_match_ids},
		{"name": "launch config rejects empty launch tickets", "run": _rejects_empty_launch_tickets},
		{"name": "launch config rejects invalid websocket urls", "run": _rejects_invalid_websocket_urls},
		{"name": "launch config accepts ws websocket urls", "run": _accepts_ws_websocket_urls},
		{"name": "launch config preserves opaque tickets beginning with dashes", "run": _preserves_dash_prefixed_ticket},
		{"name": "launch config validates websocket hosts and ports", "run": _validates_websocket_hosts_and_ports},
	]


static func _valid_args() -> PackedStringArray:
	return PackedStringArray([
		"--game-id", "gomoku",
		"--match-id", VALID_MATCH_ID,
		"--launch-ticket", SECRET_TICKET,
		"--ws-url", "wss://games.example.com/matches",
	])


static func _parses_valid_args_in_any_order() -> bool:
	var args := PackedStringArray([
		"--ws-url", "wss://games.example.com/matches",
		"--launch-ticket", SECRET_TICKET,
		"--match-id", VALID_MATCH_ID,
		"--game-id", "gomoku",
	])
	var result: Dictionary = LaunchConfig.parse(args)
	return _check(result.get("ok", false), "expected valid launch config") \
		and _check(result.get("config", {}).get("game_id", "") == "gomoku", "expected game id") \
		and _check(result.get("config", {}).get("match_id", "") == VALID_MATCH_ID, "expected match id") \
		and _check(result.get("config", {}).get("ws_url", "") == "wss://games.example.com/matches", "expected ws url")


static func _rejects_missing_required_argument() -> bool:
	var required_keys := ["--game-id", "--match-id", "--launch-ticket", "--ws-url"]
	for required_key in required_keys:
		var args := _valid_args()
		var index := args.find(required_key)
		args.remove_at(index + 1)
		args.remove_at(index)
		if not _fails_with(args, "missing_required_argument"):
			return false
	return true


static func _rejects_duplicate_arguments() -> bool:
	var args := _valid_args()
	args.append_array(PackedStringArray(["--launch-ticket", "another-ticket"]))
	return _fails_with(args, "duplicate_argument")


static func _rejects_unknown_arguments() -> bool:
	var args := _valid_args()
	args.append_array(PackedStringArray(["--debug", "true"]))
	return _fails_with(args, "unknown_argument")


static func _errors_do_not_reveal_launch_tickets() -> bool:
	var args := _valid_args()
	args.append_array(PackedStringArray(["--launch-ticket", "another-ticket"]))
	var result: Dictionary = LaunchConfig.parse(args)
	var safe_error := "%s %s" % [result.get("code", ""), result.get("message", "")]
	return _check(not safe_error.contains(SECRET_TICKET), "error exposed the original launch ticket") \
		and _check(not safe_error.contains("another-ticket"), "error exposed the duplicate launch ticket")


static func _rejects_non_uuid_match_ids() -> bool:
	var args := _valid_args()
	args[args.find("--match-id") + 1] = "m1"
	return _fails_with(args, "invalid_match_id")


static func _rejects_empty_launch_tickets() -> bool:
	var args := _valid_args()
	args[args.find("--launch-ticket") + 1] = ""
	return _fails_with(args, "invalid_launch_ticket")


static func _rejects_invalid_websocket_urls() -> bool:
	for invalid_url in ["https://games.example.com", "ws://", "ftp://games.example.com", "not-a-url"]:
		var args := _valid_args()
		args[args.find("--ws-url") + 1] = invalid_url
		if not _fails_with(args, "invalid_ws_url"):
			return false
	return true


static func _accepts_ws_websocket_urls() -> bool:
	var args := _valid_args()
	args[args.find("--ws-url") + 1] = "ws://localhost:8080/matches"
	var result: Dictionary = LaunchConfig.parse(args)
	return _check(result.get("ok", false), "expected ws URL to be accepted")


static func _preserves_dash_prefixed_ticket() -> bool:
	var opaque_ticket := "--opaque.base64url_value"
	var args := _valid_args()
	args[args.find("--launch-ticket") + 1] = opaque_ticket
	var result: Dictionary = LaunchConfig.parse(args)
	return _check(result.get("ok", false), "expected dash-prefixed opaque ticket to parse") \
		and _check(result.get("config", {}).get("launch_ticket", "") == opaque_ticket, "expected unchanged opaque ticket")


static func _validates_websocket_hosts_and_ports() -> bool:
	for valid_url in ["ws://10.0.2.2:8080/v1/ws", "wss://games.example.com", "ws://localhost", "ws://192.168.1.1", "ws://[2001:db8::1]:8080/v1/ws"]:
		var valid_args := _valid_args()
		valid_args[valid_args.find("--ws-url") + 1] = valid_url
		if not _check(LaunchConfig.parse(valid_args).get("ok", false), "expected valid ws URL %s" % valid_url):
			return false
	for invalid_url in ["ws://host:0", "ws://host:99999", "ws://host\t/path", "ws://host\n/path", "ws://[2001:db8::1", "ws://2001:db8::1", "ws://user@host", "ws://host\\path", "ws://host%2f.example", "ws://api..example", "ws://-api.example", "ws://api-.example", "ws://256.0.0.1"]:
		var invalid_args := _valid_args()
		invalid_args[invalid_args.find("--ws-url") + 1] = invalid_url
		if not _fails_with(invalid_args, "invalid_ws_url"):
			return false
	return true



static func _fails_with(args: PackedStringArray, expected_code: String) -> bool:
	var result: Dictionary = LaunchConfig.parse(args)
	return _check(not result.get("ok", true), "expected launch config failure") \
		and _check(result.get("code", "") == expected_code, "expected error code %s" % expected_code)


static func _check(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition
