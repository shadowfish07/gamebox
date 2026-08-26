extends Control

signal confirmed
signal cancelled


func _ready() -> void:
	visible = false


func open() -> void:
	visible = true
	$Dialog/Content/Actions/CancelButton.grab_focus()


func close() -> void:
	visible = false


func _on_cancel_pressed() -> void:
	close()
	cancelled.emit()


func _on_confirm_pressed() -> void:
	close()
	confirmed.emit()
