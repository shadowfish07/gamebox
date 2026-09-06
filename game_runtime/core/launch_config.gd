class_name LaunchConfig
extends RefCounted

const GAME_IDS := ["chinese_checkers", "flight_chess", "gomoku", "rps"]
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

	if values["--game-id"] not in GAME_IDS:
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
	if authority.is_empty() or authority.contains("@") or authority.contains("\\") or authority.contains("%"):
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
	var host := authority
	var port_suffix := ""
	if port_separator >= 0:
		host = authority.left(port_separator)
		port_suffix = authority.substr(port_separator)
	if host.is_empty() or host.contains(":"):
		return false
	return _is_valid_hostname_or_ipv4(host) and _is_valid_port_suffix(port_suffix)


static func _is_valid_hostname_or_ipv4(host: String) -> bool:
	if host.length() > 253:
		return false
	if _looks_like_ipv4(host):
		return _is_valid_ipv4(host)
	return _is_valid_hostname(host)


static func _looks_like_ipv4(host: String) -> bool:
	if not host.contains("."):
		return false
	for index in host.length():
		var code := host.unicode_at(index)
		if code != 46 and (code < 48 or code > 57):
			return false
	return true


static func _is_valid_ipv4(host: String) -> bool:
	var octets := host.split(".", true)
	if octets.size() != 4:
		return false
	for octet in octets:
		if octet.is_empty() or octet.length() > 3:
			return false
		for index in octet.length():
			var code := octet.unicode_at(index)
			if code < 48 or code > 57:
				return false
		if octet.to_int() > 255:
			return false
	return true


static func _is_valid_hostname(host: String) -> bool:
	var labels := host.split(".", true)
	for label in labels:
		if label.is_empty() or label.length() > 63:
			return false
		if not _is_ascii_alphanumeric(label.unicode_at(0)) or not _is_ascii_alphanumeric(label.unicode_at(label.length() - 1)):
			return false
		for index in label.length():
			var code := label.unicode_at(index)
			if not _is_ascii_alphanumeric(code) and code != 45:
				return false
	return true


static func _is_ascii_alphanumeric(code: int) -> bool:
	return (code >= 48 and code <= 57) or (code >= 65 and code <= 90) or (code >= 97 and code <= 122)


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
