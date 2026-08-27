extends HBoxContainer

signal back_requested
signal menu_action_requested(action_id: String)

@export var title_text := "游戏"
@export var subtitle_text := ""
@export var action_text := ""
@export var show_action := false

var _menu_items: Dictionary = {}


func _ready() -> void:
	present(title_text, subtitle_text, action_text, show_action)


func present(title: String, subtitle: String = "", action: String = "", action_is_visible: bool = false) -> void:
	title_text = title
	subtitle_text = subtitle
	action_text = action
	show_action = action_is_visible
	$TitleGroup/TitleLabel.text = title_text
	$TitleGroup/SubtitleLabel.text = subtitle_text
	$TitleGroup/SubtitleLabel.visible = not subtitle_text.is_empty()
	$ActionButton.text = action_text
	$ActionButton.visible = show_action and not action_text.is_empty()
	if not $ActionButton.visible:
		close_menu()


func set_subtitle(subtitle: String) -> void:
	subtitle_text = subtitle
	$TitleGroup/SubtitleLabel.text = subtitle_text
	$TitleGroup/SubtitleLabel.visible = not subtitle_text.is_empty()


func set_subtitle_visible(subtitle_is_visible: bool) -> void:
	$TitleGroup/SubtitleLabel.visible = subtitle_is_visible and not subtitle_text.is_empty()


func set_action_visible(action_is_visible: bool) -> void:
	show_action = action_is_visible
	$ActionButton.visible = show_action and not action_text.is_empty()
	if not $ActionButton.visible:
		close_menu()


func set_menu_items(items: Array) -> void:
	var item_container := $MenuLayer/MenuRoot/MenuPanel/Items as VBoxContainer
	for child in item_container.get_children():
		child.free()
	_menu_items.clear()
	for item in items:
		if item is not Dictionary:
			continue
		var action_id := str(item.get("id", ""))
		var label := str(item.get("label", ""))
		if action_id.is_empty() or label.is_empty():
			continue
		var button := Button.new()
		button.name = "MenuItem%s" % _menu_items.size()
		button.text = label
		button.custom_minimum_size.y = $ActionButton.custom_minimum_size.y
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.theme_type_variation = &"GameboxOverflowMenuDangerItem" if bool(item.get("danger", false)) else &"GameboxOverflowMenuItem"
		button.set_meta("action_id", action_id)
		button.pressed.connect(_on_menu_item_pressed.bind(action_id))
		item_container.add_child(button)
		_menu_items[action_id] = button


func set_menu_item_disabled(action_id: String, disabled: bool) -> void:
	var button := _menu_items.get(action_id) as Button
	if button != null:
		button.disabled = disabled


func is_menu_item_disabled(action_id: String) -> bool:
	var button := _menu_items.get(action_id) as Button
	return button == null or button.disabled


func close_menu() -> bool:
	var menu_root := $MenuLayer/MenuRoot as Control
	if not menu_root.visible:
		return false
	menu_root.hide()
	return true


func _on_back_button_pressed() -> void:
	back_requested.emit()


func _on_action_button_pressed() -> void:
	var menu_root := $MenuLayer/MenuRoot as Control
	if menu_root.visible:
		close_menu()
		return
	if _menu_items.is_empty():
		return
	menu_root.theme = _find_host_theme()
	menu_root.show()
	_position_menu.call_deferred()


func _position_menu() -> void:
	var panel := $MenuLayer/MenuRoot/MenuPanel as PanelContainer
	panel.reset_size()
	var action_rect := ($ActionButton as Button).get_global_rect()
	var viewport_size := get_viewport_rect().size
	panel.position = Vector2(
		clampf(action_rect.end.x - panel.size.x, 0.0, viewport_size.x - panel.size.x),
		clampf(action_rect.end.y, 0.0, viewport_size.y - panel.size.y)
	)


func _on_menu_item_pressed(action_id: String) -> void:
	var button := _menu_items.get(action_id) as Button
	if button == null or button.disabled:
		return
	close_menu()
	menu_action_requested.emit(action_id)


func _find_host_theme() -> Theme:
	var ancestor: Node = self
	while ancestor != null:
		if ancestor is Control and (ancestor as Control).theme != null:
			return (ancestor as Control).theme
		ancestor = ancestor.get_parent()
	return null
