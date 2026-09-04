class_name FlightChessSceneController
extends Control

const LaunchConfig = preload("res://core/launch_config.gd")
const MatchClient = preload("res://core/match_client.gd")
const FlightChessState = preload("res://games/flight_chess/flight_chess_state.gd")
const FlightChessTheme = preload("res://games/flight_chess/flight_chess_theme.gd")
const FlightChessBoard = preload("res://games/flight_chess/flight_chess_board.gd")
const GameboxTheme = preload("res://design_system/gamebox_theme.gd")
const GameboxTokens = preload("res://design_system/generated/gamebox_tokens.gd")

const MIN_VIEWPORT := Vector2(960.0, 540.0)
const LANDSCAPE_CONTENT_SCALE := Vector2i(1920, 1080)
const MIN_RAIL_WIDTH := 192.0
const MAX_RAIL_WIDTH := 360.0
const DICE_SEQUENCE := [6, 4, 2, 5, 3, 1]
const TERMINAL_STATUSES := ["finished", "cancelled", "abandoned"]
const SAFE_ERROR_COPY := {
	"ticket_invalid": "登录状态已失效，请返回大厅",
	"resume_expired": "登录状态已失效，请返回大厅",
	"stale_revision": "棋盘已更新，正在同步",
	"action_conflict": "操作冲突，请重试",
	"not_your_turn": "还没轮到你",
	"invalid_move": "这架飞机现在不能移动",
	"invalid_request": "操作无效，请重试",
	"match_not_found": "对局不存在，请返回大厅",
	"internal_error": "服务暂时不可用，请稍后重试",
	"connection_failed": "连接失败，请返回大厅",
}

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
var _launch_config := {}
var _match_client_factory := Callable()
var _state: Variant
var _client: Variant
var _match_id := ""
var _connection_state := "connecting"
var _awaiting_snapshot := true
var _started := false
var _disposed := false
var _returning := false
var _force_return := false
var _resign_submitted := false
var _error_text := ""
var _presented_result_signature := ""
var _logged_state_signature := ""
var _ready_marker_callback := Callable()


func configure_launch(config: Dictionary) -> bool:
	if is_inside_tree() or not _launch_config.is_empty() or not _validated_config(config).get("ok", false):
		return false
	_launch_config = config.duplicate(true)
	return true


func set_match_client_factory(factory: Callable) -> bool:
	if is_inside_tree() or not factory.is_valid():
		return false
	_match_client_factory = factory
	return true


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
	_dispose_client()
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
	$LeftRail/Content/ResignButton.pressed.connect(_on_resign_pressed)
	$RightRail/Content/RollButton.pressed.connect(_on_roll_pressed)
	$Board.piece_pressed.connect(_on_piece_pressed)
	$ConnectionLabel.return_requested.connect(_on_back_pressed)
	$ResignDialog.confirmed.connect(_on_resign_confirmed)
	$ResultPanel.return_requested.connect(_on_back_pressed)
	var colors: Dictionary = GameboxTokens.DARK if dark else GameboxTokens.LIGHT
	$ResultScrim.color = Color(colors["scrim"], GameboxTokens.COMPONENT["dialog_scrim_opacity"])
	_reset_demo()
	if _launch_config.is_empty():
		_apply_preview_state()
		$LeftRail/Content/ResignButton.visible = false
	else:
		_start_network_game()
	_finish_initial_layout.call_deferred()


func _process(_delta: float) -> void:
	if _started and not _disposed:
		_client.poll()


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


func automation_targets() -> Dictionary:
	var viewport_rect := get_viewport().get_visible_rect()
	if not viewport_rect.has_area() or not is_node_ready():
		return {}
	var board := $Board as Control
	var roll_button := $RightRail/Content/RollButton as Control
	var resign_button := $LeftRail/Content/ResignButton as Control
	var confirm_button := $ResignDialog/Dialog/Content/Actions/ConfirmButton as Control
	return {
		"roll": _normalized_point(roll_button.get_global_transform_with_canvas() * (roll_button.size * 0.5), viewport_rect),
		"red0": _normalized_point(board.get_global_transform_with_canvas() * board.piece_center("red", 0), viewport_rect),
		"yellow0": _normalized_point(board.get_global_transform_with_canvas() * board.piece_center("yellow", 0), viewport_rect),
		"resign": _normalized_point(resign_button.get_global_transform_with_canvas() * (resign_button.size * 0.5), viewport_rect),
		"confirm": _normalized_point(confirm_button.get_global_transform_with_canvas() * (confirm_button.size * 0.5), viewport_rect),
	}


static func _normalized_point(point: Vector2, bounds: Rect2) -> Vector2:
	return Vector2(
		clampf((point.x - bounds.position.x) / bounds.size.x, 0.0, 1.0),
		clampf((point.y - bounds.position.y) / bounds.size.y, 0.0, 1.0),
	)


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
	if _started:
		if _can_roll() and not _client.request_flight_chess_roll().is_empty():
			_error_text = ""
		else:
			_error_text = "暂时无法掷骰子，请重试"
		_sync_ui()
		return
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
	if _started:
		if color != _local_board_color() or not _selectable_indices.has(index):
			return
		_selected_index = index
		_sync_ui()
		if _client.request_flight_chess_move(index).is_empty():
			_selected_index = -1
			_error_text = "操作失败，请重试"
		else:
			_error_text = ""
		_sync_ui()
		return
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
	if _started or not _launch_config.is_empty():
		_sync_network_ui()
		return
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
	if $ResignDialog.visible:
		$ResignDialog.close()
		return
	if _returning:
		return
	_returning = true
	_dispose_client()
	if _quit_callback.is_valid():
		_quit_callback.call()
	elif is_inside_tree():
		get_tree().quit()


func _start_network_game() -> void:
	var resolved := _validated_config(_launch_config)
	if not resolved.get("ok", false):
		_show_start_failure()
		return
	var config: Dictionary = resolved["config"]
	_match_id = config["match_id"]
	_state = FlightChessState.new(_match_id)
	_client = _match_client_factory.call() if _match_client_factory.is_valid() else MatchClient.new()
	if not _valid_client(_client):
		config["launch_ticket"] = ""
		_launch_config.clear()
		_show_start_failure()
		return
	_connect_client_signals()
	var started: bool = _client.start(config["ws_url"], _match_id, config["launch_ticket"], _state, "flight_chess")
	config["launch_ticket"] = ""
	_launch_config.clear()
	if not started:
		_show_start_failure()
		return
	_started = true
	_connection_state = _client.connection_state
	$LeftRail/Content/ResignButton.visible = true
	set_process(true)
	_sync_ui()
	_schedule_ready_marker()


func _on_connection_state_changed(next_state: String) -> void:
	if next_state not in ["connecting", "connected", "reconnecting", "failed", "closed"]:
		return
	_connection_state = next_state
	if next_state != "connected":
		_awaiting_snapshot = true
		_selected_index = -1
	_sync_ui()


func _on_snapshot_sync_started() -> void:
	_awaiting_snapshot = true
	_selected_index = -1
	_sync_ui()


func _on_snapshot_received(envelope: Dictionary) -> void:
	if _state == null:
		return
	var applied: Dictionary = _state.apply_snapshot(envelope)
	if not applied.get("ok", false):
		_error_text = "同步失败，请返回大厅"
		_force_return = true
	else:
		_awaiting_snapshot = false
		_resign_submitted = false
		_selected_index = -1
		_error_text = ""
	_sync_ui()


func _on_event_received(envelope: Dictionary) -> void:
	if _state == null:
		return
	var applied: Dictionary = _state.apply_event(envelope)
	if not applied.get("ok", false):
		_error_text = "同步失败，请返回大厅"
		_force_return = true
	_selected_index = -1
	_sync_ui()


func _on_player_presence_changed(_user_id: String, _online: bool) -> void:
	_sync_ui()


func _on_match_error(code: String) -> void:
	_error_text = str(SAFE_ERROR_COPY.get(code, "操作失败，请稍后重试"))
	_resign_submitted = false
	_selected_index = -1
	if code == "stale_revision":
		_awaiting_snapshot = true
	_sync_ui()


func _on_return_to_lobby_requested(code: String) -> void:
	_error_text = str(SAFE_ERROR_COPY.get(code, "连接失败，请返回大厅"))
	_force_return = true
	_selected_index = -1
	_sync_ui()


func _on_resign_pressed() -> void:
	if _can_offer_resign():
		$ResignDialog.open()
		RenderingServer.frame_post_draw.connect(_log_resign_confirm_target, CONNECT_ONE_SHOT)


func _on_resign_confirmed() -> void:
	if not _can_offer_resign() or _resign_submitted:
		return
	_resign_submitted = true
	if _client.request_resign().is_empty():
		_resign_submitted = false
		_error_text = "操作失败，请重试"
	_sync_ui()


func _sync_network_ui() -> void:
	var has_state: bool = _state != null and _state.revision >= 0
	if has_state:
		_pieces = _state.visual_pieces()
		_dice_value = _state.dice
	else:
		_pieces = _empty_visual_pieces()
		_dice_value = 0
	var local_board_color := _local_board_color()
	_selectable_indices = _state.movable_piece_indices() if _can_select_piece() else []
	if not _selectable_indices.has(_selected_index):
		_selected_index = -1
	$Board.present(_pieces, local_board_color, _selectable_indices, _selected_index, not _selectable_indices.is_empty())
	$RightRail/Content/DiceCard/Content/Dice.set_value(_dice_value)
	$RightRail/Content/StatusLabel.text = _network_status_text(has_state)
	$RightRail/Content/TurnLabel.text = _network_turn_text(has_state)
	$RightRail/Content/HintLabel.text = _network_hint_text(has_state)
	$RightRail/Content/RollButton.disabled = not _can_roll()
	$RightRail/Content/RollButton.text = "确认中…" if has_state and _state.pending_action.get("type") == "flight_chess.roll.requested" else "掷骰子"
	$LeftRail/Content/ResignButton.disabled = not _can_offer_resign()
	$ConnectionLabel.present(_connection_banner_state(), _error_text if _force_return else "")
	$ErrorLabel.present("" if _force_return else _error_text, "error")
	if has_state:
		var opponent_board_color := "yellow" if local_board_color == "red" else "red"
		$LeftRail/Content/LocalCard.theme_type_variation = &"FlightChessRedCard" if local_board_color == "red" else &"FlightChessYellowCard"
		$LeftRail/Content/OpponentCard.theme_type_variation = &"FlightChessYellowCard" if opponent_board_color == "yellow" else &"FlightChessRedCard"
		$LeftRail/Content/LocalCard/Content/Role.text = "你 · %s方" % ("红" if local_board_color == "red" else "黄")
		$LeftRail/Content/OpponentCard/Content/Role.text = "对手 · %s方" % ("黄" if opponent_board_color == "yellow" else "红")
		$LeftRail/Content/LocalCard/Content/Meta.text = _piece_summary(local_board_color)
		$LeftRail/Content/OpponentCard/Content/Meta.text = _piece_summary(opponent_board_color)
		$LeftRail/Content/OpponentCard/Content/Name.text = _opponent_presence_text()
	_present_terminal_result(has_state)
	_log_runtime_state()


func _network_status_text(has_state: bool) -> String:
	if not has_state:
		return "连接对局"
	if _state.status in TERMINAL_STATUSES:
		return "对局结束"
	if not _state.pending_action.is_empty():
		return "等待服务器确认"
	return "你的回合" if _local_platform_color() == _state.next_color else "对手回合"


func _network_turn_text(has_state: bool) -> String:
	if not has_state:
		return "正在同步棋盘"
	if _state.status in TERMINAL_STATUSES:
		return "结果已确认"
	if _state.pending_action.get("type") == "flight_chess.roll.requested":
		return "正在生成骰点"
	if _state.pending_action.get("type") == "flight_chess.move.requested":
		return "正在确认走子"
	if _local_platform_color() != _state.next_color:
		return "等待对手"
	return "选一架飞机" if _state.phase == "awaiting_move" else "请掷骰子"


func _network_hint_text(has_state: bool) -> String:
	if not has_state or _awaiting_snapshot or _connection_state != "connected":
		return "棋盘会保留，恢复同步后继续"
	if _state.status in TERMINAL_STATUSES:
		return "结果已由服务器确认"
	if not _state.pending_action.is_empty():
		return "操作已提交，棋盘将在确认后更新"
	if _local_platform_color() != _state.next_color:
		return "对手正在%s" % ("选择飞机" if _state.phase == "awaiting_move" else "掷骰子")
	if _state.phase == "awaiting_move":
		return "掷出 %d，可移动的飞机已高亮" % _state.dice
	return "掷出 6 可起飞，并奖励再掷一次"


func _present_terminal_result(has_state: bool) -> void:
	if not has_state or _state.status not in TERMINAL_STATUSES:
		_presented_result_signature = ""
		$ResultPanel.present_details({})
		$ResultScrim.visible = false
		return
	$ResignDialog.close()
	var signature := "%d|%s|%s" % [_state.revision, _state.status, str(_state.result)]
	if signature == _presented_result_signature:
		return
	_presented_result_signature = signature
	var local_won: bool = _state.winner_user_id == _client.local_user_id
	var details := {}
	if _state.status == "cancelled":
		details = {"outcome": "cancelled", "title": "对局已取消", "support": "本局不会计入结果。", "review_available": false}
	elif _state.status == "abandoned":
		details = {"outcome": "abandoned", "title": "对局已作废", "support": "本局不会计入结果。", "review_available": false}
	elif _state.result == "resignation":
		details = {
			"outcome": "won" if local_won else "lost",
			"outcome_label": "胜利" if local_won else "认输",
			"title": "对手已认输" if local_won else "你已认输",
			"support": "飞行棋终局已由服务器确认。",
			"summary": [{"value": "%d 次" % max(_state.revision - 1, 0), "label": "已确认操作"}],
			"review_available": false,
		}
	else:
		details = {
			"outcome": "won" if local_won else "lost",
			"title": "全员抵达" if local_won else "这局差一点",
			"support": "四架飞机已全部抵达终点。" if local_won else "对手率先完成了航程。",
			"summary": [{"value": "%d 次" % _state.revision, "label": "已确认操作"}],
			"review_available": false,
		}
	$ResultPanel.present_details(details)
	$ResultScrim.visible = true
	print("GAMEBOX_MATCH_RESULT match=%s result=%s" % [_match_id, str(_state.result)])


func _can_roll() -> bool:
	return _started and not _disposed and not _awaiting_snapshot and _connection_state == "connected" \
		and _state != null and _state.can_request_roll(_client.local_user_id)


func _can_select_piece() -> bool:
	return _started and not _disposed and not _awaiting_snapshot and _connection_state == "connected" \
		and _state != null and _state.status == "active" and _state.phase == "awaiting_move" \
		and _state.pending_action.is_empty() and _local_platform_color() == _state.next_color


func _can_offer_resign() -> bool:
	return _started and not _disposed and not _awaiting_snapshot and not _resign_submitted \
		and _connection_state == "connected" and _state != null \
		and _state.can_request_resign(_client.local_user_id)


func _local_platform_color() -> String:
	if _state == null or _client == null:
		return ""
	if _client.local_user_id == _state.black_user_id:
		return "black"
	if _client.local_user_id == _state.white_user_id:
		return "white"
	return ""


func _local_board_color() -> String:
	return "red" if _local_platform_color() == "black" else "yellow" if _local_platform_color() == "white" else ""


func _opponent_presence_text() -> String:
	if _connection_state != "connected" or _awaiting_snapshot:
		return "状态未知"
	var opponent_id: String = _state.white_user_id if _local_platform_color() == "black" else _state.black_user_id
	if opponent_id.is_empty() or not _client.has_player_presence(opponent_id):
		return "状态未知"
	return "在线" if _client.is_player_online(opponent_id) else "离线"


func _connection_banner_state() -> String:
	if _force_return:
		return "failed"
	if _connection_state in ["failed", "closed", "reconnecting"]:
		return _connection_state
	if _awaiting_snapshot:
		return "syncing" if _connection_state == "connected" else "connecting"
	return "connected"


func _connect_client_signals() -> void:
	_client.connection_state_changed.connect(_on_connection_state_changed)
	_client.snapshot_sync_started.connect(_on_snapshot_sync_started)
	_client.snapshot_received.connect(_on_snapshot_received)
	_client.event_received.connect(_on_event_received)
	_client.player_presence_changed.connect(_on_player_presence_changed)
	_client.match_error.connect(_on_match_error)
	_client.return_to_lobby_requested.connect(_on_return_to_lobby_requested)


func _disconnect_client_signals() -> void:
	if _client == null:
		return
	for pair in [
		["connection_state_changed", _on_connection_state_changed],
		["snapshot_sync_started", _on_snapshot_sync_started],
		["snapshot_received", _on_snapshot_received],
		["event_received", _on_event_received],
		["player_presence_changed", _on_player_presence_changed],
		["match_error", _on_match_error],
		["return_to_lobby_requested", _on_return_to_lobby_requested],
	]:
		var signal_value: Signal = _client.get(pair[0])
		if signal_value.is_connected(pair[1]):
			signal_value.disconnect(pair[1])


func _dispose_client() -> void:
	if _disposed:
		return
	_disposed = true
	set_process(false)
	if _ready_marker_callback.is_valid() and RenderingServer.frame_post_draw.is_connected(_ready_marker_callback):
		RenderingServer.frame_post_draw.disconnect(_ready_marker_callback)
	_ready_marker_callback = Callable()
	_disconnect_client_signals()
	if _client != null and _client.has_method("dispose"):
		_client.dispose()


func _show_start_failure() -> void:
	_launch_config.clear()
	_error_text = "无法进入对局，请返回大厅"
	_connection_state = "failed"
	_force_return = true
	set_process(false)
	_sync_network_ui()


func _schedule_ready_marker() -> void:
	_ready_marker_callback = func() -> void:
		_ready_marker_callback = Callable()
		if not _disposed and not _returning and is_inside_tree():
			print("GAMEBOX_GODOT_READY game=flight_chess match=%s" % _match_id)
	RenderingServer.frame_post_draw.connect(_ready_marker_callback, CONNECT_ONE_SHOT)


func _log_automation_targets() -> void:
	var targets := automation_targets()
	if _match_id.is_empty() or targets.size() != 5:
		return
	print("GAMEBOX_FLIGHT_CHESS_TARGETS match=%s roll=%.6f,%.6f red0=%.6f,%.6f yellow0=%.6f,%.6f resign=%.6f,%.6f confirm=%.6f,%.6f" % [
		_match_id,
		(targets["roll"] as Vector2).x, (targets["roll"] as Vector2).y,
		(targets["red0"] as Vector2).x, (targets["red0"] as Vector2).y,
		(targets["yellow0"] as Vector2).x, (targets["yellow0"] as Vector2).y,
		(targets["resign"] as Vector2).x, (targets["resign"] as Vector2).y,
		(targets["confirm"] as Vector2).x, (targets["confirm"] as Vector2).y,
	])


func _log_resign_confirm_target() -> void:
	if _disposed or _returning or _match_id.is_empty() or not $ResignDialog.visible:
		return
	var target: Vector2 = automation_targets().get("confirm", Vector2.ZERO)
	if target == Vector2.ZERO:
		return
	print("GAMEBOX_FLIGHT_CHESS_CONFIRM_TARGET match=%s confirm=%.6f,%.6f" % [
		_match_id, target.x, target.y,
	])


func _validated_config(config: Dictionary) -> Dictionary:
	if config.size() != 4:
		return {"ok": false}
	for key in config:
		if key not in ["game_id", "match_id", "launch_ticket", "ws_url"] or not config[key] is String:
			return {"ok": false}
	return LaunchConfig.parse(PackedStringArray([
		"--game-id", config["game_id"], "--match-id", config["match_id"],
		"--launch-ticket", config["launch_ticket"], "--ws-url", config["ws_url"],
	]))


func _valid_client(client: Variant) -> bool:
	if client == null:
		return false
	for method in ["start", "poll", "request_flight_chess_roll", "request_flight_chess_move", "request_resign", "dispose"]:
		if not client.has_method(method):
			return false
	for signal_name in ["connection_state_changed", "snapshot_sync_started", "snapshot_received", "event_received", "player_presence_changed", "match_error", "return_to_lobby_requested"]:
		if not client.has_signal(signal_name):
			return false
	return true


func _log_runtime_state() -> void:
	if _match_id.is_empty():
		return
	var revision_value: int = -1 if _state == null else _state.revision
	var status_value: String = "loading" if _state == null or _state.revision < 0 else _state.status
	var phase_value: String = "?" if _state == null or _state.revision < 0 else _state.phase
	var pending_value: bool = _state != null and not _state.pending_action.is_empty()
	var signature := "%d|%s|%s|%s|%s" % [revision_value, status_value, _connection_state, phase_value, str(pending_value)]
	if signature == _logged_state_signature:
		return
	_logged_state_signature = signature
	print("GAMEBOX_GODOT_STATE match=%s revision=%d status=%s connection=%s" % [
		_match_id, revision_value, status_value, _connection_state,
	])
	print("GAMEBOX_FLIGHT_CHESS_STATE match=%s revision=%d status=%s connection=%s phase=%s" % [
		_match_id, revision_value, status_value, _connection_state,
		phase_value,
	])
	print("GAMEBOX_FLIGHT_CHESS_PENDING match=%s revision=%d pending=%s" % [_match_id, revision_value, str(pending_value)])
	if revision_value >= 0 and _connection_state == "connected":
		_log_automation_targets()


static func _empty_visual_pieces() -> Dictionary:
	var result := {"red": [], "yellow": []}
	for color in result:
		for index in 4:
			result[color].append({"zone": "hangar", "index": index})
	return result
