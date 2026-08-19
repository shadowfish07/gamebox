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
		if index + 1 >= args.size():
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
	if _contains_ascii_whitespace_or_control(value):
		return false
	var scheme_separator := value.find("://")
	if scheme_separator < 0:
		return false
	var scheme := value.left(scheme_separator)
	if scheme != "ws" and scheme != "wss":
		return false
	var authority_and_suffix := value.substr(scheme_separator + 3)
	var authority_end := authority_and_suffix.length()
	for delimiter in ["/", "?", "#"]:
		var delimiter_index := authority_and_suffix.find(delimiter)
		if delimiter_index >= 0:
			authority_end = min(authority_end, delimiter_index)
	var authority := authority_and_suffix.left(authority_end)
	if authority.is_empty():
		return false

	if authority.begins_with("["):
		return _is_valid_bracketed_ipv6_authority(authority)
	if authority.contains("[") or authority.contains("]"):
		return false
	return _is_valid_host_authority(authority)


static func _contains_ascii_whitespace_or_control(value: String) -> bool:
	for index in value.length():
		var code := value.unicode_at(index)
		if code <= 32 or code == 127:
			return true
	return false


static func _is_valid_bracketed_ipv6_authority(authority: String) -> bool:
	var closing_bracket := authority.find("]")
	if closing_bracket <= 1:
		return false
	var host := authority.substr(1, closing_bracket - 1)
	if not _is_valid_ipv6(host):
		return false
	return _is_valid_port_suffix(authority.substr(closing_bracket + 1))


static func _is_valid_ipv6(host: String) -> bool:
	if not host.contains(":") or host.find("::") != host.rfind("::"):
		return false
	var groups := host.split(":", false)
	if host.contains("::"):
		if groups.size() > 7:
			return false
	elif groups.size() != 8:
		return false
	for group in groups:
		if group.is_empty() or group.length() > 4:
			return false
		for index in group.length():
			var code := group.unicode_at(index)
			var is_digit := code >= 48 and code <= 57
			var is_lower_hex := code >= 97 and code <= 102
			var is_upper_hex := code >= 65 and code <= 70
			if not (is_digit or is_lower_hex or is_upper_hex):
				return false
	return true


static func _is_valid_host_authority(authority: String) -> bool:
	var port_separator := authority.rfind(":")
	if port_separator < 0:
		return not authority.is_empty()
	var host := authority.left(port_separator)
	if host.is_empty() or host.contains(":"):
		return false
	return _is_valid_port_suffix(authority.substr(port_separator))


static func _is_valid_port_suffix(suffix: String) -> bool:
	if suffix.is_empty():
		return true
	if not suffix.begins_with(":"):
		return false
	var port := suffix.substr(1)
	if port.is_empty() or port.length() > 5:
		return false
	for index in port.length():
		var code := port.unicode_at(index)
		if code < 48 or code > 57:
			return false
	var port_number := port.to_int()
	return port_number >= 1 and port_number <= 65535
