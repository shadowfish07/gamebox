class_name FlightChessSceneController
extends Control

const FlightChessTheme = preload("res://games/flight_chess/flight_chess_theme.gd")
const FlightChessBoard = preload("res://games/flight_chess/flight_chess_board.gd")
const GameboxTheme = preload("res://design_system/gamebox_theme.gd")
const GameboxTokens = preload("res://design_system/generated/gamebox_tokens.gd")

const MIN_VIEWPORT := Vector2(960.0, 540.0)
const LANDSCAPE_CONTENT_SCALE := Vector2i(1920, 1080)
const MIN_RAIL_WIDTH := 192.0
const MAX_RAIL_WIDTH := 360.0
const DICE_SEQUENCE := [6, 4, 2, 5, 3, 1]

var dice_value: int:
	get: return _dice_value
	set(_value): pass

var _pieces := {}
var _dice_value := 0
var _roll_cursor := 0
var _selectable_indices: Array = []
var _selected_index := -1
var _status_text := "你的回合"
var _turn_text := "先掷骰子"
var _hint_text := "掷出 6 后，再选择一架飞机起飞"
var _preview_state := "ready"
var _preview_dark: Variant = null
var _preview_safe_insets := Vector4.ZERO
var _has_preview_safe_insets := false
var _quit_callback := Callable()
var _previous_window_profile := {}
var _layout_ready := false


func _enter_tree() -> void:
	var window := get_window()
	if window == null:
		return
	_previous_window_profile = {
		"size": window.content_scale_size,
		"mode": window.content_scale_mode,
		"aspect": window.content_scale_aspect,
	}
	apply_window_profile(window)


func _exit_tree() -> void:
	if _previous_window_profile.is_empty():
		return
	var window := get_window()
	if window == null:
		return
	if window.content_scale_size == LANDSCAPE_CONTENT_SCALE \
		and window.content_scale_mode == Window.CONTENT_SCALE_MODE_CANVAS_ITEMS \
		and window.content_scale_aspect == Window.CONTENT_SCALE_ASPECT_EXPAND:
		window.content_scale_size = _previous_window_profile["size"]
		window.content_scale_mode = _previous_window_profile["mode"]
		window.content_scale_aspect = _previous_window_profile["aspect"]
	_previous_window_profile.clear()


func _ready() -> void:
	_apply_mobile_orientation()
	var dark := bool(_preview_dark) if _preview_dark is bool else GameboxTheme.system_prefers_dark()
	theme = FlightChessTheme.create(dark)
	$LeftRail/Content/BackButton.pressed.connect(_on_back_pressed)
	$RightRail/Content/RollButton.pressed.connect(_on_roll_pressed)
	$Board.piece_pressed.connect(_on_piece_pressed)
	_reset_demo()
	_apply_preview_state()
	_finish_initial_layout.call_deferred()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and is_node_ready() and _layout_ready:
		_apply_layout()
	elif what == Node.NOTIFICATION_WM_GO_BACK_REQUEST:
		_on_back_pressed()


func _unhandled_key_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and not event.is_echo():
		get_viewport().set_input_as_handled()
		_on_back_pressed()


static func layout_for_size(viewport: Vector2, safe_rect: Rect2 = Rect2()) -> Dictionary:
	if viewport.x < MIN_VIEWPORT.x or viewport.y < MIN_VIEWPORT.y or viewport.x <= viewport.y:
		return {}
	var viewport_rect := Rect2(Vector2.ZERO, viewport)
	var safe_bounds := safe_rect.intersection(viewport_rect) if safe_rect.has_area() else viewport_rect
	if not safe_bounds.has_area():
		return {}
	var page_margin := float(GameboxTokens.SPACING["page"]) * GameboxTheme.LOGICAL_SCALE
	var max_margin := float(GameboxTokens.SPACING["section"]) * GameboxTheme.LOGICAL_SCALE
	var margin := clampf(safe_bounds.size.y * 0.03, page_margin, max_margin)
	var min_gap := float(GameboxTokens.SPACING["layout"]) * GameboxTheme.LOGICAL_SCALE
	var max_gap := float(GameboxTokens.SPACING["compact"]) * GameboxTheme.LOGICAL_SCALE
	var gap := clampf(safe_bounds.size.y * 0.02, min_gap, max_gap)
	var available := safe_bounds.size - Vector2(margin * 2.0, margin * 2.0)
	var board_side := minf(available.y, available.x - MIN_RAIL_WIDTH * 2.0 - gap * 2.0)
	if board_side <= 0.0:
		return {}
	var rail_width := clampf((available.x - board_side - gap * 2.0) * 0.5, MIN_RAIL_WIDTH, MAX_RAIL_WIDTH)
	var total_width := board_side + rail_width * 2.0 + gap * 2.0
	if total_width > available.x:
		return {}
	var origin_y := safe_bounds.position.y + (safe_bounds.size.y - board_side) * 0.5
	var board_x := safe_bounds.get_center().x - board_side * 0.5
	return {
		"left": Rect2(safe_bounds.position.x + margin, origin_y, rail_width, board_side),
		"board": Rect2(board_x, origin_y, board_side, board_side),
		"right": Rect2(safe_bounds.end.x - margin - rail_width, origin_y, rail_width, board_side),
	}


static func preferred_mobile_orientation() -> int:
	return DisplayServer.SCREEN_SENSOR_LANDSCAPE


static func preferred_content_scale_size() -> Vector2i:
	return LANDSCAPE_CONTENT_SCALE


static func apply_window_profile(window: Window) -> void:
	window.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	window.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	window.content_scale_size = LANDSCAPE_CONTENT_SCALE


static func physical_insets_to_logical(insets: Vector4, physical_size: Vector2, logical_size: Vector2) -> Vector4:
	if physical_size.x <= 0.0 or physical_size.y <= 0.0 or logical_size.x <= 0.0 or logical_size.y <= 0.0:
		return Vector4(-1.0, -1.0, -1.0, -1.0)
	var scale := logical_size / physical_size
	return Vector4(insets.x * scale.x, insets.y * scale.y, insets.z * scale.x, insets.w * scale.y)


static func layout_is_compact(layout: Dictionary) -> bool:
	if not layout.has("board") or not layout.has("right"):
		return true
	return (layout["board"] as Rect2).size.y < 650.0 or (layout["right"] as Rect2).size.x < 230.0


func _apply_mobile_orientation() -> void:
	if OS.has_feature("android") and DisplayServer.has_feature(DisplayServer.FEATURE_ORIENTATION):
		DisplayServer.screen_set_orientation(preferred_mobile_orientation())


func _finish_initial_layout() -> void:
	_layout_ready = true
	_apply_layout()


func set_preview_state(state: String) -> bool:
	if state not in ["ready", "rolled", "pressed", "selected", "stacked"]:
		return false
	_preview_state = state
	if is_node_ready():
		_reset_demo()
		_apply_preview_state()
	return true


func set_preview_dark(dark: bool) -> void:
	_preview_dark = dark
	if is_node_ready():
		theme = FlightChessTheme.create(dark)


func set_preview_safe_insets(insets: Vector4) -> bool:
	if insets.x < 0.0 or insets.y < 0.0 or insets.z < 0.0 or insets.w < 0.0:
		return false
	_preview_safe_insets = insets
	_has_preview_safe_insets = true
	if is_node_ready():
		_apply_layout()
	return true


func set_quit_callback(callback: Callable) -> bool:
	if is_inside_tree() or not callback.is_valid():
		return false
	_quit_callback = callback
	return true


func piece_state(color: String, index: int) -> Dictionary:
	if not _pieces.has(color) or index < 0 or index >= (_pieces[color] as Array).size():
		return {}
	return ((_pieces[color] as Array)[index] as Dictionary).duplicate()


func _apply_layout() -> void:
	var layout := layout_for_size(size, _safe_rect())
	if layout.is_empty():
		return
	_apply_rect($LeftRail, layout["left"])
	_apply_rect($Board, layout["board"])
	_apply_rect($RightRail, layout["right"])
	var rail_padding := float(GameboxTokens.SPACING["layout"]) * GameboxTheme.LOGICAL_SCALE
	var right_text_width := maxf(1.0, (layout["right"] as Rect2).size.x - rail_padding * 2.0)
	for label in [$RightRail/Content/TurnLabel, $RightRail/Content/HintLabel, $RightRail/Content/RuleLabel]:
		(label as Label).custom_maximum_size.x = right_text_width
	var compact := layout_is_compact(layout)
	$RightRail/Content/HintLabel.visible = not compact
	$LeftRail/Content/Eyebrow.visible = not compact
	$RightRail/Content/TurnLabel.theme_type_variation = &"FlightChessTurnCompact" if compact else &"FlightChessTurn"
	$RightRail/Content/RuleLabel.theme_type_variation = &"FlightChessRuleCompact" if compact else &"FlightChessRule"
	$RightRail/Content/DiceCard.custom_minimum_size.y = 136.0 if compact else 200.0
	$RightRail/Content/DiceCard/Content/Dice.custom_minimum_size = Vector2(112.0, 112.0) if compact else Vector2(168.0, 168.0)


func _safe_rect() -> Rect2:
	if _has_preview_safe_insets:
		return Rect2(
			Vector2(_preview_safe_insets.x, _preview_safe_insets.y),
			size - Vector2(_preview_safe_insets.x + _preview_safe_insets.z, _preview_safe_insets.y + _preview_safe_insets.w),
		)
	if OS.has_feature("android"):
		var display_safe := DisplayServer.get_display_safe_area()
		var window_size := Vector2(DisplayServer.window_get_size())
		if display_safe.has_area() and window_size.x > 0.0 and window_size.y > 0.0:
			var insets := Vector4(
				float(display_safe.position.x),
				float(display_safe.position.y),
				window_size.x - float(display_safe.end.x),
				window_size.y - float(display_safe.end.y),
			)
			var logical_insets := physical_insets_to_logical(insets, window_size, size)
			return Rect2(
				Vector2(logical_insets.x, logical_insets.y),
				size - Vector2(logical_insets.x + logical_insets.z, logical_insets.y + logical_insets.w),
			)
	return Rect2(Vector2.ZERO, size)


func _apply_rect(control: Control, rect: Rect2) -> void:
	control.position = rect.position
	control.size = rect.size


func _reset_demo() -> void:
	_pieces = {
		"yellow": [
			{"zone": "hangar", "index": 0}, {"zone": "hangar", "index": 1},
			{"zone": "main", "index": 6}, {"zone": "main", "index": 17},
		],
		"red": [
			{"zone": "hangar", "index": 0}, {"zone": "hangar", "index": 1},
			{"zone": "hangar", "index": 2}, {"zone": "main", "index": 30},
		],
	}
	_dice_value = 0
	_roll_cursor = 0
	_selectable_indices.clear()
	_selected_index = -1
	_status_text = "你的回合"
	_turn_text = "先掷骰子"
	_hint_text = "掷出 6 后，再选择一架飞机起飞"


func _apply_preview_state() -> void:
	match _preview_state:
		"rolled": _show_rolled_six()
		"pressed": _show_rolled_six()
		"selected":
			_show_rolled_six()
			_selected_index = 0
		"stacked":
			(_pieces["red"] as Array)[2] = {"zone": "main", "index": 30}
			(_pieces["red"] as Array)[3] = {"zone": "main", "index": 30}
			_dice_value = 4
			_selectable_indices = [2, 3]
			_status_text = "掷出 4"
			_turn_text = "选择叠放飞机"
			_hint_text = "同格飞机以叠层和数量标记显示"
	_sync_ui()
	if _preview_state == "pressed":
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = true
		event.position = $Board.piece_center("red", 0)
		$Board._gui_input(event)


func _on_roll_pressed() -> void:
	if not _selectable_indices.is_empty():
		return
	_dice_value = DICE_SEQUENCE[_roll_cursor % DICE_SEQUENCE.size()]
	_roll_cursor += 1
	_selected_index = -1
	if _dice_value == 6:
		_selectable_indices = [0, 1, 2, 3]
		_status_text = "掷出 6"
		_turn_text = "选一架飞机"
		_hint_text = "选择任意红方飞机；机库中的飞机将进入起飞点"
	else:
		_selectable_indices = _movable_route_pieces()
		_status_text = "掷出 %d" % _dice_value
		_turn_text = "选择要移动的飞机" if not _selectable_indices.is_empty() else "本回合无法移动"
		_hint_text = "点选一架已起飞的飞机" if not _selectable_indices.is_empty() else "飞机仍在机库，等待下一次掷骰"
	_sync_ui()


func _show_rolled_six() -> void:
	_dice_value = 6
	_selectable_indices = [0, 1, 2, 3]
	_status_text = "掷出 6"
	_turn_text = "选一架飞机"
	_hint_text = "可起飞的红方飞机已高亮"


func _on_piece_pressed(color: String, index: int) -> void:
	if color != "red" or not _selectable_indices.has(index):
		return
	_selected_index = index
	var piece: Dictionary = (_pieces["red"] as Array)[index]
	var rolled_six := _dice_value == 6
	match piece["zone"]:
		"hangar":
			if not rolled_six:
				return
			piece = {"zone": "launch", "index": 0}
			_status_text = "起飞成功"
			_turn_text = "可以再掷一次"
			_hint_text = "掷出 6 会奖励额外一次掷骰"
		"launch":
			piece = {"zone": "main", "index": FlightChessBoard.PATH_STARTS["red"]}
			_status_text = "已进入主航线"
			_turn_text = "移动完成"
			_hint_text = "待联机规则接入后，这里将等待服务端确认"
		"main":
			piece = {"zone": "main", "index": (int(piece["index"]) + _dice_value) % 52}
			_status_text = "移动完成"
			_turn_text = "航程 +%d" % _dice_value
			_hint_text = "当前为本地视觉原型，未接入服务端权威状态"
		_:
			return
	(_pieces["red"] as Array)[index] = piece
	_dice_value = 0
	_selectable_indices.clear()
	_selected_index = -1
	_sync_ui()


func _movable_route_pieces() -> Array:
	var result: Array = []
	var red_pieces: Array = _pieces["red"]
	for index in red_pieces.size():
		if str((red_pieces[index] as Dictionary)["zone"]) != "hangar":
			result.append(index)
	return result


func _sync_ui() -> void:
	$Board.present(_pieces, "red", _selectable_indices, _selected_index, not _selectable_indices.is_empty())
	$RightRail/Content/DiceCard/Content/Dice.set_value(_dice_value)
	$RightRail/Content/StatusLabel.text = _status_text
	$RightRail/Content/TurnLabel.text = _turn_text
	$RightRail/Content/HintLabel.text = _hint_text
	$RightRail/Content/RollButton.disabled = not _selectable_indices.is_empty()
	$RightRail/Content/RollButton.text = "先选飞机" if not _selectable_indices.is_empty() else "掷骰子"
	$LeftRail/Content/OpponentCard/Content/Meta.text = _piece_summary("yellow")
	$LeftRail/Content/LocalCard/Content/Meta.text = _piece_summary("red")


func _piece_summary(color: String) -> String:
	var waiting := 0
	var flying := 0
	for piece in _pieces[color]:
		if piece["zone"] == "hangar": waiting += 1
		else: flying += 1
	return "%d 架在途 · %d 架待机" % [flying, waiting]


func _on_back_pressed() -> void:
	if _quit_callback.is_valid():
		_quit_callback.call()
	elif is_inside_tree():
		get_tree().quit()
