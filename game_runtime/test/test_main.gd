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
