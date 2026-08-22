extends Control

var is_loading := false


func _ready() -> void:
	set_loading(false, "")


func set_loading(active: bool, message: String) -> void:
	is_loading = active
	visible = active
	mouse_filter = Control.MOUSE_FILTER_STOP if active else Control.MOUSE_FILTER_IGNORE
	$Content/Message.text = message
