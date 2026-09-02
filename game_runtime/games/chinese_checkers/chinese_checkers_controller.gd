extends Control

const LaunchConfig = preload("res://core/launch_config.gd")
const MatchClient = preload("res://core/match_client.gd")
const ChineseCheckersState = preload("res://games/chinese_checkers/chinese_checkers_state.gd")
const ChineseCheckersTheme = preload("res://games/chinese_checkers/chinese_checkers_theme.gd")
const GameboxTheme = preload("res://design_system/gamebox_theme.gd")
const GameboxTokens = preload("res://design_system/generated/gamebox_tokens.gd")

const TERMINAL_STATUSES := ["finished", "cancelled", "abandoned"]
const SAFE_ERROR_COPY := {
	"ticket_invalid": "登录状态已失效，请返回大厅",
	"resume_expired": "登录状态已失效，请返回大厅",
	"stale_revision": "棋盘已更新，正在同步",
	"action_conflict": "操作冲突，请重试",
	"not_your_turn": "还没轮到你",
	"invalid_move": "这一步走法无效，请重新选择",
	"invalid_request": "操作无效，请重试",
	"match_not_found": "对局不存在，请返回大厅",
	"internal_error": "服务暂时不可用，请稍后重试",
	"connection_failed": "连接失败，请返回大厅",
}
const GO_BACK_DEBOUNCE_MS := 150

var ready_marker_emitted: bool:
	get: return _ready_marker_emitted
	set(_value): pass
var ready_marker_text: String:
	get: return _ready_marker_text
	set(_value): pass

var _launch_config := {}
var _match_client_factory := Callable()
var _quit_callback := Callable()
var _frame_ready_gate: Variant
var _state: Variant
var _client: Variant
var _match_id := ""
var _connection_state := "connecting"
var _error_text := ""
var _selected_hole := -1
var _target_paths := {}
var _awaiting_snapshot := true
var _started := false
var _disposed := false
var _returning := false
var _force_return := false
var _resign_submitted := false
var _reviewing_result := false
var _presented_result_signature := ""
var _last_presented_move_revision := -1
var _defer_result_until_move_animation := false
var _queued_move_animations: Array = []
var _move_presentation := {}
var _logged_state_signature := ""
var _ready_marker_generation := 0
var _ready_marker_callback := Callable()
var _ready_marker_emitted := false
var _ready_marker_text := ""
var _last_go_back_time_ms := -100000


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


func _ready() -> void:
	var dark_theme := GameboxTheme.system_prefers_dark()
	theme = ChineseCheckersTheme.create(dark_theme)
	var colors: Dictionary = GameboxTokens.DARK if dark_theme else GameboxTokens.LIGHT
	$ResultScrim.color = Color(colors["scrim"], GameboxTokens.COMPONENT["dialog_scrim_opacity"])
	$Board.hole_pressed.connect(_on_hole_pressed)
	$Board.move_animation_finished.connect(_on_move_animation_finished)
	$TopNavigation.back_requested.connect(_on_back_pressed)
	$TopNavigation.set_menu_items([{"id": "resign", "label": "认输并结束对局", "danger": true}])
	$TopNavigation.menu_action_requested.connect(_on_menu_action_requested)
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
	_state = ChineseCheckersState.new(_match_id)
	_client = _match_client_factory.call() if _match_client_factory.is_valid() else MatchClient.new()
	if not _valid_client(_client):
		config["launch_ticket"] = ""
		_launch_config.clear()
		_show_start_failure()
		return
	_connect_client_signals()
	var started: bool = _client.start(config["ws_url"], _match_id, config["launch_ticket"], _state, "chinese_checkers")
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


func _exit_tree() -> void:
	_dispose_client()


func _on_hole_pressed(index: int) -> void:
	if not _can_interact():
		return
	var local_stone := 1 if _local_color() == "black" else 2
	var stone: int = _state.board[index]
	if stone == local_stone:
		if _selected_hole == index:
			_clear_selection()
		else:
			_select_hole(index)
		_refresh_ui()
		return
	if _selected_hole >= 0 and _target_paths.has(index):
		var path: Array = _target_paths[index].duplicate()
		if _client.request_chinese_checkers_move(path).is_empty():
			_error_text = "操作失败，请重试"
		else:
			_error_text = ""
			_clear_selection()
		_refresh_ui()
		return
	_clear_selection()
	_refresh_ui()


func _select_hole(index: int) -> void:
	_target_paths = _state.legal_paths_from(index, _client.local_user_id)
	_selected_hole = index if not _target_paths.is_empty() else -1
	if _selected_hole < 0:
		_error_text = "这枚棋子当前没有可走终点"
	else:
		_error_text = ""


func _clear_selection() -> void:
	_selected_hole = -1
	_target_paths.clear()


func _on_menu_action_requested(action_id: String) -> void:
	if action_id == "resign" and _can_offer_resign():
		$ResignDialog.open()


func _on_resign_confirmed() -> void:
	if not _can_offer_resign() or _resign_submitted:
		return
	_resign_submitted = true
	if _client.request_resign().is_empty():
		_resign_submitted = false
		_error_text = "操作失败，请重试"
	_refresh_ui()


func _on_back_pressed() -> void:
	if $TopNavigation.close_menu():
		return
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


func _notification(what: int) -> void:
	if what == Node.NOTIFICATION_WM_GO_BACK_REQUEST:
		var now := Time.get_ticks_msec()
		if now - _last_go_back_time_ms < GO_BACK_DEBOUNCE_MS:
			return
		_last_go_back_time_ms = now
		_on_back_pressed()


func _unhandled_key_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and not event.is_echo():
		get_viewport().set_input_as_handled()
		_on_back_pressed()


func _on_connection_state_changed(next_state: String) -> void:
	if next_state not in ["connecting", "connected", "reconnecting", "failed", "closed"]:
		return
	_connection_state = next_state
	if next_state != "connected":
		_awaiting_snapshot = true
		_clear_selection()
	_refresh_ui()


func _on_snapshot_sync_started() -> void:
	_awaiting_snapshot = true
	_clear_selection()
	_refresh_ui()


func _on_snapshot_received(envelope: Dictionary) -> void:
	if _state == null:
		return
	var applied: Dictionary = _state.apply_snapshot(envelope)
	if not applied.get("ok", false):
		_error_text = "同步失败，请返回大厅"
		_force_return = true
	elif applied.get("status") in ["applied", "ignored"]:
		_error_text = ""
		_awaiting_snapshot = false
		_resign_submitted = false
		_last_presented_move_revision = maxi(_last_presented_move_revision, _state.revision)
		if applied.get("status") == "applied":
			_queued_move_animations.clear()
			_move_presentation.clear()
			_defer_result_until_move_animation = false
			$Board.cancel_move_animation()
		_clear_selection()
	_refresh_ui()


func _on_event_received(envelope: Dictionary) -> void:
	if _state == null:
		return
	var applied: Dictionary = _state.apply_event(envelope)
	var accepted_path: Array = []
	var preserve_board_animation := false
	if not applied.get("ok", false):
		_error_text = "同步失败，请返回大厅"
		_force_return = true
	elif envelope.get("type") == "chinese_checkers.move.accepted" \
		and applied.get("status") in ["applied", "ignored"]:
		var revision: Variant = envelope.get("revision")
		if typeof(revision) == TYPE_INT and revision > _last_presented_move_revision:
			_last_presented_move_revision = revision
			$MoveSound.play()
			var payload: Variant = envelope.get("payload")
			if payload is Dictionary and payload.get("path") is Array:
				accepted_path = payload["path"].duplicate()
				_defer_result_until_move_animation = _state.status in TERMINAL_STATUSES
				preserve_board_animation = not $Board.move_animation_path.is_empty()
	_clear_selection()
	if not accepted_path.is_empty():
		var presentation := _current_move_presentation()
		if preserve_board_animation:
			_queued_move_animations.append({
				"board": _state.board,
				"local_color": _local_color(),
				"path": accepted_path,
				"presentation": presentation,
			})
		else:
			_move_presentation = presentation
	_refresh_ui(preserve_board_animation)
	if not accepted_path.is_empty() and not preserve_board_animation \
		and not $Board.play_move_animation(accepted_path):
		_defer_result_until_move_animation = false
		_refresh_ui()


func _on_move_animation_finished() -> void:
	while not _queued_move_animations.is_empty():
		var queued: Dictionary = _queued_move_animations.pop_front()
		_move_presentation = queued["presentation"]
		if $Board.present(queued["board"], queued["local_color"], -1, {}, [], false) \
			and $Board.play_move_animation(queued["path"]):
			_refresh_ui(true)
			return
	_move_presentation.clear()
	if _state == null:
		return
	_defer_result_until_move_animation = false
	_refresh_ui.call_deferred()


func _on_player_presence_changed(_user_id: String, _online: bool) -> void:
	_refresh_ui()


func _on_match_error(code: String) -> void:
	_error_text = str(SAFE_ERROR_COPY.get(code, "操作失败，请稍后重试"))
	_resign_submitted = false
	_clear_selection()
	if code == "stale_revision":
		_awaiting_snapshot = true
	_refresh_ui()


func _on_return_to_lobby_requested(code: String) -> void:
	_error_text = str(SAFE_ERROR_COPY.get(code, "连接失败，请返回大厅"))
	_force_return = true
	_clear_selection()
	_refresh_ui()


func _refresh_ui(preserve_board_animation: bool = false) -> void:
	var has_state: bool = _state != null and _state.revision >= 0
	var presentation: Dictionary = _move_presentation if not _move_presentation.is_empty() \
		else _current_move_presentation() if has_state else {}
	var terminal := bool(presentation.get("terminal", false))
	var pending_path: Array = []
	if has_state and _state.pending_action.get("type") == "chinese_checkers.move.requested":
		pending_path = _state.pending_action.get("path", []).duplicate()
	if not _can_interact():
		_clear_selection()
	elif _selected_hole >= 0:
		_target_paths = _state.legal_paths_from(_selected_hole, _client.local_user_id)
		if _target_paths.is_empty():
			_clear_selection()
	var display_board: Array = _state.board if has_state else _initial_board()
	var local_color := str(presentation.get("local_color", "white"))
	preserve_board_animation = preserve_board_animation or (
		not _move_presentation.is_empty() and not $Board.move_animation_path.is_empty())
	if not preserve_board_animation:
		$Board.present(display_board, local_color if not local_color.is_empty() else "white", _selected_hole, _target_paths, pending_path, _can_interact())
	$TopNavigation.set_subtitle(str(presentation.get("status_text", "")) if has_state else _connection_text())
	$TopNavigation.set_subtitle_visible(has_state and not terminal and not _force_return and _connection_state == "connected" and not _awaiting_snapshot)
	$TopNavigation.set_action_visible(not terminal and not _force_return)
	$TopNavigation.set_menu_item_disabled("resign", not _can_offer_resign())
	$ConnectionLabel.present(_connection_banner_state(), _error_text if _force_return else "")
	$ErrorLabel.present("" if _force_return else _error_text, "error")
	$PlayerStrip.visible = has_state and not $ConnectionLabel.visible
	if has_state:
		var active_local := bool(presentation["active_local"])
		var active_opponent := bool(presentation["active_opponent"])
		var local_status := str(presentation["local_status"])
		var opponent_color := str(presentation["opponent_color"])
		var opponent_status := str(presentation["opponent_status"])
		_present_player_card($PlayerStrip/Content/Me, local_color, local_status, &"ChineseCheckersTurnPlayerActiveLocal" if active_local else &"ChineseCheckersTurnPlayerInactive")
		_present_player_card($PlayerStrip/Content/Opponent, opponent_color, opponent_status, &"ChineseCheckersTurnPlayerActiveOpponent" if active_opponent else &"ChineseCheckersTurnPlayerInactive")
		$PlayerStrip/Content/Turn.text = str(presentation["turn_text"])
	$HintLabel.text = str(presentation.get("hint_text", "连接后即可开始"))
	if terminal:
		$ResignDialog.close()
		if _defer_result_until_move_animation:
			$ResultPanel.visible = false
			$ResultScrim.visible = false
			$ResultPill.visible = false
		else:
			var signature := "%d|%s|%s" % [_state.revision, _state.status, str(_state.result)]
			if signature != _presented_result_signature:
				_presented_result_signature = signature
				_reviewing_result = false
				_present_result()
	else:
		_presented_result_signature = ""
		_reviewing_result = false
		$ResultPanel.present_details({})
		$ResultScrim.visible = false
		$ResultPill.visible = false
	_log_runtime_state()


func _current_move_presentation() -> Dictionary:
	var terminal: bool = _state.status in TERMINAL_STATUSES
	var local_color := _local_color()
	var active_local: bool = not terminal and (not _state.pending_action.is_empty() or local_color == _state.next_color)
	var active_opponent: bool = not terminal and _state.pending_action.is_empty() and local_color != _state.next_color
	return {
		"terminal": terminal,
		"status_text": _status_text(),
		"local_color": local_color,
		"active_local": active_local,
		"active_opponent": active_opponent,
		"local_status": "确认中" if not _state.pending_action.is_empty() else "正在行动" if active_local else "先手" if local_color == "black" else "后手",
		"opponent_color": "white" if local_color == "black" else "black",
		"opponent_status": "正在行动" if active_opponent else _opponent_presence_text(),
		"turn_text": _turn_chip_text(),
		"hint_text": _hint_text(),
	}


func _present_result() -> void:
	var local_won: bool = _state.winner_user_id == _client.local_user_id
	var details := {}
	if _state.status == "cancelled":
		details = {"outcome": "cancelled", "title": "对局已取消", "support": "本局不会计入结果。", "confirmed_text": "对局已结束", "review_available": false}
	elif _state.status == "abandoned":
		details = {"outcome": "abandoned", "title": "对局已作废", "support": "本局不会计入结果。", "confirmed_text": "对局已结束", "review_available": false}
	elif _state.result == "resignation":
		details = {
			"outcome": "won" if local_won else "lost",
			"outcome_label": "胜利" if local_won else "认输",
			"title": "对手已认输" if local_won else "你已认输",
			"support": "跳棋终局已由服务器确认。",
			"summary": [{"value": "%d 手" % max(_state.revision - 1, 0), "label": "完成步数"}],
			"review_available": true,
		}
	else:
		details = {
			"outcome": "won" if local_won else "lost",
			"title": "率先抵达" if local_won else "这局差一点",
			"support": "全部棋子进入对面目标营。" if local_won else "对手率先完成了目标营。",
			"summary": [{"value": "%d 手" % _state.revision, "label": "完成步数"}],
			"review_available": true,
		}
	$ResultPanel.present_details(details)
	$ResultPanel.visible = not _reviewing_result
	$ResultScrim.visible = not _reviewing_result
	$ResultPill.visible = _reviewing_result and bool(details.get("review_available", false))
	print("GAMEBOX_MATCH_RESULT match=%s result=%s" % [_match_id, str(_state.result)])


func _log_runtime_state() -> void:
	if _match_id.is_empty():
		return
	var revision: int = -1 if _state == null else _state.revision
	var status: String = "loading" if _state == null or _state.revision < 0 else _state.status
	var pending: bool = _state != null and not _state.pending_action.is_empty()
	var signature: String = "%d|%s|%s|%d|%s|%d" % [revision, status, _connection_state, _selected_hole, str(pending), _target_paths.size()]
	if signature == _logged_state_signature:
		return
	_logged_state_signature = signature
	print("GAMEBOX_GODOT_STATE match=%s revision=%d status=%s connection=%s" % [_match_id, revision, status, _connection_state])
	print("GAMEBOX_CHINESE_CHECKERS_STATE match=%s revision=%d selected=%d targets=%d pending=%s" % [_match_id, revision, _selected_hole, _target_paths.size(), str(pending)])


func _on_result_review_requested() -> void:
	_reviewing_result = true
	$ResultPanel.visible = false
	$ResultScrim.visible = false
	$ResultPill.visible = true


func _on_result_pill_pressed() -> void:
	_reviewing_result = false
	_presented_result_signature = ""
	_refresh_ui()


func _can_interact() -> bool:
	return _started and not _disposed and not _awaiting_snapshot and _connection_state == "connected" \
		and _state != null and _state.revision >= 0 and _state.status == "active" \
		and _state.pending_action.is_empty() and _local_color() == _state.next_color


func _can_offer_resign() -> bool:
	return _started and not _disposed and not _awaiting_snapshot and not _resign_submitted \
		and _connection_state == "connected" and _state != null \
		and _state.can_request_resign(_client.local_user_id)


func _local_color() -> String:
	if _state == null or _client == null:
		return ""
	if _client.local_user_id == _state.black_user_id:
		return "black"
	if _client.local_user_id == _state.white_user_id:
		return "white"
	return ""


func _opponent_presence_text() -> String:
	if _connection_state != "connected" or _awaiting_snapshot:
		return "状态未知"
	var opponent_id: String = _state.white_user_id if _local_color() == "black" else _state.black_user_id
	if opponent_id.is_empty() or not _client.has_method("has_player_presence") \
		or not _client.has_method("is_player_online") or not _client.has_player_presence(opponent_id):
		return "状态未知"
	return "在线" if _client.is_player_online(opponent_id) else "离线"


func _present_player_card(card: PanelContainer, color: String, status: String, variation: StringName) -> void:
	card.theme_type_variation = variation
	var identity := card.get_node("Content/Identity/Name") as Label
	var supporting := card.get_node("Content/Status") as Label
	var piece := card.get_node("Content/Identity/Piece") as Label
	var identity_variation := &"ChineseCheckersTurnPlayerIdentity"
	var supporting_variation := &"ChineseCheckersTurnPlayerSupporting"
	if variation == &"ChineseCheckersTurnPlayerActiveLocal":
		identity_variation = &"ChineseCheckersTurnPlayerActiveLocalIdentity"
		supporting_variation = &"ChineseCheckersTurnPlayerActiveLocalSupporting"
	elif variation == &"ChineseCheckersTurnPlayerActiveOpponent":
		identity_variation = &"ChineseCheckersTurnPlayerActiveOpponentIdentity"
		supporting_variation = &"ChineseCheckersTurnPlayerActiveOpponentSupporting"
	identity.theme_type_variation = identity_variation
	supporting.theme_type_variation = supporting_variation
	supporting.text = status
	piece.add_theme_color_override("font_color", GameboxTokens.GAME["black_piece"] if color == "black" else GameboxTokens.GAME["white_piece"])
	piece.add_theme_color_override("font_outline_color", GameboxTokens.GAME["white_piece_outline"])
	piece.add_theme_constant_override("outline_size", GameboxTokens.SPACING["base"])


func _status_text() -> String:
	if not _state.pending_action.is_empty():
		return "等待服务器确认"
	if _selected_hole >= 0:
		return "选择一个终点"
	return "轮到我" if _local_color() == _state.next_color else "等待对手"


func _turn_chip_text() -> String:
	if _state.status in TERMINAL_STATUSES:
		return "对局结束"
	if not _state.pending_action.is_empty():
		return "确认中"
	return "轮到你" if _local_color() == _state.next_color else "等待中"


func _hint_text() -> String:
	if _state.status in TERMINAL_STATUSES:
		return "对局已结束，结果已由服务器确认"
	if _awaiting_snapshot or _connection_state != "connected":
		return "棋盘会保留，恢复同步后继续"
	if not _state.pending_action.is_empty():
		return "路线已提交，等待服务器确认"
	if _selected_hole >= 0:
		return "已显示 %d 个可达终点，点终点直接走棋" % _target_paths.size()
	if _local_color() == _state.next_color:
		return "点选你的棋子，再点高亮终点"
	return "对手正在选择路线"


func _connection_text() -> String:
	return "重连中…" if _connection_state == "reconnecting" else "连接失败" if _connection_state in ["failed", "closed"] else "同步中…" if _connection_state == "connected" else "连接中…"


func _connection_banner_state() -> String:
	if _force_return:
		return "failed"
	if _connection_state in ["failed", "closed", "reconnecting"]:
		return _connection_state
	if _awaiting_snapshot:
		return "syncing" if _connection_state == "connected" else "connecting"
	return "connected"


func _resolve_launch_config() -> Dictionary:
	return _validated_config(_launch_config) if not _launch_config.is_empty() else LaunchConfig.parse(OS.get_cmdline_user_args())


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
	for method in ["start", "poll", "request_chinese_checkers_move", "request_resign", "dispose"]:
		if not client.has_method(method):
			return false
	for signal_name in ["connection_state_changed", "snapshot_sync_started", "snapshot_received", "event_received", "player_presence_changed", "match_error", "return_to_lobby_requested"]:
		if not client.has_signal(signal_name):
			return false
	return true


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
	_clear_selection()
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
	if RenderingServer.frame_post_draw.connect(_ready_marker_callback, CONNECT_ONE_SHOT) != OK:
		_ready_marker_callback = Callable()


func _on_first_frame_drawn(generation: int) -> void:
	_ready_marker_callback = Callable()
	if generation != _ready_marker_generation or _disposed or _returning or _ready_marker_emitted or not is_inside_tree():
		return
	_ready_marker_text = "GAMEBOX_GODOT_READY game=chinese_checkers match=%s" % _match_id
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


static func _initial_board() -> Array:
	var cells: Array = []
	cells.resize(121)
	cells.fill(0)
	for index in 10:
		cells[index] = 1
	for index in range(111, 121):
		cells[index] = 2
	return cells
