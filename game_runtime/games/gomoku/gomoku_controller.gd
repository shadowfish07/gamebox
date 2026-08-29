extends Control

const LaunchConfig = preload("res://core/launch_config.gd")
const MatchClient = preload("res://core/match_client.gd")
const GomokuState = preload("res://games/gomoku/gomoku_state.gd")
const GomokuBoard = preload("res://games/gomoku/gomoku_board.gd")
const GomokuPreferences = preload("res://games/gomoku/gomoku_preferences.gd")
const GameboxTheme = preload("res://design_system/gamebox_theme.gd")
const GameboxTokens = preload("res://design_system/generated/gamebox_tokens.gd")

const INVALID_CELL := Vector2i(-1, -1)
const TERMINAL_STATUSES := ["finished", "cancelled", "abandoned"]
const SAFE_ERROR_COPY := {
	"ticket_invalid": "登录状态已失效，请返回大厅",
	"resume_expired": "登录状态已失效，请返回大厅",
	"stale_revision": "棋盘已更新，正在同步",
	"action_conflict": "操作冲突，请重试",
	"not_your_turn": "还没轮到你",
	"cell_occupied": "这个位置已经有棋子",
	"invalid_request": "操作无效，请重试",
	"match_not_found": "对局不存在，请返回大厅",
	"internal_error": "服务暂时不可用，请稍后重试",
	"connection_failed": "连接失败，请返回大厅",
}

const GO_BACK_DEBOUNCE_MS := 150

var ready_marker_emitted: bool:
	get:
		return _ready_marker_emitted
	set(_value):
		pass

var ready_marker_text: String:
	get:
		return _ready_marker_text
	set(_value):
		pass

var _launch_config := {}
var _match_client_factory := Callable()
var _quit_callback := Callable()
var _frame_ready_gate: Variant
var _preferences_store: Variant
var _state: Variant
var _client: Variant
var _match_id := ""
var _connection_state := "connecting"
var _error_text := ""
var _last_move := INVALID_CELL
var _disposed := false
var _returning := false
var _started := false
var _force_return := false
var _awaiting_snapshot := true
var _last_log_signature := ""
var _reported_terminal_signature := ""
var _ready_marker_generation := 0
var _ready_marker_callback := Callable()
var _ready_marker_emitted := false
var _ready_marker_text := ""
var _resign_submitted := false
var _confirm_move_enabled := false
var _selected_move := INVALID_CELL
var _last_go_back_time_ms := -100000
var _go_back_debounce_ms := GO_BACK_DEBOUNCE_MS
var _reviewing_result := false
var _presented_result_signature := ""


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


func set_quit_callback(callback: Callable) -> bool:
	if is_inside_tree() or not callback.is_valid():
		return false
	_quit_callback = callback
	return true


func set_frame_ready_gate(gate: Variant) -> bool:
	if is_inside_tree() or gate == null or not gate.has_method("schedule") or not gate.has_method("cancel"):
		return false
	_frame_ready_gate = gate
	return true


func set_preferences_store(store: Variant) -> bool:
	if is_inside_tree() or store == null \
		or not store.has_method("load_confirm_move") or not store.has_method("save_confirm_move"):
		return false
	_preferences_store = store
	return true


func _ready() -> void:
	var dark_theme := GameboxTheme.system_prefers_dark()
	theme = GameboxTheme.create(dark_theme)
	var colors: Dictionary = GameboxTokens.DARK if dark_theme else GameboxTokens.LIGHT
	$ResultScrim.color = Color(colors["scrim"], GameboxTokens.COMPONENT["dialog_scrim_opacity"])
	if _preferences_store == null:
		_preferences_store = GomokuPreferences.new()
	_confirm_move_enabled = _preferences_store.load_confirm_move()
	$Board.cell_pressed.connect(_on_cell_pressed)
	$TopNavigation.back_requested.connect(_on_back_pressed)
	$TopNavigation.set_menu_items([
		{"id": "settings", "label": "对局设置"},
		{"id": "resign", "label": "认输", "danger": true},
	])
	$TopNavigation.menu_action_requested.connect(_on_menu_action_requested)
	$SettingsSheet/Sheet/Content/MoveConfirmationToggle.toggled.connect(_on_move_confirmation_toggled)
	$SettingsSheet/Sheet/Content/DoneButton.pressed.connect(_on_settings_done_pressed)
	$MoveConfirmationBar/Content/Actions/CancelButton.pressed.connect(_on_move_cancel_pressed)
	$MoveConfirmationBar/Content/Actions/ConfirmButton.pressed.connect(_on_move_confirm_pressed)
	$ResignDialog.confirmed.connect(_on_resign_confirmed)
	$ResultPanel.return_requested.connect(_on_back_pressed)
	$ResultPanel.review_requested.connect(_on_result_review_requested)
	$ResultPill.pressed.connect(_on_result_pill_pressed)
	$ConnectionLabel.return_requested.connect(_on_back_pressed)
	_refresh_ui()

	var resolved := _resolve_launch_config()
	if not resolved.get("ok", false):
		_show_start_failure()
		return
	var config: Dictionary = resolved["config"]
	_match_id = config["match_id"]
	_state = GomokuState.new(_match_id)
	_client = _match_client_factory.call() if _match_client_factory.is_valid() else MatchClient.new()
	if not _valid_client(_client):
		config["launch_ticket"] = ""
		_launch_config.clear()
		_show_start_failure()
		return
	_connect_client_signals()
	var started: bool = _client.start(config["ws_url"], _match_id, config["launch_ticket"], _state)
	config["launch_ticket"] = ""
	_launch_config.clear()
	if not started:
		_show_start_failure()
		return
	_started = true
	_connection_state = _client.connection_state
	set_process(true)
	_refresh_ui()
	_schedule_ready_marker()


func _process(_delta: float) -> void:
	if _started and not _disposed:
		_client.poll()


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		print("GAMEBOX_INPUT_TOUCH index=%d pressed=%s pos=%s" % [event.index, event.pressed, event.position])


func _exit_tree() -> void:
	print("GAMEBOX_GODOT_BACK exit_tree returning=%s" % str(_returning))
	_dispose_client()


func _on_cell_pressed(x: int, y: int) -> void:
	var can_request: bool = _state != null and _state.can_request_move(x, y, _client.local_user_id)
	print("GAMEBOX_BOARD_CELL x=%d y=%d started=%s disposed=%s await_snap=%s state=%s can=%s conn=%s" \
		% [x, y, _started, _disposed, _awaiting_snapshot, _state != null, can_request, _connection_state])
	if not _started or _disposed or _awaiting_snapshot or _state == null \
		or not _state.can_request_move(x, y, _client.local_user_id):
		return
	if _confirm_move_enabled:
		_selected_move = Vector2i(x, y)
		_error_text = ""
		print("GAMEBOX_MOVE_SELECTION state=selected x=%d y=%d" % [x, y])
		_refresh_ui()
		return
	_request_selected_move(Vector2i(x, y))


func _request_selected_move(cell: Vector2i) -> void:
	var result: String = _client.request_move(cell.x, cell.y)
	print("GAMEBOX_BOARD_MOVE x=%d y=%d result=%s" % [cell.x, cell.y, result])
	if not result.is_empty():
		_selected_move = INVALID_CELL
		_error_text = ""
		_refresh_ui()
	else:
		_error_text = "操作失败，请重试"
		_refresh_ui()


func _on_move_cancel_pressed() -> void:
	if _selected_move == INVALID_CELL:
		return
	print("GAMEBOX_MOVE_SELECTION state=cancelled x=%d y=%d" % [_selected_move.x, _selected_move.y])
	_selected_move = INVALID_CELL
	_refresh_ui()


func _on_move_confirm_pressed() -> void:
	if _selected_move == INVALID_CELL or not _can_request_selected_move():
		return
	_request_selected_move(_selected_move)


func _on_settings_pressed() -> void:
	var toggle := $SettingsSheet/Sheet/Content/MoveConfirmationToggle as BaseButton
	toggle.set_pressed_no_signal(_confirm_move_enabled)
	$SettingsSheet.visible = true
	print("GAMEBOX_SETTINGS_SHEET visible=true")
	_refresh_ui()


func _on_menu_action_requested(action_id: String) -> void:
	match action_id:
		"settings":
			_on_settings_pressed()
		"resign":
			_on_resign_pressed()


func _on_settings_done_pressed() -> void:
	if not $SettingsSheet.visible:
		return
	$SettingsSheet.visible = false
	print("GAMEBOX_SETTINGS_SHEET visible=false")
	_refresh_ui()


func _on_move_confirmation_toggled(enabled: bool) -> void:
	var toggle := $SettingsSheet/Sheet/Content/MoveConfirmationToggle as BaseButton
	if not _preferences_store.save_confirm_move(enabled):
		toggle.set_pressed_no_signal(_confirm_move_enabled)
		_error_text = "设置保存失败，请重试"
		_refresh_ui()
		return
	_confirm_move_enabled = enabled
	toggle.set_pressed_no_signal(enabled)
	if not enabled:
		_selected_move = INVALID_CELL
	_error_text = ""
	print("GAMEBOX_MOVE_CONFIRMATION enabled=%s" % str(enabled))
	_refresh_ui()


func _on_resign_pressed() -> void:
	if not _can_offer_resign():
		return
	print("GAMEBOX_GODOT_BACK resign_dialog open")
	$ResignDialog.open()


func _on_resign_confirmed() -> void:
	if not _can_offer_resign() or _resign_submitted:
		return
	_resign_submitted = true
	if not _client.request_resign().is_empty():
		_error_text = ""
		_refresh_ui()
	else:
		_resign_submitted = false


func _on_back_pressed() -> void:
	if $TopNavigation.close_menu():
		return
	if $SettingsSheet.visible:
		_on_settings_done_pressed()
		return
	if $ResignDialog.visible:
		print("GAMEBOX_GODOT_BACK back_pressed hide_dialog")
		$ResignDialog.close()
		return
	if _returning:
		print("GAMEBOX_GODOT_BACK back_pressed already_returning")
		return
	_returning = true
	print("GAMEBOX_GODOT_BACK back_pressed quitting")
	_dispose_client()
	if _quit_callback.is_valid():
		_quit_callback.call()
	elif is_inside_tree():
		get_tree().quit()


func _notification(what: int) -> void:
	if what == Node.NOTIFICATION_WM_GO_BACK_REQUEST:
		# Android hardware Back is delivered as a go-back window event (the
		# raw Key::BACK input never maps to ui_cancel). Route it through the
		# same resign-dialog-aware handler as keyboard Escape.
		print("GAMEBOX_GODOT_BACK go_back_request dialog_visible=%s" % str($ResignDialog.visible))
		var now := Time.get_ticks_msec()
		if now - _last_go_back_time_ms < _go_back_debounce_ms:
			# Godot 4.7 forwards one physical Android Back press as two
			# GO_BACK_REQUEST notifications: the activity back dispatcher and
			# the render view's key event each send it, ~7ms apart. Acting on
			# both closes the resign dialog and quits in a single press, so
			# ignore the immediate duplicate — only a later, deliberate press
			# returns.
			print("GAMEBOX_GODOT_BACK go_back_duplicate_suppressed")
			return
		_last_go_back_time_ms = now
		_on_back_requested()


func _on_back_requested() -> void:
	if $TopNavigation.close_menu():
		print("GAMEBOX_GODOT_BACK branch=hide_menu")
	elif $SettingsSheet.visible:
		print("GAMEBOX_GODOT_BACK branch=hide_settings")
		_on_settings_done_pressed()
	elif $ResignDialog.visible:
		print("GAMEBOX_GODOT_BACK branch=hide_dialog")
		$ResignDialog.close()
	else:
		print("GAMEBOX_GODOT_BACK branch=quit_on_back")
		_on_back_pressed()


func _unhandled_key_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and not event.is_echo():
		get_viewport().set_input_as_handled()
		_on_back_requested()


func _on_connection_state_changed(next_state: String) -> void:
	if next_state not in ["connecting", "connected", "reconnecting", "failed", "closed"]:
		return
	_connection_state = next_state
	if next_state in ["connecting", "reconnecting", "failed", "closed"]:
		_awaiting_snapshot = true
		_selected_move = INVALID_CELL
	_refresh_ui()


func _on_snapshot_sync_started() -> void:
	_awaiting_snapshot = true
	_selected_move = INVALID_CELL
	_refresh_ui()


func _on_snapshot_received(envelope: Dictionary) -> void:
	if _state == null:
		return
	_selected_move = INVALID_CELL
	var applied: Dictionary = _state.apply_snapshot(envelope)
	if not applied.get("ok", false):
		_error_text = "同步失败，请返回大厅"
		_force_return = true
	elif applied.get("status") == "applied":
		_error_text = ""
		_resign_submitted = false
		_awaiting_snapshot = false
		_last_move = INVALID_CELL
	_refresh_ui()


func _on_event_received(envelope: Dictionary) -> void:
	if _state == null:
		return
	_selected_move = INVALID_CELL
	var applied: Dictionary = _state.apply_event(envelope)
	if not applied.get("ok", false):
		_error_text = "同步失败，请返回大厅"
		_force_return = true
	elif envelope.get("type") == "gomoku.move.accepted":
		var payload: Dictionary = envelope.get("payload", {})
		if typeof(payload.get("x")) == TYPE_INT and typeof(payload.get("y")) == TYPE_INT:
			_last_move = Vector2i(payload["x"], payload["y"])
	_refresh_ui()


func _on_player_presence_changed(_user_id: String, _online: bool) -> void:
	_refresh_ui()


func _on_match_error(code: String) -> void:
	_error_text = str(SAFE_ERROR_COPY.get(code, "操作失败，请稍后重试"))
	_resign_submitted = false
	_selected_move = INVALID_CELL
	if code == "stale_revision":
		_awaiting_snapshot = true
	_refresh_ui()


func _on_return_to_lobby_requested(code: String) -> void:
	_error_text = str(SAFE_ERROR_COPY.get(code, "连接失败，请返回大厅"))
	_force_return = true
	_selected_move = INVALID_CELL
	_refresh_ui()


func _refresh_ui() -> void:
	var board: Control = $Board
	var has_state: bool = _state != null and _state.revision >= 0
	var local_user_id: String = _client.local_user_id if _client != null else ""
	var terminal: bool = has_state and _state.status in TERMINAL_STATUSES
	var local_color: String = _local_color(local_user_id) if has_state else ""
	var opponent_presence := _opponent_presence(local_user_id) if has_state else "unknown"
	var can_move: bool = has_state and _connection_state == "connected" \
		and not _awaiting_snapshot \
		and _state.status == "active" and _state.pending_action.is_empty() \
		and _local_color(local_user_id) == _state.next_color
	if _selected_move != INVALID_CELL and not can_move:
		_selected_move = INVALID_CELL
	var pending: Vector2i = INVALID_CELL
	var winning_line: Array[Vector2i] = []
	if has_state:
		var pending_action: Dictionary = _state.pending_action
		if pending_action.get("type") == "gomoku.move.requested":
			pending = Vector2i(pending_action.get("x", -1), pending_action.get("y", -1))
		if terminal and _state.status == "finished" and _state.result == "five":
			winning_line = GomokuBoard.find_winning_line(_state.board)
		board.present(_state.board, _last_move, pending, _selected_move, winning_line)
	else:
		board.present(_empty_board(), INVALID_CELL, INVALID_CELL)

	var status_text: String = _status_text(local_user_id) if has_state else _connection_text()
	var show_status := not _force_return and has_state and _connection_state == "connected" \
		and not _awaiting_snapshot and not terminal
	$TopNavigation.set_subtitle(status_text)
	$TopNavigation.set_subtitle_visible(show_status)
	$ConnectionLabel.present(_connection_banner_state(), _error_text if _force_return else "")
	$OpponentPresence.visible = has_state and not terminal and not $ConnectionLabel.visible
	$OpponentPresence/Content/PresenceDot.text = _opponent_presence_mark(opponent_presence)
	$OpponentPresence/Content/OpponentPresenceLabel.text = _opponent_presence_text(opponent_presence)
	$ColorLabel.text = "你执黑" if local_color == "black" else "你执白" if local_color == "white" else ""
	$ErrorLabel.present("" if _force_return else _error_text, "error")
	$LoadingOverlay.set_loading(false, "")
	$TopNavigation.set_action_visible(not terminal and not _force_return)

	if terminal:
		_selected_move = INVALID_CELL
		$SettingsSheet.visible = false
	var can_resign: bool = has_state and _state.can_request_resign(local_user_id)
	var has_selection := _selected_move != INVALID_CELL
	$MoveConfirmationBar.visible = has_selection
	if has_selection:
		$MoveConfirmationBar/Content/SelectionLabel.text = "第 %d 列 · 第 %d 行" % [_selected_move.x + 1, _selected_move.y + 1]
	$TopNavigation.set_menu_item_disabled("resign", not can_resign or _resign_submitted or has_selection \
		or _connection_state != "connected" or _awaiting_snapshot)
	if terminal:
		$ResignDialog.close()
		var result_signature := "%d|%s|%s" % [_state.revision, _state.status, str(_state.result)]
		if result_signature != _presented_result_signature:
			_presented_result_signature = result_signature
			_reviewing_result = false
		_present_gomoku_result(local_user_id, winning_line)
	else:
		_presented_result_signature = ""
		_reviewing_result = false
		$TerminalEvidence.visible = false
		$ResultPanel.present_details({})
		$ResultScrim.visible = false
		$ResultPill.visible = false
	board.set_interactable(can_move and not $SettingsSheet.visible)
	print("GAMEBOX_BOARD_CANMOVE can=%s conn=%s await=%s status=%s pend_empty=%s next=%s local=%s" \
		% [can_move, _connection_state, _awaiting_snapshot, _state.status if has_state else "?", \
			_state.pending_action.is_empty() if has_state else "?", _state.next_color if has_state else "?", _local_color(local_user_id)])
	_log_safe_state(has_state, opponent_presence)


func _can_offer_resign() -> bool:
	return _started and not _disposed and not _awaiting_snapshot and not _resign_submitted \
		and _connection_state == "connected" and _state != null \
		and _state.can_request_resign(_client.local_user_id)


func _present_gomoku_result(local_user_id: String, winning_line: Array[Vector2i]) -> void:
	var local_color := _local_color(local_user_id)
	var local_won: bool = _state.winner_user_id == local_user_id
	var move_count := _stone_count(_state.board)
	var terminal_cell := _last_move
	var cell_label := _cell_label(terminal_cell)
	var line_label := _line_label(winning_line)
	var details: Dictionary
	if _state.status == "cancelled":
		details = {"outcome": "cancelled", "title": "对局已取消", "support": "本局不会计入结果。", "confirmed_text": "对局已结束", "review_available": false}
	elif _state.status == "abandoned":
		details = {"outcome": "abandoned", "title": "对局已作废", "support": "本局不会计入结果。", "confirmed_text": "对局已结束", "review_available": false}
	elif _state.result == "resignation":
		details = {
			"outcome": "won" if local_won else "lost",
			"outcome_label": "胜利" if local_won else "认输",
			"title": "对手已认输" if local_won else "你已认输",
			"support": "对局因对手认输而结束。" if local_won else "对局因你认输而结束。",
			"confirmed_text": "认输结果已确认",
			"summary": [
				{"value": "%d 手" % move_count, "label": "结束时手数"},
				{"value": _color_name(local_color), "label": "你的棋色"},
			],
			"review_available": true,
		}
	elif _state.result == "draw":
		details = {
			"outcome": "draw", "title": "势均力敌", "support": "棋盘已满，双方未分胜负。",
			"summary": [
				{"value": "%d 手" % move_count, "label": "本局手数"},
				{"value": "和棋", "label": "最终结果"},
				{"value": _color_name(local_color), "label": "你的棋色"},
			],
			"review_available": true,
		}
	else:
		details = {
			"outcome": "won" if local_won else "lost",
			"title": "漂亮的一局" if local_won else "这局差一点",
			"support": "你执%s，在第 %d 手连成五子。" % [_color_name(local_color), move_count] if local_won else "对手在第 %d 手连成五子，终局已经保留。" % move_count,
			"summary": [
				{"value": "%d 手" % move_count, "label": "本局手数"},
				{"value": cell_label if terminal_cell != INVALID_CELL else line_label, "label": "制胜落点" if terminal_cell != INVALID_CELL and local_won else "终局落点" if terminal_cell != INVALID_CELL else "获胜连线"},
				{"value": _color_name(local_color), "label": "你的棋色"},
			],
			"review_available": true,
		}
	$TerminalEvidence/Content/Labels/Player.text = "你 · %s棋" % _color_name(local_color) if not local_color.is_empty() else "对局已结束"
	$TerminalEvidence/Content/Labels/Move.text = "认输前落子 · %s" % cell_label if _state.result == "resignation" and terminal_cell != INVALID_CELL else "%s · %s" % ["最后落子" if local_won else "对手落子", cell_label] if terminal_cell != INVALID_CELL else "获胜连线 · %s" % line_label if not winning_line.is_empty() else "没有产生终局落子"
	$TerminalEvidence/Content/Piece.text = "●" if not local_color.is_empty() else "—"
	$TerminalEvidence/Content/Piece.add_theme_color_override(
		"font_color", GameboxTokens.GAME["black_piece"] if local_color == "black" else GameboxTokens.GAME["white_piece"]
	)
	var outline_color: Color = GameboxTokens.GAME["white_piece"] if local_color == "black" else GameboxTokens.GAME["black_piece"] if local_color == "white" else (GameboxTokens.DARK if GameboxTheme.system_prefers_dark() else GameboxTokens.LIGHT)["on_surface"]
	$TerminalEvidence/Content/Piece.add_theme_color_override("font_outline_color", outline_color)
	$TerminalEvidence/Content/Piece.add_theme_constant_override("outline_size", 6)
	$TerminalEvidence.visible = true
	$ResultPanel.present_details(details)
	$ResultPanel.visible = not _reviewing_result
	$ResultScrim.visible = not _reviewing_result
	$ResultPill.visible = _reviewing_result and bool(details.get("review_available", false))


func _on_result_review_requested() -> void:
	_reviewing_result = true
	$ResultPanel.visible = false
	$ResultScrim.visible = false
	$ResultPill.visible = true


func _on_result_pill_pressed() -> void:
	_reviewing_result = false
	_presented_result_signature = ""
	_refresh_ui()


static func _stone_count(board: Array) -> int:
	var count := 0
	for cell in board:
		if cell in [1, 2]:
			count += 1
	return count


static func _cell_label(cell: Vector2i) -> String:
	if cell == INVALID_CELL:
		return "—"
	return "%s%d" % [String.chr(65 + cell.x), cell.y + 1]


static func _line_label(line: Array[Vector2i]) -> String:
	if line.is_empty():
		return "—"
	return "%s–%s" % [_cell_label(line[0]), _cell_label(line[-1])]


static func _color_name(color: String) -> String:
	return "黑" if color == "black" else "白" if color == "white" else "—"


func _status_text(local_user_id: String) -> String:
	match _state.status:
		"finished":
			if _state.result == "draw":
				return "和棋"
			return "你赢了" if _state.winner_user_id == local_user_id else "你输了"
		"cancelled":
			return "对局已取消"
		"abandoned":
			return "对局已作废"
	if _connection_state != "connected":
		return _connection_text()
	if _awaiting_snapshot:
		return "同步中…"
	if _selected_move != INVALID_CELL:
		return "确认落子位置"
	if not _state.pending_action.is_empty():
		return "等待服务器确认"
	return "轮到我" if _local_color(local_user_id) == _state.next_color else "等待对手"


func _connection_text() -> String:
	match _connection_state:
		"connected":
			return "同步中…" if _awaiting_snapshot else "连接中"
		"reconnecting":
			return "重连中"
		"failed", "closed":
			return "连接失败"
		_:
			return "连接中"


func _connection_banner_state() -> String:
	if _force_return:
		return "failed"
	if _connection_state in ["failed", "closed"]:
		return _connection_state
	if _connection_state == "reconnecting":
		return "reconnecting"
	if _awaiting_snapshot:
		return "syncing" if _connection_state == "connected" else "connecting"
	return "connected"


func _opponent_presence(local_user_id: String) -> String:
	if _connection_state != "connected" or _awaiting_snapshot or _client == null:
		return "unknown"
	var opponent_id := ""
	if local_user_id == _state.black_user_id:
		opponent_id = _state.white_user_id
	elif local_user_id == _state.white_user_id:
		opponent_id = _state.black_user_id
	if opponent_id.is_empty() or not _client.has_player_presence(opponent_id):
		return "unknown"
	return "online" if _client.is_player_online(opponent_id) else "offline"


func _opponent_presence_text(presence: String) -> String:
	match presence:
		"online":
			return "对手在线"
		"offline":
			return "对手离线"
		_:
			return "对手状态未知"


func _opponent_presence_mark(presence: String) -> String:
	match presence:
		"online":
			return "●"
		"offline":
			return "○"
		_:
			return "·"


func _local_color(local_user_id: String) -> String:
	if _state == null:
		return ""
	if local_user_id == _state.black_user_id:
		return "black"
	if local_user_id == _state.white_user_id:
		return "white"
	return ""


func _resolve_launch_config() -> Dictionary:
	if not _launch_config.is_empty():
		return _validated_config(_launch_config)
	return LaunchConfig.parse(OS.get_cmdline_user_args())


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


func _connect_client_signals() -> void:
	_client.connection_state_changed.connect(_on_connection_state_changed)
	_client.snapshot_sync_started.connect(_on_snapshot_sync_started)
	_client.snapshot_received.connect(_on_snapshot_received)
	_client.event_received.connect(_on_event_received)
	_client.player_presence_changed.connect(_on_player_presence_changed)
	_client.match_error.connect(_on_match_error)
	_client.return_to_lobby_requested.connect(_on_return_to_lobby_requested)


func _valid_client(client: Variant) -> bool:
	if client == null:
		return false
	for method in ["start", "poll", "request_move", "request_resign", "has_player_presence", "is_player_online", "dispose"]:
		if not client.has_method(method):
			return false
	for signal_name in ["connection_state_changed", "snapshot_sync_started", "snapshot_received", "event_received", "player_presence_changed", "match_error", "return_to_lobby_requested"]:
		if not client.has_signal(signal_name):
			return false
	return true


func _disconnect_client_signals() -> void:
	if _client == null:
		return
	if _client.has_signal("connection_state_changed") \
		and _client.connection_state_changed.is_connected(_on_connection_state_changed):
		_client.connection_state_changed.disconnect(_on_connection_state_changed)
	if _client.has_signal("snapshot_sync_started") \
		and _client.snapshot_sync_started.is_connected(_on_snapshot_sync_started):
		_client.snapshot_sync_started.disconnect(_on_snapshot_sync_started)
	if _client.has_signal("snapshot_received") and _client.snapshot_received.is_connected(_on_snapshot_received):
		_client.snapshot_received.disconnect(_on_snapshot_received)
	if _client.has_signal("event_received") and _client.event_received.is_connected(_on_event_received):
		_client.event_received.disconnect(_on_event_received)
	if _client.has_signal("player_presence_changed") \
		and _client.player_presence_changed.is_connected(_on_player_presence_changed):
		_client.player_presence_changed.disconnect(_on_player_presence_changed)
	if _client.has_signal("match_error") and _client.match_error.is_connected(_on_match_error):
		_client.match_error.disconnect(_on_match_error)
	if _client.has_signal("return_to_lobby_requested") \
		and _client.return_to_lobby_requested.is_connected(_on_return_to_lobby_requested):
		_client.return_to_lobby_requested.disconnect(_on_return_to_lobby_requested)


func _dispose_client() -> void:
	if _disposed:
		return
	_disposed = true
	_selected_move = INVALID_CELL
	_cancel_ready_marker()
	set_process(false)
	_disconnect_client_signals()
	if _client != null and _client.has_method("dispose"):
		_client.dispose()


func _show_start_failure() -> void:
	_launch_config.clear()
	_error_text = "无法进入对局，请返回大厅"
	_connection_state = "failed"
	_force_return = true
	_selected_move = INVALID_CELL
	set_process(false)
	_refresh_ui()


func _schedule_ready_marker() -> void:
	if _disposed or _ready_marker_emitted or _ready_marker_callback.is_valid():
		return
	_ready_marker_generation += 1
	var generation := _ready_marker_generation
	_ready_marker_callback = _on_first_frame_drawn.bind(generation)
	if _frame_ready_gate != null:
		if not _frame_ready_gate.schedule(_ready_marker_callback):
			_ready_marker_callback = Callable()
		return
	var connect_error := RenderingServer.frame_post_draw.connect(_ready_marker_callback, CONNECT_ONE_SHOT)
	if connect_error != OK:
		_ready_marker_callback = Callable()


func _on_first_frame_drawn(generation: int) -> void:
	_ready_marker_callback = Callable()
	if generation != _ready_marker_generation or _disposed or _returning \
		or _ready_marker_emitted or not is_inside_tree():
		return
	_ready_marker_text = "GAMEBOX_GODOT_READY game=gomoku match=%s" % _match_id
	_ready_marker_emitted = true
	print(_ready_marker_text)


func _cancel_ready_marker() -> void:
	_ready_marker_generation += 1
	if not _ready_marker_callback.is_valid():
		return
	if _frame_ready_gate != null:
		_frame_ready_gate.cancel(_ready_marker_callback)
	elif RenderingServer.frame_post_draw.is_connected(_ready_marker_callback):
		RenderingServer.frame_post_draw.disconnect(_ready_marker_callback)
	_ready_marker_callback = Callable()


func _log_safe_state(has_state: bool, opponent_presence: String) -> void:
	if _match_id.is_empty():
		return
	var revision: int = _state.revision if has_state else -1
	var status: String = _state.status if has_state else "loading"
	var signature := "%d|%s|%s|%s" % [revision, status, _connection_state, opponent_presence]
	if signature != _last_log_signature:
		_last_log_signature = signature
		print("GAMEBOX_GODOT_STATE match=%s revision=%d status=%s connection=%s opponent_presence=%s" % [_match_id, revision, status, _connection_state, opponent_presence])
	if has_state and status in TERMINAL_STATUSES:
		var result: String = str(_state.result) if _state.result in ["five", "resignation", "draw"] else status
		var terminal_signature := "%d|%s" % [revision, result]
		if terminal_signature != _reported_terminal_signature:
			_reported_terminal_signature = terminal_signature
			print("GAMEBOX_MATCH_RESULT match=%s result=%s" % [_match_id, result])


func _empty_board() -> Array:
	var board: Array = []
	board.resize(225)
	board.fill(0)
	return board


func _can_request_selected_move() -> bool:
	return _started and not _disposed and not _awaiting_snapshot \
		and _connection_state == "connected" and _state != null \
		and _state.can_request_move(_selected_move.x, _selected_move.y, _client.local_user_id)
