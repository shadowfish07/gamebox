extends RefCounted

const MainScene = preload("res://main.tscn")
const MainScript = preload("res://main.gd")
const GameRegistry = preload("res://core/game_registry.gd")


static func cases() -> Array:
	return [
		{"name": "host smoke accepts bounded decimal delay", "run": _accepts_bounded_smoke_delay},
		{"name": "host smoke rejects invalid delays", "run": _rejects_invalid_smoke_delays},
		{"name": "gomoku fills a viewport-hosted main scene", "run": _gomoku_fills_viewport_host},
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


static func _gomoku_fills_viewport_host() -> bool:
	var tree := Engine.get_main_loop() as SceneTree
	var host = MainScene.instantiate()
	tree.root.add_child(host)
	await tree.process_frame
	var host_control := host as Control
	if not _check(host_control != null and host_control.size.x > 0.0 and host_control.size.y > 0.0, "expected positive host Control size"):
		host.queue_free()
		return false
	var scene_result: Dictionary = GameRegistry.resolve("gomoku")
	var gomoku = scene_result["scene"].instantiate() as Control
	host.add_child(gomoku)
	await tree.process_frame
	var has_size: bool = gomoku.size.x > 0.0 and gomoku.size.y > 0.0
	host.queue_free()
	return _check(has_size, "expected positive Gomoku Control size after a process frame")


static func _check(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition
