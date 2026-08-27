extends Control

const LaunchConfig = preload("res://core/launch_config.gd")
const MatchClient = preload("res://core/match_client.gd")
const RpsState = preload("res://games/rps/rps_state.gd")
const GameboxTheme = preload("res://design_system/gamebox_theme.gd")
const GameboxTokens = preload("res://design_system/generated/gamebox_tokens.gd")
const CHOICE_SELECTED_SCALE := Vector2(0.92, 0.92)
const REVEAL_DURATION_MS := 1600
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
var _reveal_until_ms := 0
var _reveal_key := ""


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
	var dark_theme := GameboxTheme.system_prefers_dark()
	theme = GameboxTheme.create(dark_theme)
	var colors: Dictionary = GameboxTokens.DARK if dark_theme else GameboxTokens.LIGHT
	$SafeContent/Layout.add_theme_constant_override("separation", GameboxTokens.SPACING["layout"] * GameboxTheme.LOGICAL_SCALE)
	$SafeContent/Layout/MySection/ChoicePanel/Choices.add_theme_constant_override("separation", GameboxTokens.SPACING["layout"] * GameboxTheme.LOGICAL_SCALE)
	$ResultScrim.color = Color(colors["scrim"], GameboxTokens.COMPONENT["dialog_scrim_opacity"])
	$SafeContent/Layout/OpponentSection/StatusLine/StatusChip.add_theme_stylebox_override("panel", _chip_style(colors))
	$SafeContent/Layout/MySection/StatusLine/StatusChip.add_theme_stylebox_override("panel", _chip_style(colors))
	for status_line in [$SafeContent/Layout/OpponentSection/StatusLine, $SafeContent/Layout/MySection/StatusLine]:
		status_line.get_node("Identity/Avatar").add_theme_stylebox_override("panel", _avatar_style(colors))
		status_line.get_node("Identity/Avatar/Label").add_theme_color_override("font_color", colors["on_primary_container"])
		status_line.get_node("Identity/Label").add_theme_color_override("font_color", colors["on_surface_variant"])
		status_line.get_node("StatusChip/Content/Label").add_theme_color_override("font_color", colors["on_surface_variant"])
		status_line.get_node("StatusChip/Content/DotSlot/Dot").add_theme_stylebox_override("panel", _status_dot_style(colors))
	$SafeContent/Layout/OpponentSection/OpponentVisual/UnknownSurface.add_theme_stylebox_override(
		"panel", _opponent_surface_style(colors["surface_container_high"], colors["outline_variant"])
	)
	$SafeContent/Layout/OpponentSection/OpponentVisual/LockedSurface.add_theme_stylebox_override(
		"panel", _opponent_surface_style(colors["tertiary_container"], colors["on_tertiary_container"])
	)
	$RevealPanel/Content.add_theme_constant_override("separation", GameboxTokens.SPACING["section"] * GameboxTheme.LOGICAL_SCALE)
	$RevealPanel/Content/Choices.add_theme_constant_override("separation", GameboxTokens.SPACING["layout"] * GameboxTheme.LOGICAL_SCALE)
	$RevealPanel/Content/ResultLabel.add_theme_font_size_override(
		"font_size", GameboxTokens.TYPOGRAPHY["headline_small"]["font_size"] * GameboxTheme.LOGICAL_SCALE
	)
	for button in [$SafeContent/Layout/TopNavigation/BackButton, $SafeContent/Layout/TopNavigation/MoreButton]:
		button.add_theme_color_override("font_color", colors["on_surface"])
		button.add_theme_color_override("font_hover_color", colors["on_surface"])
		button.add_theme_color_override("font_pressed_color", colors["on_surface"])
	$SafeContent/Layout/TopNavigation/BackButton.pressed.connect(_on_back_pressed)
	$SafeContent/Layout/TopNavigation/MoreButton.pressed.connect(_on_resign_pressed)
	for entry in _choice_entries():
		var button: Button = entry["button"]
		button.get_node("Content").add_theme_constant_override("separation", GameboxTokens.SPACING["base"])
		button.pressed.connect(_on_choice.bind(entry["choice"]))
		button.button_down.connect(_on_choice_button_down.bind(button))
		button.button_up.connect(_on_choice_button_up.bind(button))
		button.get_node("Content/Indicator").color = colors["primary"]
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
	if _reveal_until_ms > 0 and Time.get_ticks_msec() >= _reveal_until_ms:
		_reveal_until_ms = 0
		_refresh_ui()


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


func _on_choice_button_down(button: Button) -> void:
	if not button.disabled:
		button.pivot_offset = button.size * 0.5
		button.scale = CHOICE_SELECTED_SCALE


func _on_choice_button_up(button: Button) -> void:
	button.scale = CHOICE_SELECTED_SCALE if _selected_choice() == _choice_for_button(button) else Vector2.ONE


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
	if _state != null and _state.last_reveal is Dictionary:
		_start_reveal(_state.last_reveal)
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
	$ConnectionBanner.present(_connection_state, "网络波动，正在恢复对局…\n已确认的出拳状态会保留")
	$ErrorSnackbar.present(_error_text, "error")
	$LoadingOverlay.set_loading(not has_state or _awaiting_snapshot, "正在同步对局…")
	$SafeContent/Layout/TopNavigation/TitleGroup/FormatLabel.text = _format_label(_state.format) if has_state else "赛制加载中"
	$SafeContent/Layout/RoundStage/Content/ScoreLabel.text = "你 %d  VS  %d 对手" % [_state.me_score, _state.opponent_score] if has_state else "你 0  VS  0 对手"
	$SafeContent/Layout/RoundStage/Content/RoundLabel.text = "最终结果" if terminal else "第 %d 轮" % _state.round_number if has_state else "准备对局"
	$SafeContent/Layout/RoundStage/Content/StateLabel.text = _status_text(local_user_id) if has_state else "正在同步对局…"
	$SafeContent/Layout/RoundStage/Content/StateSupportLabel.text = _status_support(local_user_id) if has_state else "收到权威快照前无法操作"
	_refresh_player_statuses(has_state, terminal)
	_refresh_reveal(has_state)
	var can_choose: bool = has_state and not terminal and not _awaiting_snapshot \
		and _connection_state == "connected" and not _is_revealing() and _state.can_request_choice("rock", local_user_id)
	for entry in _choice_entries():
		entry["button"].disabled = not can_choose
	_refresh_choice_visuals()
	$SafeContent/Layout/MySection/ChoicePanel.visible = not terminal and _selected_choice().is_empty() and not _is_revealing()
	$SafeContent/Layout/MySection/SelectedPanel.visible = not terminal and not _selected_choice().is_empty() and not _is_revealing()
	$ResignButton.visible = has_state and not terminal and not _is_revealing() and _state.can_request_resign(local_user_id)
	$ResignButton.disabled = _connection_state != "connected" or _awaiting_snapshot or _resign_submitted
	if terminal and not _is_revealing():
		$ResignDialog.close()
		$ResultPanel.present(_state.status, _state.winner_user_id == local_user_id)
		$ResultPanel/Content/Details.text = "%s · 最终比分 你 %d VS %d 对手" % [_format_label(_state.format), _state.me_score, _state.opponent_score]
		$ResultScrim.visible = true
	else:
		$ResultPanel.present("", false)
		$ResultScrim.visible = false
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
		return "你的选择已锁定"
	if _state.opponent_locked:
		return "对手已经准备好"
	return "选择你的手势"


func _opponent_text() -> String:
	if _state.opponent_locked:
		return "已出拳 · 保密"
	return "等待出拳"


func _status_support(local_user_id: String) -> String:
	if _state.status == "finished":
		return "最终比分已确认"
	if _state.status in ["cancelled", "abandoned"]:
		return "返回游戏大厅"
	if not _state.pending_action.is_empty():
		return "服务器确认前不会视为最终出拳"
	if _state.me_locked:
		return "等待对手后同时揭晓"
	if _state.opponent_locked:
		return "选择石头、剪刀或布"
	return "手势会在双方锁定后同时揭晓"


func _refresh_player_statuses(has_state: bool, terminal: bool) -> void:
	var opponent_status := "恢复中" if _awaiting_snapshot or _connection_state != "connected" else _opponent_text() if has_state else "等待"
	var my_status := "恢复中" if _awaiting_snapshot or _connection_state != "connected" else "终局" if terminal else "提交中" if has_state and not _state.pending_action.is_empty() else "已出拳" if has_state and _state.me_locked else "等待"
	$SafeContent/Layout/OpponentSection/StatusLine/StatusChip/Content/Label.text = opponent_status
	$SafeContent/Layout/MySection/StatusLine/StatusChip/Content/Label.text = my_status
	var locked: bool = has_state and _state.opponent_locked and not _is_revealing()
	$SafeContent/Layout/OpponentSection/OpponentVisual/Unknown.visible = not locked
	$SafeContent/Layout/OpponentSection/OpponentVisual/Locked.visible = locked
	$SafeContent/Layout/OpponentSection/OpponentVisual/UnknownSurface.visible = not locked
	$SafeContent/Layout/OpponentSection/OpponentVisual/LockedSurface.visible = locked
	var selected := _selected_choice()
	if not selected.is_empty():
		$SafeContent/Layout/MySection/SelectedPanel/Icon.texture = _choice_texture(selected)
		$SafeContent/Layout/MySection/SelectedPanel/Label.text = "你出了%s" % _choice_label(selected)
		$SafeContent/Layout/MySection/SelectedPanel/Status.text = "正在锁定你的选择…" if not _state.pending_action.is_empty() else "已出拳 · 等待同时揭晓"


func _refresh_choice_visuals() -> void:
	var selected_choice := _selected_choice()
	var full_color: Color = GameboxTokens.DARK["on_surface"] if GameboxTheme.system_prefers_dark() else GameboxTokens.LIGHT["on_surface"]
	var faded_alpha: float = full_color.a - float(GameboxTokens.GAME["pending_overlay_alpha"])
	for entry in _choice_entries():
		var button: Button = entry["button"]
		var selected: bool = entry["choice"] == selected_choice
		var choice_color := full_color
		if not selected and not selected_choice.is_empty():
			choice_color.a = faded_alpha
		button.pivot_offset = button.size * 0.5
		button.scale = CHOICE_SELECTED_SCALE if selected else Vector2.ONE
		button.modulate = choice_color
		button.get_node("Content/Indicator").visible = selected


func _refresh_reveal(has_state: bool) -> void:
	var reveal: Variant = _state.last_reveal if has_state else null
	$RevealPanel.visible = reveal is Dictionary and _is_revealing()
	if not reveal is Dictionary:
		return
	var choices: Dictionary = reveal["choices"]
	var my_choice: String = choices[_state.me_user_id]
	var opponent_choice: String = choices[_state.opponent_user_id]
	$RevealPanel/Content/Choices/MyChoice/Icon.texture = _choice_texture(my_choice)
	$RevealPanel/Content/Choices/MyChoice/Label.text = "你 · %s" % _choice_label(my_choice)
	$RevealPanel/Content/Choices/OpponentChoice/Icon.texture = _choice_texture(opponent_choice)
	$RevealPanel/Content/Choices/OpponentChoice/Label.text = "对手 · %s" % _choice_label(opponent_choice)
	$RevealPanel/Content/ResultLabel.text = "本轮平局" if reveal["draw"] else \
		"本轮获胜" if reveal["roundWinnerUserId"] == _state.me_user_id else "本轮落败"
	$RevealPanel/Content/ReasonLabel.text = _reveal_reason(my_choice, opponent_choice, bool(reveal["draw"]))


func _start_reveal(reveal: Dictionary) -> void:
	# A later lock event retains the previous round's reveal in its snapshot.
	# Deduplicate by revealed round, not snapshot revision, so that old overlay
	# cannot disable the opponent's choice controls in the next round.
	var key := str(reveal.get("round", ""))
	if key == _reveal_key:
		return
	_reveal_key = key
	_reveal_until_ms = Time.get_ticks_msec() + REVEAL_DURATION_MS
	var panel: Control = $RevealPanel
	panel.modulate.a = 0.0
	var tween := create_tween()
	tween.tween_property(panel, "modulate:a", 1.0, float(GameboxTokens.MOTION["slow"]) / 1000.0)


func _is_revealing() -> bool:
	return _reveal_until_ms > Time.get_ticks_msec()


static func _reveal_reason(my_choice: String, opponent_choice: String, draw: bool) -> String:
	if draw:
		return "都是%s · 平局不计分，再来一轮" % _choice_label(my_choice)
	var pair := "%s:%s" % [my_choice, opponent_choice]
	if pair in ["rock:scissors", "scissors:rock"]:
		return "石头砸碎剪刀。"
	if pair in ["scissors:paper", "paper:scissors"]:
		return "剪刀剪开布。"
	if pair in ["paper:rock", "rock:paper"]:
		return "布包住石头。"
	return "比分已更新"


func _chip_style(colors: Dictionary) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = colors["surface_container_high"]
	style.content_margin_left = 20
	style.content_margin_right = 20
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	var radius := roundi(GameboxTokens.SHAPE["full"] * GameboxTheme.LOGICAL_SCALE)
	style.corner_radius_top_left = radius
	style.corner_radius_top_right = radius
	style.corner_radius_bottom_left = radius
	style.corner_radius_bottom_right = radius
	return style


func _avatar_style(colors: Dictionary) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = colors["primary_container"]
	var radius := 20
	style.corner_radius_top_left = radius
	style.corner_radius_top_right = radius
	style.corner_radius_bottom_left = radius
	style.corner_radius_bottom_right = radius
	return style


func _status_dot_style(colors: Dictionary) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = colors["outline"]
	var radius := 7
	style.corner_radius_top_left = radius
	style.corner_radius_top_right = radius
	style.corner_radius_bottom_left = radius
	style.corner_radius_bottom_right = radius
	return style


func _opponent_surface_style(fill: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.border_width_left = 2
	style.border_width_top = 2
	style.border_width_right = 2
	style.border_width_bottom = 2
	var radius := 180
	style.corner_radius_top_left = radius
	style.corner_radius_top_right = radius
	style.corner_radius_bottom_left = radius
	style.corner_radius_bottom_right = radius
	return style


func _choice_texture(choice: String) -> Texture2D:
	for entry in _choice_entries():
		if entry["choice"] == choice:
			return entry["button"].get_node("Content/Icon").texture
	return null


static func _choice_label(choice: String) -> String:
	return {"rock": "石头", "scissors": "剪刀", "paper": "布"}.get(choice, "未知")


func _selected_choice() -> String:
	if _state == null:
		return ""
	if _state.pending_action.get("type", "") == "rps.choice.requested":
		return str(_state.pending_action.get("choice", ""))
	if _state.me_locked and _state.me_choice is String:
		return _state.me_choice
	return ""


func _choice_entries() -> Array:
	return [
		{"choice": "rock", "button": $SafeContent/Layout/MySection/ChoicePanel/Choices/RockButton},
		{"choice": "scissors", "button": $SafeContent/Layout/MySection/ChoicePanel/Choices/ScissorsButton},
		{"choice": "paper", "button": $SafeContent/Layout/MySection/ChoicePanel/Choices/PaperButton},
	]


static func _choice_for_button(button: Button) -> String:
	return {
		"RockButton": "rock",
		"ScissorsButton": "scissors",
		"PaperButton": "paper",
	}.get(str(button.name), "")


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
	var reveal_visible: bool = $RevealPanel.visible
	var opponent_choice_visible: bool = reveal_visible and has_state \
		and _state.last_reveal is Dictionary \
		and _state.last_reveal["round"] == _state.round_number
	var signature := "%d|%s|%s|%d|%s|%s|%s|%s" % [
		state_revision, state_status, _connection_state, round_number, me_locked, opponent_locked,
		opponent_choice_visible, reveal_visible,
	]
	if signature != _last_log_signature:
		_last_log_signature = signature
		print("GAMEBOX_GODOT_STATE match=%s revision=%d status=%s connection=%s" % [
			_match_id, state_revision, state_status, _connection_state,
		])
		print("GAMEBOX_RPS_STATE match=%s revision=%d round=%d me_locked=%s opponent_locked=%s" % [
			_match_id, state_revision, round_number, me_locked, opponent_locked,
		])
		print("GAMEBOX_RPS_PRESENTATION match=%s revision=%d opponent_choice_visible=%s reveal_visible=%s" % [
			_match_id, state_revision, opponent_choice_visible, reveal_visible,
		])
	if has_state and state_status in ["finished", "cancelled", "abandoned"] and not _terminal_logged:
		_terminal_logged = true
		var terminal_result := str(_state.result) if _state.result != null else state_status
		print("GAMEBOX_MATCH_RESULT match=%s result=%s" % [_match_id, terminal_result])
