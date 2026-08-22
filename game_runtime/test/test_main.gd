extends RefCounted

const MainScene = preload("res://main.tscn")
const MainScript = preload("res://main.gd")
const GameRegistry = preload("res://core/game_registry.gd")


static func cases() -> Array:
	return [
		{"name": "host smoke accepts bounded decimal delay", "run": _accepts_bounded_smoke_delay},
		{"name": "host smoke rejects invalid delays", "run": _rejects_invalid_smoke_delays},
		{"name": "main helper starts one full-viewport gomoku scene", "run": _starts_gomoku_in_main_scene},
		{"name": "opaque smoke-looking ticket remains a normal launch", "run": _keeps_smoke_looking_ticket_in_normal_launch},
		{"name": "host smoke exposes a controlled exit marker", "run": _has_controlled_exit_marker},
		{"name": "private ticket is hydrated once before LaunchConfig", "run": _hydrates_private_ticket_once},
		{"name": "main injects hydrated launch config without retaining a second ticket", "run": _injects_hydrated_config_once},
		{"name": "private ticket hydration uses fixed key positions", "run": _hydrates_ticket_with_key_collision_value},
		{"name": "malformed private ticket arguments fail closed", "run": _rejects_malformed_private_ticket_args},
		{"name": "project requests portrait handheld orientation", "run": _requests_portrait_orientation},
		{"name": "project expands into tall portrait screens", "run": _expands_into_tall_portrait_screens},
	]


static func _accepts_bounded_smoke_delay() -> bool:
	var host = MainScript.new()
	var result: Dictionary = host._parse_host_smoke_args(PackedStringArray(["--host-smoke", "--auto-exit-ms", "800"]))
	host.free()
	return _check(result.get("ok", false), "expected bounded smoke delay to parse") \
		and _check(result.get("auto_exit_ms", 0) == 800, "expected unchanged smoke delay")


static func _rejects_invalid_smoke_delays() -> bool:
	for value in ["0", "-1", "8ms", "999999999999999999999", "60001"]:
		var host = MainScript.new()
		var result: Dictionary = host._parse_host_smoke_args(PackedStringArray(["--host-smoke", "--auto-exit-ms", value]))
		host.free()
		if not _check(not result.get("ok", true), "expected invalid smoke delay %s to fail" % value):
			return false
	return true


static func _starts_gomoku_in_main_scene() -> bool:
	var host = await _attached_main_scene()
	host._start_with_args(_valid_launch_args())
	await (Engine.get_main_loop() as SceneTree).process_frame
	var ready_label := host.get_node("ReadyLabel") as Label
	var gomoku_children := _gomoku_children(host)
	var result := _check(not ready_label.visible, "expected ReadyLabel to hide after a valid launch") \
		and _check(gomoku_children.size() == 1, "expected exactly one Gomoku child")
	if result:
		result = _check(gomoku_children[0].size == host.size, "expected Gomoku size to equal host viewport size")
	host.queue_free()
	return result


static func _keeps_smoke_looking_ticket_in_normal_launch() -> bool:
	var host = await _attached_main_scene()
	var args := _valid_launch_args()
	args[args.find("--launch-ticket") + 1] = "--host-smoke"
	host._start_with_args(args)
	await (Engine.get_main_loop() as SceneTree).process_frame
	var ready_label := host.get_node("ReadyLabel") as Label
	var result := _check(not ready_label.visible, "expected smoke-looking ticket to remain a normal launch") \
		and _check(_gomoku_children(host).size() == 1, "expected normal Gomoku child for opaque ticket")
	host.queue_free()
	return result


static func _has_controlled_exit_marker() -> bool:
	return _check(
		MainScript.HOST_SMOKE_EXITING_MARKER == "GAMEBOX_GODOT_EXITING",
		"expected stable controlled exit marker",
	)


static func _hydrates_private_ticket_once() -> bool:
	var host = MainScript.new()
	var args := _valid_launch_args()
	args[args.find("--launch-ticket") + 1] = MainScript.PRIVATE_TICKET_PLACEHOLDER
	OS.set_environment(MainScript.PRIVATE_TICKET_ENVIRONMENT, "private-canary-ticket")
	var result: Dictionary = host._hydrate_private_launch_ticket(args)
	var hydrated_args: PackedStringArray = result.get("args", PackedStringArray())
	var hydrated_ticket := ""
	if not hydrated_args.is_empty():
		hydrated_ticket = hydrated_args[hydrated_args.find("--launch-ticket") + 1]
	host.free()
	return _check(result.get("ok", false), "expected private ticket hydration") \
		and _check(hydrated_ticket == "private-canary-ticket", "expected unchanged private ticket") \
		and _check(not OS.has_environment(MainScript.PRIVATE_TICKET_ENVIRONMENT), "expected private environment to be cleared")


static func _injects_hydrated_config_once() -> bool:
	var host = await _attached_main_scene()
	var args := _valid_launch_args()
	args[args.find("--launch-ticket") + 1] = MainScript.PRIVATE_TICKET_PLACEHOLDER
	const PRIVATE_CANARY := "private-injected-canary-ticket"
	OS.set_environment(MainScript.PRIVATE_TICKET_ENVIRONMENT, PRIVATE_CANARY)
	host._start_with_args(args)
	await (Engine.get_main_loop() as SceneTree).process_frame
	var gomoku_children := _gomoku_children(host)
	var result := _check(gomoku_children.size() == 1, "expected configured Gomoku child")
	if result:
		var controller: Control = gomoku_children[0]
		result = _check(controller._launch_config.is_empty(), "controller retained injected config after start") \
			and _check(controller._client._launch_ticket == PRIVATE_CANARY, "hydrated ticket was not passed to MatchClient") \
			and _check(not str(controller).contains(PRIVATE_CANARY), "controller string exposed private ticket")
	result = _check(not OS.has_environment(MainScript.PRIVATE_TICKET_ENVIRONMENT), "private environment survived controller injection") and result
	host.queue_free()
	return result


static func _hydrates_ticket_with_key_collision_value() -> bool:
	var host = MainScript.new()
	var args := _valid_launch_args()
	args[1] = "--launch-ticket"
	args[5] = MainScript.PRIVATE_TICKET_PLACEHOLDER
	OS.set_environment(MainScript.PRIVATE_TICKET_ENVIRONMENT, "collision-canary-secret")
	var result: Dictionary = host._hydrate_private_launch_ticket(args)
	var hydrated_args: PackedStringArray = result.get("args", PackedStringArray())
	host.free()
	return _check(result.get("ok", false), "expected fixed-position hydration") \
		and _check(hydrated_args[1] == "--launch-ticket", "expected collision value unchanged") \
		and _check(hydrated_args[5] == "collision-canary-secret", "expected actual ticket hydrated") \
		and _check(not OS.has_environment(MainScript.PRIVATE_TICKET_ENVIRONMENT), "expected private environment cleared")


static func _rejects_malformed_private_ticket_args() -> bool:
	var malformed_inputs := [
		PackedStringArray(["--launch-ticket", MainScript.PRIVATE_TICKET_PLACEHOLDER]),
		PackedStringArray(["--game-id", "gomoku", "--launch-ticket", "decoy", "--launch-ticket", MainScript.PRIVATE_TICKET_PLACEHOLDER, "--ws-url", "ws://127.0.0.1"]),
	]
	for args in malformed_inputs:
		var host = MainScript.new()
		OS.set_environment(MainScript.PRIVATE_TICKET_ENVIRONMENT, "must-not-hydrate")
		var result: Dictionary = host._hydrate_private_launch_ticket(args)
		host.free()
		if not _check(not result.get("ok", true), "expected malformed private args to fail"):
			return false
		if not _check(not OS.has_environment(MainScript.PRIVATE_TICKET_ENVIRONMENT), "expected malformed environment cleared"):
			return false
	return true


static func _requests_portrait_orientation() -> bool:
	return _check(
		ProjectSettings.get_setting("display/window/handheld/orientation") == DisplayServer.SCREEN_PORTRAIT,
		"expected portrait handheld orientation",
	)


static func _expands_into_tall_portrait_screens() -> bool:
	return _check(
		ProjectSettings.get_setting("display/window/stretch/aspect") == "expand",
		"expected stretch aspect to expand instead of adding letterbox bars",
	)


static func _attached_main_scene() -> Control:
	var tree := Engine.get_main_loop() as SceneTree
	var host := MainScene.instantiate() as Control
	tree.root.add_child(host)
	await tree.process_frame
	return host


static func _valid_launch_args() -> PackedStringArray:
	return PackedStringArray(["--game-id", "gomoku", "--match-id", "11111111-1111-4111-8111-111111111111", "--launch-ticket", "opaque-ticket", "--ws-url", "ws://10.0.2.2:8080/v1/ws"])


static func _gomoku_children(host: Control) -> Array[Control]:
	var gomoku_children: Array[Control] = []
	for child in host.get_children():
		if child is Control and child.name == "Gomoku":
			gomoku_children.append(child)
	return gomoku_children


static func _check(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition
