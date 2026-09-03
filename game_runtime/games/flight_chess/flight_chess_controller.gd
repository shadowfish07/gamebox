class_name FlightChessSceneController
extends Control

const FlightChessTheme = preload("res://games/flight_chess/flight_chess_theme.gd")
const GameboxTheme = preload("res://design_system/gamebox_theme.gd")

const MIN_VIEWPORT := Vector2(960.0, 540.0)
const MIN_RAIL_WIDTH := 200.0
const MAX_RAIL_WIDTH := 380.0
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
var _quit_callback := Callable()


func _ready() -> void:
	var dark := bool(_preview_dark) if _preview_dark is bool else GameboxTheme.system_prefers_dark()
	theme = FlightChessTheme.create(dark)
	$LeftRail/Content/BackButton.pressed.connect(_on_back_pressed)
	$RightRail/Content/RollButton.pressed.connect(_on_roll_pressed)
	$Board.piece_pressed.connect(_on_piece_pressed)
	_reset_demo()
	_apply_preview_state()
	_apply_layout()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and is_node_ready():
		_apply_layout()
	elif what == Node.NOTIFICATION_WM_GO_BACK_REQUEST:
		_on_back_pressed()


func _unhandled_key_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and not event.is_echo():
		get_viewport().set_input_as_handled()
		_on_back_pressed()


static func layout_for_size(viewport: Vector2) -> Dictionary:
	if viewport.x < MIN_VIEWPORT.x or viewport.y < MIN_VIEWPORT.y or viewport.x <= viewport.y:
		return {}
	var margin := clampf(viewport.y * 0.035, 24.0, 40.0)
	var gap := clampf(viewport.y * 0.024, 16.0, 28.0)
	var available := viewport - Vector2(margin * 2.0, margin * 2.0)
	var board_side := minf(available.y, available.x - MIN_RAIL_WIDTH * 2.0 - gap * 2.0)
	if board_side <= 0.0:
		return {}
	var rail_width := clampf((available.x - board_side - gap * 2.0) * 0.5, MIN_RAIL_WIDTH, MAX_RAIL_WIDTH)
	var total_width := board_side + rail_width * 2.0 + gap * 2.0
	var origin_x := (viewport.x - total_width) * 0.5
	var origin_y := (viewport.y - board_side) * 0.5
	return {
		"left": Rect2(origin_x, origin_y, rail_width, board_side),
		"board": Rect2(origin_x + rail_width + gap, origin_y, board_side, board_side),
		"right": Rect2(origin_x + rail_width + gap * 2.0 + board_side, origin_y, rail_width, board_side),
	}


func set_preview_state(state: String) -> bool:
	if state not in ["ready", "rolled", "selected"]:
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
	var layout := layout_for_size(size)
	if layout.is_empty():
		return
	_apply_rect($LeftRail, layout["left"])
	_apply_rect($Board, layout["board"])
	_apply_rect($RightRail, layout["right"])
	var compact := size.y < 650.0 or (layout["right"] as Rect2).size.x < 230.0
	$RightRail/Content/HintLabel.visible = not compact
	$RightRail/Content/TurnLabel.theme_type_variation = &"FlightChessTurnCompact" if compact else &"FlightChessTurn"
	$RightRail/Content/RuleLabel.theme_type_variation = &"FlightChessRuleCompact" if compact else &"FlightChessRule"
	$RightRail/Content/DiceCard/Content/Dice.custom_minimum_size = Vector2(120.0, 120.0) if compact else Vector2(160.0, 160.0)


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
		"selected":
			_show_rolled_six()
			_selected_index = 0
	_sync_ui()


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
