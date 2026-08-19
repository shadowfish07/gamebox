extends Control

const LaunchConfig = preload("res://core/launch_config.gd")
const GameRegistry = preload("res://core/game_registry.gd")
const SAFE_LAUNCH_ERROR := "Unable to launch game. Please return to Gamebox and try again."
const HOST_SMOKE_MAX_DELAY_MS := 60000


func _ready() -> void:
	_start_with_args(OS.get_cmdline_user_args())


func _start_with_args(args: PackedStringArray) -> void:
	if args.is_empty():
		return
	if _has_host_smoke_key(args):
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


func _has_host_smoke_key(args: PackedStringArray) -> bool:
	for index in range(0, args.size(), 2):
		if args[index] == "--host-smoke":
			return true
	return false


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
			if not _is_valid_host_smoke_delay(value):
				return {"ok": false}
			has_auto_exit = true
			auto_exit_ms = value.to_int()
			index += 2
		else:
			return {"ok": false}
	return {"ok": has_smoke, "auto_exit_ms": auto_exit_ms}


func _is_valid_host_smoke_delay(value: String) -> bool:
	if value.is_empty() or value.length() > 5:
		return false
	for index in value.length():
		var code := value.unicode_at(index)
		if code < 48 or code > 57:
			return false
	var delay_ms := value.to_int()
	return delay_ms >= 1 and delay_ms <= HOST_SMOKE_MAX_DELAY_MS


func _show_launch_error(code: String) -> void:
	$ReadyLabel.text = SAFE_LAUNCH_ERROR
	push_error("Game launch failed: %s" % code)
