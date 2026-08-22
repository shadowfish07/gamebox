extends RefCounted

const GameboxTheme = preload("res://design_system/gamebox_theme.gd")
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
		{"name": "design system snackbar presents and times out", "run": _snackbar_lifecycle},
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


static func _snackbar_lifecycle() -> bool:
	var snackbar := SnackbarScene.instantiate()
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(snackbar)
	if not _check(snackbar.name == "GameboxSnackbar", "snackbar root path changed") \
		or not _check(snackbar.has_node("Content/Message"), "snackbar message path changed") \
		or not _check(snackbar.has_node("AutoHideTimer"), "snackbar timer path changed"):
		snackbar.free()
		return false
	snackbar.present("这个位置已经有棋子", "error")
	if not _check(snackbar.visible, "snackbar did not show") \
		or not _check((snackbar.get_node("Content/Message") as Label).text == "这个位置已经有棋子", "snackbar copy changed") \
		or not _check(snackbar.tone == "error", "snackbar tone changed"):
		snackbar.free()
		return false
	(snackbar.get_node("AutoHideTimer") as Timer).timeout.emit()
	var result := _check(not snackbar.visible, "snackbar did not hide after its timer")
	snackbar.free()
	return result


static func _confirmation_contract() -> bool:
	var dialog := ConfirmationDialogScene.instantiate() as ConfirmationDialog
	var result := _check(dialog.name == "GameboxConfirmationDialog", "confirmation root path changed") \
		and _check(dialog.dialog_text == "认输后本局立即结束，确认认输吗？", "danger copy changed") \
		and _check(dialog.ok_button_text == "确认认输", "danger confirmation action changed") \
		and _check(dialog.cancel_button_text == "继续对局", "danger cancellation action changed")
	dialog.free()
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
