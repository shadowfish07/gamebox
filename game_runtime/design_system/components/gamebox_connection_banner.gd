extends PanelContainer


func _ready() -> void:
	visible = false


func present(state: String, detail: String = "") -> void:
	var message := ""
	match state:
		"connecting":
			message = "正在连接…"
		"reconnecting":
			message = "正在重新连接…"
		"failed":
			message = "连接失败" if detail.is_empty() else "连接失败 · %s" % detail
		_:
			pass
	$Content/Message.text = message
	visible = not message.is_empty()
