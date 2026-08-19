extends Control

const LaunchConfig = preload("res://core/launch_config.gd")
const GameRegistry = preload("res://core/game_registry.gd")
const SAFE_LAUNCH_ERROR := "Unable to launch game. Please return to Gamebox and try again."
const HOST_SMOKE_MAX_DELAY_MS := 60000
const HOST_SMOKE_EXITING_MARKER := "GAMEBOX_GODOT_EXITING"
const NORMAL_READY_MARKER := "GAMEBOX_GODOT_NORMAL_READY"
const PRIVATE_TICKET_ENVIRONMENT := "GAMEBOX_PRIVATE_LAUNCH_TICKET"
const PRIVATE_TICKET_PLACEHOLDER := "__GAMEBOX_PRIVATE_LAUNCH_TICKET__"


func _ready() -> void:
	_start_with_args(OS.get_cmdline_user_args())


func _start_with_args(args: PackedStringArray) -> void:
	if args.is_empty():
		return
	if _has_host_smoke_key(args):
		_start_host_smoke(args)
		return
	var hydration_result := _hydrate_private_launch_ticket(args)
	if not hydration_result.get("ok", false):
		_show_launch_error("invalid_private_launch_ticket")
		return
	args = hydration_result["args"]

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
	print(NORMAL_READY_MARKER)


func _hydrate_private_launch_ticket(args: PackedStringArray) -> Dictionary:
	var hydrated_args := args.duplicate()
	var ticket_key_index := hydrated_args.find("--launch-ticket")
	if ticket_key_index < 0 or ticket_key_index + 1 >= hydrated_args.size():
		return {"ok": true, "args": hydrated_args}
	var ticket_index := ticket_key_index + 1
	if hydrated_args[ticket_index] != PRIVATE_TICKET_PLACEHOLDER:
		return {"ok": true, "args": hydrated_args}
	var private_ticket := OS.get_environment(PRIVATE_TICKET_ENVIRONMENT)
	OS.unset_environment(PRIVATE_TICKET_ENVIRONMENT)
	if private_ticket.is_empty():
		return {"ok": false}
	hydrated_args[ticket_index] = private_ticket
	return {"ok": true, "args": hydrated_args}


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
		get_tree().create_timer(auto_exit_ms / 1000.0).timeout.connect(_controlled_host_smoke_exit)


func _controlled_host_smoke_exit() -> void:
	print(HOST_SMOKE_EXITING_MARKER)
	get_tree().quit()


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
