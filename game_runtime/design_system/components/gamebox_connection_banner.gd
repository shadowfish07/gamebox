extends PanelContainer

signal return_requested


func _ready() -> void:
	visible = false


func present(state: String, message_override: String = "") -> void:
	var message := ""
	var failed := state in ["failed", "closed"]
	match state:
		"connecting":
			message = "连接中…"
		"reconnecting":
			message = "重连中…"
		"syncing":
			message = "同步中…"
		"failed", "closed":
			message = "连接失败"
		_:
			pass
	if not message_override.is_empty():
		message = message_override
	_apply_tone(failed)
	$Content/Message.text = message
	$Content/ReturnButton.visible = failed
	mouse_filter = Control.MOUSE_FILTER_STOP if failed else Control.MOUSE_FILTER_IGNORE
	visible = not message.is_empty()


func _on_return_button_pressed() -> void:
	return_requested.emit()


func _apply_tone(failed: bool) -> void:
	theme_type_variation = &"GameboxConnectionBannerError" if failed else &"GameboxConnectionBanner"
	$Content/Message.theme_type_variation = &"GameboxOnErrorContainer" if failed else &"GameboxOnSecondaryContainer"
