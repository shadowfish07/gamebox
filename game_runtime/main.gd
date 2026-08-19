extends Node2D

const LaunchConfig = preload("res://core/launch_config.gd")
const GameRegistry = preload("res://core/game_registry.gd")
const SAFE_LAUNCH_ERROR := "Unable to launch game. Please return to Gamebox and try again."


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		return
	if args.has("--host-smoke"):
		_start_host_smoke(args)
		return

	var config_result: Dictionary = LaunchConfig.parse(args)
	if not config_result.get("ok", false):
		_show_launch_error(config_result.get("code", "invalid_launch_configuration"))
		return

	var registry_result: Dictionary = GameRegistry.resolve(config_result["config"]["game_id"])
	if not registry_result.get("ok", false):
		_show_launch_error(registry_result.get("code", "unsupported_game"))
		return

	$ReadyLabel.hide()
	add_child(registry_result["scene"].instantiate())


func _start_host_smoke(args: PackedStringArray) -> void:
	var result := _parse_host_smoke_args(args)
	if not result.get("ok", false):
		_show_launch_error("invalid_host_smoke_arguments")
		return

	$ReadyLabel.text = "GAMEBOX_GODOT_READY"
	print("GAMEBOX_GODOT_READY")
	var auto_exit_ms: int = result.get("auto_exit_ms", 0)
	if auto_exit_ms > 0:
		get_tree().create_timer(auto_exit_ms / 1000.0).timeout.connect(get_tree().quit)


func _parse_host_smoke_args(args: PackedStringArray) -> Dictionary:
	var has_smoke := false
	var has_auto_exit := false
	var auto_exit_ms := 0
	var index := 0
	while index < args.size():
		var key := args[index]
		if key == "--host-smoke":
			if has_smoke:
				return {"ok": false}
			has_smoke = true
			index += 1
		elif key == "--auto-exit-ms":
			if has_auto_exit or index + 1 >= args.size():
				return {"ok": false}
			var value := args[index + 1]
			if not value.is_valid_int() or value.to_int() <= 0:
				return {"ok": false}
			has_auto_exit = true
			auto_exit_ms = value.to_int()
			index += 2
		else:
			return {"ok": false}
	return {"ok": has_smoke, "auto_exit_ms": auto_exit_ms}


func _show_launch_error(code: String) -> void:
	$ReadyLabel.text = SAFE_LAUNCH_ERROR
	push_error("Game launch failed: %s" % code)
