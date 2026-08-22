extends PanelContainer

var tone := "neutral"


func _ready() -> void:
	visible = false


func present(message: String, next_tone: String = "neutral") -> void:
	$AutoHideTimer.stop()
	tone = next_tone
	theme_type_variation = &"GameboxSnackbarError" if tone == "error" else &"GameboxSnackbar"
	$Content/Message.text = message
	visible = not message.is_empty()
	if visible:
		$AutoHideTimer.start()


func _on_auto_hide_timer_timeout() -> void:
	visible = false
