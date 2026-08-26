extends PanelContainer

signal return_requested


func _ready() -> void:
	visible = false


func present(status: String, local_won: bool) -> void:
	var message := ""
	match status:
		"finished":
			message = "你赢了" if local_won else "你输了"
		"won":
			message = "你赢了"
		"lost":
			message = "你输了"
		"draw":
			message = "和棋"
		"cancelled":
			message = "对局已取消"
		"abandoned":
			message = "对局已作废"
		_:
			pass
	$Content/Result.text = message
	visible = not message.is_empty()


func _on_return_button_pressed() -> void:
	return_requested.emit()
