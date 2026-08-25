extends Control

const GameboxTokens = preload("res://design_system/generated/gamebox_tokens.gd")
const LOGICAL_SCALE := 2.0


func _ready() -> void:
	var toggle := _toggle()
	if toggle != null and not toggle.toggled.is_connected(_on_toggled):
		toggle.toggled.connect(_on_toggled)
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED or what == NOTIFICATION_THEME_CHANGED:
		queue_redraw()


func _draw() -> void:
	var toggle := _toggle()
	if toggle == null:
		return
	var track_size := Vector2(
		_scaled(GameboxTokens.SPACING["section"] * 2.0 + GameboxTokens.SPACING["base"]),
		_scaled(GameboxTokens.SPACING["large"])
	)
	var track_position := (size - track_size) * 0.5
	var track_radius := track_size.y * 0.5
	var track_color_name := "track_on" if toggle.button_pressed else "track_off"
	_draw_capsule(Rect2(track_position, track_size), get_theme_color(track_color_name, "GameboxSwitchVisual"))

	var thumb_radius := _scaled(GameboxTokens.SPACING["compact"])
	var thumb_x := track_position.x + (track_size.x - track_radius if toggle.button_pressed else track_radius)
	var thumb_center := Vector2(thumb_x, track_position.y + track_radius)
	var thumb_color_name := "thumb_on" if toggle.button_pressed else "thumb_off"
	draw_circle(thumb_center, thumb_radius, get_theme_color(thumb_color_name, "GameboxSwitchVisual"), true, -1.0, true)


func _draw_capsule(rect: Rect2, color: Color) -> void:
	var radius := rect.size.y * 0.5
	draw_rect(Rect2(rect.position + Vector2(radius, 0.0), Vector2(rect.size.x - radius * 2.0, rect.size.y)), color, true)
	draw_circle(rect.position + Vector2(radius, radius), radius, color, true, -1.0, true)
	draw_circle(rect.position + Vector2(rect.size.x - radius, radius), radius, color, true, -1.0, true)


func _toggle() -> BaseButton:
	var parent := get_parent()
	while parent != null:
		if parent is BaseButton:
			return parent as BaseButton
		parent = parent.get_parent()
	return null


func _on_toggled(_enabled: bool) -> void:
	queue_redraw()


static func _scaled(value: Variant) -> float:
	return float(value) * LOGICAL_SCALE
