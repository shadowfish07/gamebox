extends SceneTree

const FLIGHT_CHESS_SCENE := preload("res://games/flight_chess/flight_chess_scene.tscn")

var _state_name := "ready"
var _viewport := Vector2i(1280, 720)
var _screenshot_path := ""
var _theme_name := "light"
var _safe_insets := Vector4.ZERO


func _init() -> void:
	if not _parse_arguments(OS.get_cmdline_user_args()):
		return
	DisplayServer.window_set_size(_viewport)
	call_deferred("_mount")


func _mount() -> void:
	var scene: Control = FLIGHT_CHESS_SCENE.instantiate()
	scene.set_preview_state(_state_name)
	scene.set_preview_dark(_theme_name == "dark")
	scene.set_preview_safe_insets(_safe_insets)
	scene.set_quit_callback(func() -> void: quit())
	get_root().add_child(scene)
	if not _screenshot_path.is_empty():
		_capture_screenshot.call_deferred()


func _capture_screenshot() -> void:
	for _frame in 6:
		await process_frame
	await create_timer(0.35).timeout
	for _frame in 2:
		await RenderingServer.frame_post_draw
		await process_frame
	RenderingServer.force_draw()
	RenderingServer.force_sync()
	var error := get_root().get_texture().get_image().save_png(_screenshot_path)
	if error != OK:
		push_error("Flight Chess preview screenshot failed: %s" % error_string(error))
		quit(1)
		return
	print("Flight Chess preview saved: %s" % _screenshot_path)
	quit()


func _parse_arguments(args: PackedStringArray) -> bool:
	var index := 0
	while index < args.size():
		if index + 1 >= args.size():
			push_error("Expected a value after %s" % args[index])
			quit(2)
			return false
		match args[index]:
			"--state":
				_state_name = args[index + 1]
				if _state_name not in ["ready", "rolled", "pressed", "selected", "stacked"]:
					push_error("Unknown preview state: %s" % _state_name)
					quit(2)
					return false
			"--viewport":
				_viewport = _parse_viewport(args[index + 1])
				if _viewport == Vector2i.ZERO:
					push_error("Viewport must be a landscape WIDTHxHEIGHT of at least 960x540")
					quit(2)
					return false
			"--screenshot":
				_screenshot_path = args[index + 1]
				if _screenshot_path.is_empty():
					push_error("Screenshot path must not be empty")
					quit(2)
					return false
			"--theme":
				_theme_name = args[index + 1]
				if _theme_name not in ["light", "dark"]:
					push_error("Theme must be light or dark")
					quit(2)
					return false
			"--safe-insets":
				_safe_insets = _parse_insets(args[index + 1])
				if _safe_insets.x < 0.0:
					push_error("Safe insets must be four non-negative values: LEFT,TOP,RIGHT,BOTTOM")
					quit(2)
					return false
			_:
				push_error("Unknown preview option: %s" % args[index])
				quit(2)
				return false
		index += 2
	if _safe_insets.x + _safe_insets.z >= _viewport.x or _safe_insets.y + _safe_insets.w >= _viewport.y:
		push_error("Safe insets leave no usable viewport")
		quit(2)
		return false
	return true


func _parse_viewport(value: String) -> Vector2i:
	var parts := value.split("x", false)
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return Vector2i.ZERO
	var result := Vector2i(parts[0].to_int(), parts[1].to_int())
	return result if result.x >= 960 and result.y >= 540 and result.x > result.y else Vector2i.ZERO


func _parse_insets(value: String) -> Vector4:
	var parts := value.split(",", false)
	if parts.size() != 4:
		return Vector4(-1.0, -1.0, -1.0, -1.0)
	var values := PackedFloat32Array()
	for part in parts:
		if not part.is_valid_float() or part.to_float() < 0.0:
			return Vector4(-1.0, -1.0, -1.0, -1.0)
		values.append(part.to_float())
	return Vector4(values[0], values[1], values[2], values[3])
