extends Control

const LaunchConfig = preload("res://core/launch_config.gd")
const MatchClient = preload("res://core/match_client.gd")
const RpsState = preload("res://games/rps/rps_state.gd")
const GameboxTheme = preload("res://design_system/gamebox_theme.gd")
const SAFE_ERRORS := {
	"choice_locked": "本轮已经出拳",
	"stale_revision": "对局已更新，正在同步",
	"action_conflict": "操作冲突，请重试",
	"invalid_request": "操作无效，请重试",
	"match_not_found": "对局不存在，请返回大厅",
	"internal_error": "服务暂时不可用，请稍后重试",
	"connection_failed": "连接失败，请返回大厅",
}

var _launch_config := {}
var _match_client_factory := Callable()
var _quit_callback := Callable()
var _state: Variant
var _client: Variant
var _match_id := ""
var _connection_state := "connecting"
var _awaiting_snapshot := true
var _error_text := ""
var _disposed := false
var _returning := false
var _resign_submitted := false
var _last_log_signature := ""
var _terminal_logged := false


func configure_launch(config: Dictionary) -> bool:
	if is_inside_tree() or not _launch_config.is_empty():
		return false
	var result := _validated_config(config)
	if not result.get("ok", false) or result["config"]["game_id"] != "rps":
		return false
	_launch_config = result["config"].duplicate(true)
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


func _ready() -> void:
	theme = GameboxTheme.create(GameboxTheme.system_prefers_dark())
	$BackButton.pressed.connect(_on_back_pressed)
	$ChoicePanel/Choices/RockButton.pressed.connect(_on_choice.bind("rock"))
	$ChoicePanel/Choices/PaperButton.pressed.connect(_on_choice.bind("paper"))
	$ChoicePanel/Choices/ScissorsButton.pressed.connect(_on_choice.bind("scissors"))
	$ResignButton.pressed.connect(_on_resign_pressed)
	$ResignDialog.confirmed.connect(_on_resign_confirmed)
	$ResignDialog/Dialog/Content/Title.text = "认输并结束本局？"
	$ResignDialog/Dialog/Content/Message.text = "确认后对手立即获胜，本局无法继续。"
	$ResignDialog/Dialog/Content/Actions/CancelButton.text = "继续对局"
	$ResignDialog/Dialog/Content/Actions/ConfirmButton.text = "认输并结束"
	$ResultPanel.return_requested.connect(_on_back_pressed)
	_refresh_ui()
	var resolved := _resolve_launch_config()
	if not resolved.get("ok", false) or resolved["config"]["game_id"] != "rps":
		_show_start_failure()
		return
	var config: Dictionary = resolved["config"]
	_match_id = config["match_id"]
	_state = RpsState.new(_match_id)
	_client = _match_client_factory.call() if _match_client_factory.is_valid() else MatchClient.new()
	if not _valid_client(_client):
		config["launch_ticket"] = ""
		_launch_config.clear()
		_show_start_failure()
		return
	_connect_signals()
	var started: bool = _client.start(
		config["ws_url"], _match_id, config["launch_ticket"], _state, "rps"
	)
	config["launch_ticket"] = ""
	_launch_config.clear()
	if not started:
		_show_start_failure()
		return
	_connection_state = _client.connection_state
	set_process(true)
	_refresh_ui()
	call_deferred("_emit_ready_marker")


func _process(_delta: float) -> void:
	if not _disposed and _client != null:
		_client.poll()


func _exit_tree() -> void:
	_dispose_client()


func _on_choice(choice: String) -> void:
	if _state == null or _client == null or _awaiting_snapshot \
		or _connection_state != "connected" or not _state.can_request_choice(choice, _client.local_user_id):
		return
	if _client.request_choice(choice).is_empty():
		_error_text = "出拳失败，请重试"
	else:
		_error_text = ""
	_refresh_ui()


func _on_resign_pressed() -> void:
	if _can_resign():
		$ResignDialog.open()


func _on_resign_confirmed() -> void:
	if not _can_resign() or _resign_submitted:
		return
	_resign_submitted = true
	if _client.request_resign().is_empty():
		_resign_submitted = false
		_error_text = "认输失败，请重试"
	_refresh_ui()


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


func _notification(what: int) -> void:
	if what == Node.NOTIFICATION_WM_GO_BACK_REQUEST:
		_on_back_pressed()


func _unhandled_key_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and not event.is_echo():
		get_viewport().set_input_as_handled()
		_on_back_pressed()


func _on_connection_state_changed(next_state: String) -> void:
	_connection_state = next_state
	if next_state != "connected":
		_awaiting_snapshot = true
	_refresh_ui()


func _on_snapshot_sync_started() -> void:
	_awaiting_snapshot = true
	_refresh_ui()


func _on_snapshot_received(_envelope: Dictionary) -> void:
	_awaiting_snapshot = false
	_error_text = ""
	_resign_submitted = false
	_refresh_ui()


func _on_event_received(_envelope: Dictionary) -> void:
	_resign_submitted = false
	_refresh_ui()


func _on_player_presence_changed(_user_id: String, _online: bool) -> void:
	_refresh_ui()


func _on_match_error(code: String) -> void:
	_error_text = str(SAFE_ERRORS.get(code, "操作失败，请稍后重试"))
	_resign_submitted = false
	if code == "stale_revision":
		_awaiting_snapshot = true
	_refresh_ui()


func _on_return_to_lobby_requested(code: String) -> void:
	_error_text = str(SAFE_ERRORS.get(code, "连接失败，请返回大厅"))
	_awaiting_snapshot = true
	_refresh_ui()


func _refresh_ui() -> void:
	var has_state: bool = _state != null and _state.revision >= 0
	var local_user_id: String = _client.local_user_id if _client != null else ""
	var terminal: bool = has_state and _state.status in ["finished", "cancelled", "abandoned"]
	$ConnectionBanner.present(_connection_state, "正在恢复对局")
	$ErrorSnackbar.present(_error_text, "error")
	$LoadingOverlay.set_loading(not has_state or _awaiting_snapshot, "正在同步对局…")
	$FormatLabel.text = _format_label(_state.format) if has_state else "赛制加载中"
	$ScorePanel/ScoreLabel.text = "你 %d  :  %d 对手" % [_state.me_score, _state.opponent_score] if has_state else "你 0  :  0 对手"
	$RoundLabel.text = "第 %d 轮" % _state.round_number if has_state else "准备对局"
	$StateLabel.text = _status_text(local_user_id) if has_state else "正在连接"
	$OpponentLockLabel.text = _opponent_text() if has_state else "对手状态未知"
	$RevealPanel.visible = has_state and _state.last_reveal is Dictionary
	if $RevealPanel.visible:
		$RevealPanel/RevealLabel.text = _reveal_text(local_user_id)
	var can_choose: bool = has_state and not terminal and not _awaiting_snapshot \
		and _connection_state == "connected" and _state.can_request_choice("rock", local_user_id)
	for button in [$ChoicePanel/Choices/RockButton, $ChoicePanel/Choices/PaperButton, $ChoicePanel/Choices/ScissorsButton]:
		button.disabled = not can_choose
	$ChoicePanel.visible = not terminal
	$ResignButton.visible = has_state and not terminal and _state.can_request_resign(local_user_id)
	$ResignButton.disabled = _connection_state != "connected" or _awaiting_snapshot or _resign_submitted
	if terminal:
		$ResignDialog.close()
		$ResultPanel.present(_state.status, _state.winner_user_id == local_user_id)
	else:
		$ResultPanel.present("", false)
	_log_safe_state(has_state)


func _status_text(local_user_id: String) -> String:
	if _state.status == "finished":
		return "你赢得了对局" if _state.winner_user_id == local_user_id else "对手赢得了对局"
	if _state.status == "cancelled":
		return "对局已取消"
	if _state.status == "abandoned":
		return "对局已作废"
	if not _state.pending_action.is_empty():
		return "正在锁定你的选择…"
	if _state.me_locked:
		return "已出拳，等待对手"
	return "请选择本轮手势"


func _opponent_text() -> String:
	if _state.opponent_locked:
		return "对手已出拳 · 选择已保密"
	return "等待对手出拳"


func _reveal_text(local_user_id: String) -> String:
	var reveal: Dictionary = _state.last_reveal
	var choices: Dictionary = reveal["choices"]
	var mine := _choice_label(choices.get(local_user_id, ""))
	var theirs := _choice_label(choices.get(_state.opponent_user_id, ""))
	var outcome := "本轮平局" if reveal["draw"] else "你赢下本轮" if reveal["roundWinnerUserId"] == local_user_id else "对手赢下本轮"
	return "上一轮：你出%s · 对手出%s\n%s" % [mine, theirs, outcome]


static func _choice_label(choice: String) -> String:
	return {"rock": "石头", "paper": "布", "scissors": "剪刀"}.get(choice, "—")


static func _format_label(value: String) -> String:
	return "一局定胜负" if value == "single_round" else "三局两胜" if value == "best_of_three" else "未知赛制"


func _can_resign() -> bool:
	return _state != null and _client != null and not _awaiting_snapshot \
		and _connection_state == "connected" and _state.can_request_resign(_client.local_user_id)


func _resolve_launch_config() -> Dictionary:
	if not _launch_config.is_empty():
		return _validated_config(_launch_config)
	return LaunchConfig.parse(OS.get_cmdline_user_args())


static func _validated_config(config: Dictionary) -> Dictionary:
	if config.size() != 4:
		return {"ok": false}
	for key in config:
		if key not in ["game_id", "match_id", "launch_ticket", "ws_url"] or not config[key] is String:
			return {"ok": false}
	return LaunchConfig.parse(PackedStringArray([
		"--game-id", config["game_id"], "--match-id", config["match_id"],
		"--launch-ticket", config["launch_ticket"], "--ws-url", config["ws_url"],
	]))


func _connect_signals() -> void:
	_client.connection_state_changed.connect(_on_connection_state_changed)
	_client.snapshot_sync_started.connect(_on_snapshot_sync_started)
	_client.snapshot_received.connect(_on_snapshot_received)
	_client.event_received.connect(_on_event_received)
	_client.player_presence_changed.connect(_on_player_presence_changed)
	_client.match_error.connect(_on_match_error)
	_client.return_to_lobby_requested.connect(_on_return_to_lobby_requested)


static func _valid_client(client: Variant) -> bool:
	if client == null:
		return false
	for method in ["start", "poll", "request_choice", "request_resign", "dispose"]:
		if not client.has_method(method):
			return false
	return true


func _show_start_failure() -> void:
	_launch_config.clear()
	_error_text = "无法进入对局，请返回大厅"
	_connection_state = "failed"
	_awaiting_snapshot = true
	set_process(false)
	_refresh_ui()


func _dispose_client() -> void:
	if _disposed:
		return
	_disposed = true
	set_process(false)
	if _client != null:
		_client.dispose()


func _emit_ready_marker() -> void:
	if is_inside_tree() and not _disposed:
		print("GAMEBOX_GODOT_READY game=rps match=%s" % _match_id)


func _log_safe_state(has_state: bool) -> void:
	if _match_id.is_empty():
		return
	var state_revision: int = _state.revision if has_state else -1
	var state_status: String = _state.status if has_state else "loading"
	var round_number: int = _state.round_number if has_state else 0
	var me_locked: bool = _state.me_locked if has_state else false
	var opponent_locked: bool = _state.opponent_locked if has_state else false
	var signature := "%d|%s|%s|%d|%s|%s" % [
		state_revision, state_status, _connection_state, round_number, me_locked, opponent_locked,
	]
	if signature != _last_log_signature:
		_last_log_signature = signature
		print("GAMEBOX_GODOT_STATE match=%s revision=%d status=%s connection=%s" % [
			_match_id, state_revision, state_status, _connection_state,
		])
		print("GAMEBOX_RPS_STATE match=%s revision=%d round=%d me_locked=%s opponent_locked=%s" % [
			_match_id, state_revision, round_number, me_locked, opponent_locked,
		])
	if has_state and state_status in ["finished", "cancelled", "abandoned"] and not _terminal_logged:
		_terminal_logged = true
		var terminal_result := str(_state.result) if _state.result != null else state_status
		print("GAMEBOX_MATCH_RESULT match=%s result=%s" % [_match_id, terminal_result])
