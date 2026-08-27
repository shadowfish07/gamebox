extends PanelContainer


func _ready() -> void:
	visible = false


func present(state: String, detail: String = "") -> void:
	var message := ""
	var failed := state in ["failed", "closed"]
	match state:
		"connecting":
			message = "正在连接…"
		"reconnecting":
			message = "正在重新连接…"
		"failed":
			message = "连接失败" if detail.is_empty() else "连接失败 · %s" % detail
		_:
			pass
	_apply_tone(failed)
	$AutoHideTimer.stop()
	$Content/Message.text = message
	visible = not message.is_empty()


func present_recovery(state: String, detail: String = "") -> void:
	var title := ""
	var failed := state in ["failed", "closed"]
	match state:
		"connecting":
			title = "正在连接…"
		"reconnecting":
			title = "正在恢复连接"
		"syncing":
			title = "连接已恢复"
		"restored":
			title = "已恢复对局"
		"failed", "closed":
			title = "连接失败"
		_:
			pass
	_apply_tone(failed)
	$AutoHideTimer.stop()
	$Content/Message.text = title if detail.is_empty() else "%s\n%s" % [title, detail]
	visible = not title.is_empty()
	if state == "restored" and visible and is_inside_tree():
		$AutoHideTimer.start()


func _on_auto_hide_timer_timeout() -> void:
	visible = false


func _apply_tone(failed: bool) -> void:
	theme_type_variation = &"GameboxSnackbarError" if failed else &"GameboxConnectionBanner"
	$Content/Message.theme_type_variation = &"GameboxOnErrorContainer" if failed else &"GameboxOnSecondaryContainer"
