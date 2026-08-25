extends RefCounted

const GameboxTheme = preload("res://design_system/gamebox_theme.gd")
const GameboxTokens = preload("res://design_system/generated/gamebox_tokens.gd")
const BackButtonScene = preload("res://design_system/components/gamebox_back_button.tscn")
const ConnectionBannerScene = preload("res://design_system/components/gamebox_connection_banner.tscn")
const SnackbarScene = preload("res://design_system/components/gamebox_snackbar.tscn")
const ConfirmationDialogScene = preload("res://design_system/components/gamebox_confirmation_dialog.tscn")
const LoadingOverlayScene = preload("res://design_system/components/gamebox_loading_overlay.tscn")
const ResultPanelScene = preload("res://design_system/components/gamebox_result_panel.tscn")


static func cases() -> Array:
	return [
		{"name": "design system back button keeps target copy and states", "run": _back_button_contract},
		{"name": "design system connection banner maps transient states", "run": _connection_states},
		{"name": "design system semantic surfaces resolve paired colors", "run": _semantic_surface_colors},
		{"name": "design system snackbar presents and times out", "run": _snackbar_lifecycle},
		{"name": "design system snackbar passes clicks through its subtree", "run": _snackbar_mouse_passthrough},
		{"name": "design system confirmation dialog states the consequence", "run": _confirmation_contract},
		{"name": "design system loading overlay locks input with visible copy", "run": _loading_contract},
		{"name": "design system result panel maps outcomes and returns", "run": _result_contract},
	]


static func _back_button_contract() -> bool:
	var back := BackButtonScene.instantiate() as Button
	back.theme = GameboxTheme.create(false)
	var result := _check(back.name == "GameboxBackButton", "back root path changed") \
		and _check(back.custom_minimum_size.x >= 96.0 and back.custom_minimum_size.y >= 96.0, "back target below 48dp") \
		and _check(back.text == "← 返回大厅", "back icon or copy changed") \
		and _check(not back.disabled, "back default state is disabled") \
		and _check(back.get_theme_stylebox("normal") != null, "back default style missing") \
		and _check(back.get_theme_stylebox("pressed") != null, "back pressed style missing")
	back.disabled = true
	result = result and _check(back.disabled, "back disabled state did not apply") \
		and _check(back.get_theme_stylebox("disabled") != null, "back disabled style missing")
	back.free()
	return result


static func _connection_states() -> bool:
	var banner := ConnectionBannerScene.instantiate()
	if not _check(banner.name == "GameboxConnectionBanner", "connection root path changed") \
		or not _check(banner.has_node("Content/Message"), "connection message path changed"):
		banner.free()
		return false
	var message := banner.get_node("Content/Message") as Label
	banner.present("connecting", "")
	if not _check(banner.visible and message.text == "正在连接…", "connecting state changed"):
		banner.free()
		return false
	banner.present("reconnecting", "")
	if not _check(banner.visible and message.text == "正在重新连接…", "reconnecting state changed"):
		banner.free()
		return false
	banner.present("failed", "请检查网络后重试")
	if not _check(banner.visible and message.text == "连接失败 · 请检查网络后重试", "failed state changed"):
		banner.free()
		return false
	banner.present("connected", "")
	var result := _check(not banner.visible and message.text.is_empty(), "connected state stayed prominent")
	banner.free()
	return result


static func _semantic_surface_colors() -> bool:
	var tree := Engine.get_main_loop() as SceneTree
	for dark in [false, true]:
		var colors: Dictionary = GameboxTokens.DARK if dark else GameboxTokens.LIGHT
		var theme := GameboxTheme.create(dark)
		var banner := ConnectionBannerScene.instantiate() as PanelContainer
		banner.theme = theme
		tree.root.add_child(banner)
		await tree.process_frame
		var banner_label := banner.get_node("Content/Message") as Label
		var banner_panel := banner.get_theme_stylebox("panel") as StyleBoxFlat
		if not _check(banner_label.get_theme_color("font_color") == colors["on_secondary_container"], "connection foreground drifted") \
			or not _check(banner_panel.bg_color == colors["secondary_container"], "connection background drifted"):
			banner.free()
			return false
		banner.free()

		var snackbar := SnackbarScene.instantiate() as PanelContainer
		snackbar.theme = theme
		tree.root.add_child(snackbar)
		await tree.process_frame
		var snackbar_label := snackbar.get_node("Content/Message") as Label
		var neutral_panel := snackbar.get_theme_stylebox("panel") as StyleBoxFlat
		if not _check(snackbar_label.get_theme_color("font_color") == colors["on_inverse_surface"], "neutral snackbar foreground drifted") \
			or not _check(neutral_panel.bg_color == colors["inverse_surface"], "neutral snackbar background drifted") \
			or not _check(snackbar_label.get_theme_color("font_color") != neutral_panel.bg_color, "neutral snackbar foreground collided with its background"):
			snackbar.free()
			return false
		snackbar.present("", "error")
		var error_panel := snackbar.get_theme_stylebox("panel") as StyleBoxFlat
		if not _check(snackbar_label.get_theme_color("font_color") == colors["on_error_container"], "error snackbar foreground drifted") \
			or not _check(error_panel.bg_color == colors["error_container"], "error snackbar background drifted"):
			snackbar.free()
			return false
		snackbar.free()
	return true


static func _snackbar_lifecycle() -> bool:
	var snackbar := SnackbarScene.instantiate()
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(snackbar)
	var timer := snackbar.get_node("AutoHideTimer") as Timer
	timer.wait_time = 0.12
	if not _check(snackbar.name == "GameboxSnackbar", "snackbar root path changed") \
		or not _check(snackbar.has_node("Content/Message"), "snackbar message path changed") \
		or not _check(snackbar.has_node("AutoHideTimer"), "snackbar timer path changed"):
		snackbar.free()
		return false
	snackbar.present("这个位置已经有棋子", "error")
	if not _check(snackbar.visible, "snackbar did not show") \
		or not _check((snackbar.get_node("Content/Message") as Label).text == "这个位置已经有棋子", "snackbar copy changed") \
		or not _check(snackbar.tone == "error", "snackbar tone changed") \
		or not _check(not timer.is_stopped() and timer.time_left > 0.0, "snackbar timer did not start"):
		snackbar.free()
		return false
	await tree.create_timer(0.04).timeout
	var elapsed_time_left := timer.time_left
	snackbar.present("请稍后重试", "neutral")
	var result := _check(timer.time_left > elapsed_time_left, "repeated present did not restart the snackbar timer") \
		and _check((snackbar.get_node("Content/Message") as Label).text == "请稍后重试", "repeated snackbar copy did not update")
	await tree.create_timer(0.16).timeout
	await tree.process_frame
	result = result and _check(not snackbar.visible, "snackbar did not hide after its real timer") \
		and _check(timer.is_stopped(), "snackbar timer kept running after timeout")
	snackbar.free()
	return result


static func _snackbar_mouse_passthrough() -> bool:
	var tree := Engine.get_main_loop() as SceneTree
	var host := Control.new()
	host.size = Vector2(600.0, 400.0)
	tree.root.add_child(host)
	var underlying_button := Button.new()
	underlying_button.position = Vector2(100.0, 100.0)
	underlying_button.size = Vector2(320.0, 160.0)
	host.add_child(underlying_button)
	var button_hits: Array[int] = []
	underlying_button.pressed.connect(func() -> void: button_hits.append(1))

	var snackbar := SnackbarScene.instantiate() as PanelContainer
	snackbar.position = underlying_button.position
	snackbar.size = underlying_button.size
	host.add_child(snackbar)
	snackbar.present("覆盖按钮但不拦截点击")
	(snackbar.get_node("AutoHideTimer") as Timer).stop()
	var overlay_hits: Array[int] = []
	for control in [snackbar, snackbar.get_node("Content"), snackbar.get_node("Content/Message")]:
		(control as Control).gui_input.connect(func(_event: InputEvent) -> void: overlay_hits.append(1))
	await tree.process_frame
	await _dispatch_click(tree, Vector2(220.0, 180.0))
	var result := _check(button_hits.size() == 1, "visible snackbar subtree blocked the underlying button") \
		and _check(overlay_hits.is_empty(), "visible snackbar subtree handled the underlying button click")
	host.free()
	return result


static func _dispatch_click(tree: SceneTree, position: Vector2) -> void:
	for is_pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.position = position
		event.global_position = position
		event.pressed = is_pressed
		tree.root.push_input(event, true)
		await tree.process_frame


static func _confirmation_contract() -> bool:
	var tree := Engine.get_main_loop() as SceneTree
	var result := true
	for dark in [false, true]:
		var colors: Dictionary = GameboxTokens.DARK if dark else GameboxTokens.LIGHT
		var dialog := ConfirmationDialogScene.instantiate()
		dialog.theme = GameboxTheme.create(dark)
		var host := Control.new()
		host.size = Vector2(1080.0, 2400.0)
		tree.root.add_child(host)
		host.add_child(dialog)
		dialog.open()
		await tree.process_frame
		await tree.process_frame
		var ok_button := dialog.get_node("Dialog/Content/Actions/ConfirmButton") as Button
		var cancel_button := dialog.get_node("Dialog/Content/Actions/CancelButton") as Button
		var panel := dialog.get_node("Dialog") as PanelContainer
		var panel_style := panel.get_theme_stylebox("panel") as StyleBoxFlat
		var scrim := dialog.get_node("Scrim") as PanelContainer
		var scrim_style := scrim.get_theme_stylebox("panel") as StyleBoxFlat
		var confirmed_calls: Array[int] = []
		var cancelled_calls: Array[int] = []
		dialog.confirmed.connect(func() -> void: confirmed_calls.append(1))
		dialog.cancelled.connect(func() -> void: cancelled_calls.append(1))
		result = result and _check(dialog.name == "GameboxConfirmationDialog", "confirmation root path changed") \
			and _check(not (dialog is Window), "confirmation still renders native Window chrome") \
			and _check(dialog.visible and dialog.size == host.size, "confirmation modal does not cover the gameplay viewport") \
			and _check((dialog.get_node("Dialog/Content/Title") as Label).text == "确认认输", "danger title changed") \
			and _check((dialog.get_node("Dialog/Content/Message") as Label).text == "认输后本局立即结束，确认认输吗？", "danger copy changed") \
			and _check(ok_button.text == "确认认输", "danger confirmation action changed") \
			and _check(cancel_button.text == "继续对局", "danger cancellation action changed") \
			and _check(panel_style != null and panel_style.bg_color == colors["surface_container_high"], "confirmation panel surface drifted") \
			and _check(scrim_style != null and scrim_style.bg_color == Color(colors["scrim"], GameboxTokens.COMPONENT["dialog_scrim_opacity"]), "confirmation scrim drifted") \
			and _check(ok_button.size.x >= 96.0 and ok_button.size.y >= 96.0, "confirmation action rendered below minimum target") \
			and _check(cancel_button.size.x >= 96.0 and cancel_button.size.y >= 96.0, "confirmation cancel rendered below minimum target") \
			and _check(ok_button.get_global_rect().has_point(Vector2(640.0, 1230.0)), "large portrait confirm touch point moved")
		cancel_button.pressed.emit()
		await tree.process_frame
		result = result and _check(not dialog.visible and cancelled_calls.size() == 1, "confirmation cancel did not close exactly once") \
			and _check(confirmed_calls.is_empty(), "confirmation cancel emitted confirm")
		dialog.open()
		await tree.process_frame
		await _dispatch_click(tree, Vector2(640.0, 1230.0))
		result = result and _check(not dialog.visible and confirmed_calls.size() == 1, "confirmation accept did not close exactly once")
		host.free()
	return result


static func _loading_contract() -> bool:
	var overlay := LoadingOverlayScene.instantiate()
	if not _check(overlay.name == "GameboxLoadingOverlay", "loading root path changed") \
		or not _check(overlay is PanelContainer, "loading root does not consume the shared panel Theme") \
		or not _check(overlay.theme_type_variation == &"GameboxLoadingOverlay", "loading Theme variation changed") \
		or not _check(overlay.has_node("Content/Progress"), "loading progress path changed") \
		or not _check(overlay.has_node("Content/Message"), "loading message path changed"):
		overlay.free()
		return false
	overlay.set_loading(true, "正在同步对局…")
	if not _check(overlay.visible and overlay.is_loading, "loading state did not show") \
		or not _check(overlay.mouse_filter == Control.MOUSE_FILTER_STOP, "loading state did not lock input") \
		or not _check((overlay.get_node("Content/Message") as Label).text == "正在同步对局…", "loading copy changed"):
		overlay.free()
		return false
	overlay.set_loading(false, "")
	var result := _check(not overlay.visible and not overlay.is_loading, "loading state did not hide") \
		and _check(overlay.mouse_filter == Control.MOUSE_FILTER_IGNORE, "hidden loading state kept input locked")
	overlay.free()
	return result


static func _result_contract() -> bool:
	var panel := ResultPanelScene.instantiate()
	if not _check(panel.name == "GameboxResultPanel", "result root path changed") \
		or not _check(panel.has_node("Content/Result"), "result label path changed") \
		or not _check(panel.has_node("Content/ReturnButton"), "result action path changed"):
		panel.free()
		return false
	var label := panel.get_node("Content/Result") as Label
	for sample in [
		{"status": "finished", "local_won": true, "expected": "你赢了"},
		{"status": "finished", "local_won": false, "expected": "你输了"},
		{"status": "draw", "local_won": false, "expected": "和棋"},
		{"status": "cancelled", "local_won": false, "expected": "对局已取消"},
		{"status": "abandoned", "local_won": false, "expected": "对局已作废"},
	]:
		panel.present(sample["status"], sample["local_won"])
		if not _check(panel.visible and label.text == sample["expected"], "result mapping changed for %s" % sample["status"]):
			panel.free()
			return false
	var return_calls: Array[int] = []
	panel.return_requested.connect(func() -> void: return_calls.append(1))
	(panel.get_node("Content/ReturnButton") as Button).pressed.emit()
	var result := _check(return_calls.size() == 1, "result return signal did not fire exactly once") \
		and _check((panel.get_node("Content/ReturnButton") as Button).text == "返回大厅", "result action copy changed")
	panel.free()
	return result


static func _check(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition
