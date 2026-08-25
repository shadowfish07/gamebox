extends Control

const LaunchConfig = preload("res://core/launch_config.gd")
const MatchClient = preload("res://core/match_client.gd")
const GomokuState = preload("res://games/gomoku/gomoku_state.gd")
const GameboxTheme = preload("res://design_system/gamebox_theme.gd")

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
var _last_go_back_time_ms := -100000
var _go_back_debounce_ms := GO_BACK_DEBOUNCE_MS


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
	theme = GameboxTheme.create(GameboxTheme.system_prefers_dark())
	$Board.cell_pressed.connect(_on_cell_pressed)
	$BackButton.pressed.connect(_on_back_pressed)
	$ResignButton.pressed.connect(_on_resign_pressed)
	$ResignDialog.confirmed.connect(_on_resign_confirmed)
	$ResultPanel.return_requested.connect(_on_back_pressed)
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
	var result: String = _client.request_move(x, y)
	print("GAMEBOX_BOARD_MOVE x=%d y=%d result=%s" % [x, y, result])
	if not result.is_empty():
		_error_text = ""
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
	if $ResignDialog.visible:
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
	_refresh_ui()


func _on_snapshot_sync_started() -> void:
	_awaiting_snapshot = true
	_refresh_ui()


func _on_snapshot_received(envelope: Dictionary) -> void:
	if _state == null:
		return
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
	if code == "stale_revision":
		_awaiting_snapshot = true
	_refresh_ui()


func _on_return_to_lobby_requested(code: String) -> void:
	_error_text = str(SAFE_ERROR_COPY.get(code, "连接失败，请返回大厅"))
	_force_return = true
	_refresh_ui()


func _refresh_ui() -> void:
	var board: Control = $Board
	var has_state: bool = _state != null and _state.revision >= 0
	var local_user_id: String = _client.local_user_id if _client != null else ""
	var local_color: String = _local_color(local_user_id) if has_state else ""
	var opponent_presence := _opponent_presence(local_user_id) if has_state else "unknown"
	var pending: Vector2i = INVALID_CELL
	if has_state:
		var pending_action: Dictionary = _state.pending_action
		if pending_action.get("type") == "gomoku.move.requested":
			pending = Vector2i(pending_action.get("x", -1), pending_action.get("y", -1))
		board.present(_state.board, _last_move, pending)
	else:
		board.present(_empty_board(), INVALID_CELL, INVALID_CELL)

	var terminal: bool = has_state and _state.status in TERMINAL_STATUSES
	var status_text: String = _status_text(local_user_id) if has_state else _connection_text()
	if _force_return:
		status_text = _error_text if not _error_text.is_empty() else "请返回大厅"
	$StatusLabel.text = status_text
	$ConnectionLabel.present(_connection_state, _connection_detail())
	$OpponentPresence.visible = has_state and not terminal and _connection_state == "connected" \
		and not _awaiting_snapshot
	$OpponentPresence/Content/PresenceDot.text = _opponent_presence_mark(opponent_presence)
	$OpponentPresence/Content/OpponentPresenceLabel.text = _opponent_presence_text(opponent_presence)
	$ColorLabel.text = "你执黑" if local_color == "black" else "你执白" if local_color == "white" else ""
	$ErrorLabel.present(_error_text, "error")
	$LoadingOverlay.set_loading(not has_state and _awaiting_snapshot, "正在同步对局…")

	$StatusLabel.visible = _force_return or (has_state and _connection_state == "connected" \
		and not _awaiting_snapshot and not terminal)
	var can_resign: bool = has_state and _state.can_request_resign(local_user_id)
	$ResignButton.visible = can_resign and not terminal and not _resign_submitted
	$ResignButton.disabled = _connection_state != "connected" or _awaiting_snapshot
	if terminal:
		$ResignDialog.close()
		$ResultPanel.present(_result_panel_status(), _state.winner_user_id == local_user_id)
	else:
		$ResultPanel.present("", false)
	var can_move: bool = has_state and _connection_state == "connected" \
		and not _awaiting_snapshot \
		and _state.status == "active" and _state.pending_action.is_empty() \
		and _local_color(local_user_id) == _state.next_color
	board.set_interactable(can_move)
	print("GAMEBOX_BOARD_CANMOVE can=%s conn=%s await=%s status=%s pend_empty=%s next=%s local=%s" \
		% [can_move, _connection_state, _awaiting_snapshot, _state.status if has_state else "?", \
			_state.pending_action.is_empty() if has_state else "?", _state.next_color if has_state else "?", _local_color(local_user_id)])
	_log_safe_state(has_state, opponent_presence)


func _can_offer_resign() -> bool:
	return _started and not _disposed and not _awaiting_snapshot and not _resign_submitted \
		and _connection_state == "connected" and _state != null \
		and _state.can_request_resign(_client.local_user_id)


func _result_panel_status() -> String:
	if _state.status != "finished":
		return _state.status
	return "draw" if _state.result == "draw" else "finished"


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
		return "正在同步对局…"
	if not _state.pending_action.is_empty():
		return "等待服务器确认"
	return "轮到我" if _local_color(local_user_id) == _state.next_color else "等待对手"


func _connection_text() -> String:
	match _connection_state:
		"connected":
			return "正在同步对局…" if _awaiting_snapshot else "连接中"
		"reconnecting":
			return "重连中"
		"failed", "closed":
			return "连接失败"
		_:
			return "连接中"


func _connection_detail() -> String:
	match _connection_state:
		"connected":
			return "正在同步对局…" if _awaiting_snapshot else "已连接"
		"reconnecting":
			return "正在恢复连接…"
		"failed", "closed":
			return "连接已断开"
		_:
			return "正在连接服务器…"


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
