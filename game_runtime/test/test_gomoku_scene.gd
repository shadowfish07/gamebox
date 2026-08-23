extends RefCounted

const GomokuScene = preload("res://games/gomoku/gomoku_scene.tscn")
const GomokuState = preload("res://games/gomoku/gomoku_state.gd")
const MatchClient = preload("res://core/match_client.gd")
const Protocol = preload("res://core/protocol.gd")

const MATCH_ID := "11111111-1111-4111-8111-111111111111"
const BLACK_ID := "22222222-2222-4222-8222-222222222222"
const WHITE_ID := "33333333-3333-4333-8333-333333333333"
const ACTION_ID := "44444444-4444-4444-8444-444444444444"


static func cases() -> Array:
	return [
		{"name": "gomoku scene consumes the lightweight Gamebox shell", "run": _uses_lightweight_shell},
		{"name": "gomoku scene renders connection turns and safe errors", "run": _renders_live_states},
		{"name": "gomoku scene keeps required return guidance after Snackbar timeout", "run": _keeps_required_return_guidance},
		{"name": "gomoku scene hides the internal board revision", "run": _hides_internal_revision},
		{"name": "gomoku scene renders every terminal outcome", "run": _renders_terminal_states},
		{"name": "gomoku scene blocks actions while stale snapshot is pending", "run": _blocks_stale_actions},
		{"name": "gomoku scene ignores non-authoritative snapshot callbacks while locked", "run": _ignores_non_authoritative_snapshots},
		{"name": "gomoku scene keeps reconnect locked until authoritative snapshot", "run": _keeps_reconnect_locked},
		{"name": "gomoku scene locks immediately when real client requests snapshot recovery", "run": _locks_real_snapshot_recovery},
		{"name": "gomoku scene gates resign and keeps back non-destructive", "run": _gates_resign_and_back},
		{"name": "gomoku keyboard Escape closes resign before returning", "run": _escape_cancel_closes_dialog_first},
		{"name": "gomoku Android go-back closes resign before returning", "run": _android_go_back_closes_dialog_first},
		{"name": "gomoku terminal return stays non-destructive", "run": _terminal_return_is_non_destructive},
		{"name": "gomoku scene wires move once and shows pending marker", "run": _wires_move_once},
		{"name": "gomoku scene keeps fixed portrait board and touch targets", "run": _keeps_portrait_touch_layout},
		{"name": "gomoku ready marker waits for one drawn frame and cancels safely", "run": _waits_for_drawn_frame_marker},
		{"name": "gomoku scene disposes client and callbacks once", "run": _disposes_once},
	]


static func _uses_lightweight_shell() -> bool:
	var harness: Dictionary = await _scene_harness(BLACK_ID)
	var scene: Control = harness["scene"]
	var required_paths := [
		"Background", "BackButton", "TitleLabel", "StatusLabel", "ConnectionLabel", "Board",
		"ColorLabel", "ErrorLabel", "ResignButton", "ResignDialog", "LoadingOverlay", "ResultPanel",
	]
	for path in required_paths:
		if not _check(scene.has_node(path), "lightweight shell node path missing: %s" % path):
			return _cleanup(scene)
	var back := scene.get_node("BackButton") as Button
	var connection := scene.get_node("ConnectionLabel")
	var snackbar := scene.get_node("ErrorLabel")
	var dialog := scene.get_node("ResignDialog") as ConfirmationDialog
	var loading := scene.get_node("LoadingOverlay")
	var result_panel := scene.get_node("ResultPanel")
	var result := _check(scene.theme != null and scene.theme.get_type_list().has("GameboxConnectionBanner"), "shared Gamebox Theme is not applied") \
		and _check(scene.get_node("Background") is PanelContainer, "background does not use the public surface Theme") \
		and _check(back.text == "← 返回大厅", "shared return control copy changed") \
		and _check(back.custom_minimum_size.x >= 96.0 and back.custom_minimum_size.y >= 96.0, "shared return target is below 48dp") \
		and _check(connection.has_method("present") and connection.has_node("Content/Message"), "public connection component is not mounted") \
		and _check(snackbar.has_method("present") and snackbar.has_node("AutoHideTimer"), "public Snackbar component is not mounted") \
		and _check(dialog.dialog_text == "认输后本局立即结束，确认认输吗？", "danger consequence copy changed") \
		and _check(dialog.ok_button_text == "确认认输" and dialog.cancel_button_text == "继续对局", "danger actions changed") \
		and _check(loading.has_method("set_loading") and loading.has_node("Content/Message"), "public loading component is not mounted") \
		and _check(result_panel.has_method("present") and result_panel.has_node("Content/ReturnButton"), "public result component is not mounted") \
		and _check(scene.get_node("Board").has_signal("cell_pressed"), "cell_pressed automation contract changed") \
		and _check(InputMap.has_action("ui_cancel"), "ui_cancel input action changed")
	return _cleanup(scene, result)


static func _hides_internal_revision() -> bool:
	var harness: Dictionary = await _scene_harness(BLACK_ID)
	var scene: Control = harness["scene"]
	return _cleanup(scene, _check(not scene.has_node("RevisionLabel"), "internal board revision is visible to players"))


static func _renders_live_states() -> bool:
	var harness: Dictionary = await _scene_harness(BLACK_ID)
	var scene: Control = harness["scene"]
	var client: FakeMatchClient = harness["client"]
	if not _check(_has_lightweight_nodes(scene), "live-state components are missing"):
		return _cleanup(scene)
	if not _check(_status(scene) == "连接中", "initial connecting copy changed") \
		or not _check(_connection_visible(scene) and _connection_message(scene) == "正在连接…", "initial connection banner changed") \
		or not _check(_loading_visible(scene), "initial connection did not show loading"):
		return _cleanup(scene)
	client.set_connection("connected")
	if not _check(_status(scene) == "正在同步对局…", "platform connected exposed a turn before initial snapshot") \
		or not _check(not _connection_visible(scene), "connected state left the connection banner visible") \
		or not _check(_loading_visible(scene), "initial snapshot wait hid loading"):
		return _cleanup(scene)
	client.set_connection("reconnecting")
	if not _check(_status(scene) == "重连中", "reconnecting copy changed") \
		or not _check(_connection_visible(scene) and _connection_message(scene) == "正在重新连接…", "reconnecting banner changed"):
		return _cleanup(scene)
	client.accept_snapshot(_snapshot(0))
	if not _check(_status(scene) == "轮到我", "local turn copy changed") \
		or not _check((scene.get_node("Board") as Control).mouse_filter == Control.MOUSE_FILTER_STOP, "board not interactive on local turn") \
		or not _check(not _connection_visible(scene), "fresh snapshot left a connection banner visible") \
		or not _check(not _loading_visible(scene), "fresh snapshot left loading visible"):
		return _cleanup(scene)
	var one_stone := _empty_board()
	one_stone[0] = 1
	client.accept_snapshot(_snapshot(1, one_stone, "active", "white"))
	if not _check(_status(scene) == "等待对手", "opponent turn copy changed"):
		return _cleanup(scene)
	client.emit_error("cell_occupied")
	if not _check(_error(scene) == "这个位置已经有棋子" and _error_visible(scene), "cell occupied Snackbar changed"):
		return _cleanup(scene)
	client.emit_error("stale_revision")
	if not _check(_error(scene) == "棋盘已更新，正在同步", "stale revision copy changed"):
		return _cleanup(scene)
	client.accept_snapshot(_snapshot(1, one_stone, "active", "white"))
	if not _check(_error(scene).is_empty() and not _error_visible(scene), "authoritative snapshot did not clear stale error"):
		return _cleanup(scene)
	client.set_connection("failed")
	var result := _check(_connection_visible(scene) and _connection_message(scene) == "连接失败 · 连接已断开", "failed connection banner changed") \
		and _check((scene.get_node("Board") as Control).mouse_filter == Control.MOUSE_FILTER_IGNORE, "failed connection left board input enabled")
	return _cleanup(scene, result)


static func _keeps_required_return_guidance() -> bool:
	var harness: Dictionary = await _scene_harness(BLACK_ID)
	var scene: Control = harness["scene"]
	var client: FakeMatchClient = harness["client"]
	var quit_calls: Array[int] = harness["quit_calls"]
	var snackbar_timer := scene.get_node("ErrorLabel/AutoHideTimer") as Timer
	snackbar_timer.wait_time = 0.05
	client.accept_snapshot(_snapshot(0))
	client.require_return("resume_expired")
	var safe_guidance := "登录状态已失效，请返回大厅"
	if not _check(_error_visible(scene) and _error(scene) == safe_guidance, "required-return Snackbar did not show safe guidance") \
		or not _check(not _status(scene).contains("resume_expired"), "required-return status exposed a raw code"):
		return _cleanup(scene)
	await (Engine.get_main_loop() as SceneTree).create_timer(0.08).timeout
	await (Engine.get_main_loop() as SceneTree).process_frame
	if not _check(not _error_visible(scene), "required-return Snackbar did not complete its real timeout") \
		or not _check(_status(scene) == safe_guidance, "required-return guidance disappeared with its Snackbar"):
		return _cleanup(scene)
	var back := scene.get_node("BackButton") as Button
	if not _check(back.visible and not back.disabled, "required-return state disabled the visible Back control") \
		or not _check(quit_calls.is_empty(), "required-return guidance auto-returned before player input"):
		return _cleanup(scene)
	back.pressed.emit()
	var result := _check(quit_calls.size() == 1, "required-return Back did not return exactly once") \
		and _check(not _status(scene).contains("resume_expired"), "required-return UI exposed the raw return code")
	return _cleanup(scene, result)


static func _renders_terminal_states() -> bool:
	var five := _five_board()
	if not await _assert_terminal(BLACK_ID, _snapshot(9, five, "finished", "white", "five", BLACK_ID), "你赢了"):
		return false
	if not await _assert_terminal(WHITE_ID, _snapshot(9, five, "finished", "white", "five", BLACK_ID), "你输了"):
		return false
	if not await _assert_terminal(BLACK_ID, _snapshot(225, _draw_board(), "finished", "white", "draw", null), "和棋"):
		return false
	if not await _assert_terminal(BLACK_ID, _snapshot(1, _empty_board(), "cancelled", "black", null, null), "对局已取消"):
		return false
	return await _assert_terminal(BLACK_ID, _snapshot(1, _empty_board(), "abandoned", "black", null, null), "对局已作废")


static func _blocks_stale_actions() -> bool:
	var harness: Dictionary = await _scene_harness(BLACK_ID)
	var scene: Control = harness["scene"]
	var client: FakeMatchClient = harness["client"]
	client.accept_snapshot(_snapshot(0))
	client.emit_error("stale_revision")
	scene._on_cell_pressed(7, 7)
	if not _check(client.move_requests.is_empty(), "stale state accepted a move before snapshot"):
		return _cleanup(scene)
	client.accept_snapshot(_snapshot(0))
	scene._on_cell_pressed(7, 7)
	return _cleanup(scene, _check(client.move_requests == [Vector2i(7, 7)], "fresh snapshot did not restore move input"))


static func _ignores_non_authoritative_snapshots() -> bool:
	var older_harness: Dictionary = await _scene_harness(BLACK_ID)
	var older_scene: Control = older_harness["scene"]
	var older_client: FakeMatchClient = older_harness["client"]
	older_client.accept_snapshot(_snapshot(2, _two_stone_board(), "active", "black"))
	older_client.begin_snapshot_sync()
	older_client.emit_snapshot_raw(_snapshot(0))
	if not (_check(_status(older_scene) == "正在同步对局…", "older snapshot callback unlocked controller") \
		and _check(older_scene.get_node("ResignButton").disabled, "older snapshot callback unlocked resign")):
		return _cleanup(older_scene)
	_cleanup(older_scene, true)

	var invalid_harness: Dictionary = await _scene_harness(BLACK_ID)
	var invalid_scene: Control = invalid_harness["scene"]
	var invalid_client: FakeMatchClient = invalid_harness["client"]
	invalid_client.accept_snapshot(_snapshot(2, _two_stone_board(), "active", "black"))
	invalid_client.begin_snapshot_sync()
	invalid_client.emit_snapshot_raw({"type": "platform.snapshot"})
	var result := _check(_status(invalid_scene) == "同步失败，请返回大厅", "invalid snapshot did not keep required-return guidance") \
		and _check((invalid_scene.get_node("Board") as Control).mouse_filter == Control.MOUSE_FILTER_IGNORE, "invalid snapshot callback unlocked board input") \
		and _check(invalid_scene.get_node("ResignButton").disabled, "invalid snapshot callback unlocked resign")
	return _cleanup(invalid_scene, result)


static func _keeps_reconnect_locked() -> bool:
	var harness: Dictionary = await _scene_harness(BLACK_ID)
	var scene: Control = harness["scene"]
	var client: FakeMatchClient = harness["client"]
	if not _check(_has_lightweight_nodes(scene), "reconnect components are missing"):
		return _cleanup(scene)
	var two_stones := _empty_board()
	two_stones[0] = 1
	two_stones[1] = 2
	var active := _snapshot(2, two_stones, "active", "black")
	client.accept_snapshot(active)
	if not (_check(_status(scene) == "轮到我", "pre-reconnect local turn missing") \
		and _check(scene.get_node("ResignButton").visible and not scene.get_node("ResignButton").disabled, "pre-reconnect resign should be enabled")):
		return _cleanup(scene)

	client.set_connection("reconnecting")
	scene._on_cell_pressed(7, 7)
	scene._on_resign_pressed()
	if not (_check(_status(scene) == "重连中", "reconnecting copy changed") \
		and _check(client.move_requests.is_empty(), "reconnecting state accepted a move") \
		and _check(scene.get_node("ResignButton").disabled, "reconnecting state enabled resign") \
		and _check(not scene.get_node("ResignDialog").visible, "reconnecting state opened resign confirmation") \
		and _check(client.resign_requests == 0, "reconnecting state submitted resignation")):
		return _cleanup(scene)

	client.set_connection("connected")
	client.set_connection("connected")
	scene._on_cell_pressed(7, 7)
	if not (_check(_status(scene) == "正在同步对局…", "connected-before-snapshot exposed a turn") \
		and _check(client.move_requests.is_empty(), "connected-before-snapshot accepted a move") \
		and _check(scene.get_node("ResignButton").disabled, "connected-before-snapshot enabled resign")):
		return _cleanup(scene)

	client.accept_snapshot(active)
	if not (_check(_status(scene) == "轮到我", "authoritative snapshot did not unlock turn") \
		and _check(not scene.get_node("ResignButton").disabled, "authoritative snapshot did not unlock resign")):
		return _cleanup(scene)
	scene._on_cell_pressed(7, 7)
	if not _check(client.move_requests == [Vector2i(7, 7)], "unlocked scene did not send move"):
		return _cleanup(scene)

	client.accept_snapshot(_snapshot(9, _five_board(), "finished", "white", "five", BLACK_ID))
	client.set_connection("reconnecting")
	client.set_connection("connected")
	scene._on_cell_pressed(8, 8)
	var result := _check(_status(scene) == "你赢了", "terminal copy was hidden by reconnect sync") \
		and _check(not scene.get_node("ResignButton").visible, "terminal reconnect showed resign") \
		and _check(client.move_requests == [Vector2i(7, 7)], "terminal reconnect accepted another move")
	return _cleanup(scene, result)


static func _locks_real_snapshot_recovery() -> bool:
	var tree := Engine.get_main_loop() as SceneTree
	var transport := ControllerTransport.new()
	var scheduler := ControllerScheduler.new()
	var client = MatchClient.new(transport, scheduler, ControllerRandom.new())
	var scene: Control = GomokuScene.instantiate()
	scene.configure_launch(_launch_config())
	scene.set_match_client_factory(func() -> Variant: return client)
	scene.set_quit_callback(func() -> void: pass)
	tree.root.add_child(scene)
	await tree.process_frame
	transport.open()
	client.poll()
	transport.queue(_connected(2))
	transport.queue(_snapshot(2, _two_stone_board(), "active", "black"))
	client.poll()
	if not (_check(_status(scene) == "轮到我", "real client fixture did not reach local turn") \
		and _check(not scene.get_node("ResignButton").disabled, "real client fixture did not enable resign")):
		return _cleanup(scene)

	var sent_before: int = transport.sent.size()
	transport.queue(_move(4, BLACK_ID, "black", 7, 7))
	client.poll()
	transport.queue(_move(5, BLACK_ID, "black", 8, 8))
	client.poll()
	scene._on_cell_pressed(9, 9)
	scene._on_resign_pressed()
	if not (_check(_status(scene) == "正在同步对局…", "revision gap left real controller actionable") \
		and _check((scene.get_node("Board") as Control).mouse_filter == Control.MOUSE_FILTER_IGNORE, "revision gap left board input enabled") \
		and _check(scene.get_node("ResignButton").disabled, "revision gap left resign enabled") \
		and _check(_sent_type_count(transport, "platform.snapshot.requested", sent_before) == 1, "duplicate gaps sent repeated snapshot requests") \
		and _check(_sent_type_count(transport, "gomoku.move.requested", sent_before) == 0, "locked controller sent a move") \
		and _check(_sent_type_count(transport, "gomoku.resign.requested", sent_before) == 0, "locked controller sent resignation")):
		return _cleanup(scene)

	transport.queue(_snapshot(4, _four_stone_board(), "active", "black"))
	client.poll()
	if not (_check(_status(scene) == "轮到我", "fresh recovery snapshot did not unlock real controller") \
		and _check(not scene.get_node("ResignButton").disabled, "fresh recovery snapshot did not unlock resign")):
		return _cleanup(scene)

	transport.queue(_error_bound(4, "stale_revision"))
	client.poll()
	if not _check(_status(scene) == "正在同步对局…", "stale error did not relock real controller"):
		return _cleanup(scene)
	transport.queue(_snapshot(2, _two_stone_board(), "active", "black"))
	client.poll()
	if not (_check(_status(scene) != "轮到我", "older snapshot unlocked real controller") \
		and _check(scene.get_node("ResignButton").disabled, "older snapshot unlocked resignation")):
		return _cleanup(scene)

	scheduler.fire()
	transport.open()
	client.poll()
	transport.queue(_connected(4))
	transport.queue(_snapshot(4, _four_stone_board(), "active", "black"))
	client.poll()
	if not _check(_status(scene) == "轮到我", "reconnect platform.connected unlocked before or failed to unlock after snapshot"):
		return _cleanup(scene)

	transport.fail_send = true
	transport.queue(_move(6, BLACK_ID, "black", 9, 9))
	client.poll()
	var result := _check(_status(scene) == "重连中", "failed snapshot request did not remain locked through reconnect") \
		and _check(scene.get_node("ResignButton").disabled, "failed snapshot request left resign enabled")
	return _cleanup(scene, result)


static func _assert_terminal(local_user_id: String, snapshot: Dictionary, expected_status: String) -> bool:
	var harness: Dictionary = await _scene_harness(local_user_id)
	var scene: Control = harness["scene"]
	var client: FakeMatchClient = harness["client"]
	client.accept_snapshot(snapshot)
	if not _check(scene.has_node("ResultPanel/Content/Result"), "terminal result panel path is missing"):
		return _cleanup(scene)
	var result := _check(_status(scene) == expected_status, "terminal copy changed: %s" % expected_status) \
		and _check((scene.get_node("ResultPanel/Content/Result") as Label).text == expected_status, "result panel copy changed: %s" % expected_status) \
		and _check(scene.get_node("ResultPanel").visible, "terminal result panel stayed hidden") \
		and _check(not scene.get_node("ResignButton").visible, "resign visible after terminal state")
	return _cleanup(scene, result)


static func _gates_resign_and_back() -> bool:
	var harness: Dictionary = await _scene_harness(BLACK_ID)
	var scene: Control = harness["scene"]
	var client: FakeMatchClient = harness["client"]
	var quit_calls: Array[int] = harness["quit_calls"]
	if not _check(scene.has_node("ResignDialog"), "resign confirmation path is missing"):
		return _cleanup(scene)
	var dialog := scene.get_node("ResignDialog") as ConfirmationDialog
	client.accept_snapshot(_snapshot(0))
	if not _check(not scene.get_node("ResignButton").visible, "resign visible before first move"):
		return _cleanup(scene)
	var one_stone := _empty_board()
	one_stone[0] = 1
	client.accept_snapshot(_snapshot(1, one_stone, "active", "white"))
	if not _check(scene.get_node("ResignButton").visible, "resign hidden after first move"):
		return _cleanup(scene)
	scene._on_resign_pressed()
	if not _check(dialog.visible, "resign did not request confirmation") \
		or not _check(client.resign_requests == 0, "resign submitted before confirmation"):
		return _cleanup(scene)
	dialog.get_cancel_button().pressed.emit()
	await (Engine.get_main_loop() as SceneTree).process_frame
	if not _check(not dialog.visible, "cancel action did not close resign confirmation") \
		or not _check(client.resign_requests == 0, "cancel action submitted resignation"):
		return _cleanup(scene)
	scene._on_resign_pressed()
	dialog.get_ok_button().pressed.emit()
	await (Engine.get_main_loop() as SceneTree).process_frame
	dialog.confirmed.emit()
	if not _check(client.resign_requests == 1, "confirmed resign did not submit exactly once") \
		or not _check(not dialog.visible, "confirmed resign left its dialog visible") \
		or not _check(not scene.get_node("ResignButton").visible, "pending resignation left resign enabled"):
		return _cleanup(scene)
	var resigns_before_back := client.resign_requests
	scene._on_back_pressed()
	scene._on_back_pressed()
	var result := _check(client.resign_requests == resigns_before_back, "ordinary back sent resignation") \
		and _check(quit_calls.size() == 1, "ordinary back did not quit exactly once")
	return _cleanup(scene, result)


static func _escape_cancel_closes_dialog_first() -> bool:
	var harness: Dictionary = await _scene_harness(BLACK_ID)
	var scene: Control = harness["scene"]
	var client: FakeMatchClient = harness["client"]
	var quit_calls: Array[int] = harness["quit_calls"]
	if not _check(scene.has_node("ResignDialog"), "keyboard Escape confirmation path is missing"):
		return _cleanup(scene)
	var one_stone := _empty_board()
	one_stone[0] = 1
	client.accept_snapshot(_snapshot(1, one_stone, "active", "white"))
	scene._on_resign_pressed()
	var dialog := scene.get_node("ResignDialog") as ConfirmationDialog
	if not _check(dialog.visible, "resign confirmation did not open before keyboard Escape"):
		return _cleanup(scene)
	scene._unhandled_key_input(_action("ui_cancel"))
	if not _check(not dialog.visible, "first keyboard Escape did not close the visible confirmation") \
		or not _check(quit_calls.is_empty(), "first keyboard Escape returned while confirmation was visible") \
		or not _check(client.resign_requests == 0, "keyboard Escape submitted resignation"):
		return _cleanup(scene)
	scene._unhandled_key_input(_action("ui_cancel"))
	var result := _check(quit_calls.size() == 1, "second keyboard Escape did not return exactly once") \
		and _check(client.resign_requests == 0, "ordinary keyboard return submitted resignation")
	return _cleanup(scene, result)


static func _android_go_back_closes_dialog_first() -> bool:
	var harness: Dictionary = await _scene_harness(BLACK_ID)
	var scene: Control = harness["scene"]
	var client: FakeMatchClient = harness["client"]
	var quit_calls: Array[int] = harness["quit_calls"]
	if not _check(scene.has_node("ResignDialog"), "Android go-back confirmation path is missing"):
		return _cleanup(scene)
	if not _check(not (Engine.get_main_loop() as SceneTree).quit_on_go_back,
		"Android go-back is not user-managed"):
		return _cleanup(scene)
	var one_stone := _empty_board()
	one_stone[0] = 1
	client.accept_snapshot(_snapshot(1, one_stone, "active", "white"))
	scene._on_resign_pressed()
	var dialog := scene.get_node("ResignDialog") as ConfirmationDialog
	if not _check(dialog.visible, "resign confirmation did not open before Android go-back"):
		return _cleanup(scene)
	scene.notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	if not _check(not dialog.visible, "first Android go-back did not close the visible confirmation") \
		or not _check(quit_calls.is_empty(), "first Android go-back returned while confirmation was visible") \
		or not _check(client.resign_requests == 0, "Android go-back submitted resignation"):
		return _cleanup(scene)
	scene.notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	var result := _check(quit_calls.size() == 1, "second Android go-back did not return exactly once") \
		and _check(client.resign_requests == 0, "ordinary Android go-back return submitted resignation")
	return _cleanup(scene, result)


static func _terminal_return_is_non_destructive() -> bool:
	var harness: Dictionary = await _scene_harness(BLACK_ID)
	var scene: Control = harness["scene"]
	var client: FakeMatchClient = harness["client"]
	var quit_calls: Array[int] = harness["quit_calls"]
	if not _check(scene.has_node("ResultPanel/Content/ReturnButton"), "terminal return path is missing"):
		return _cleanup(scene)
	client.accept_snapshot(_snapshot(9, _five_board(), "finished", "white", "five", BLACK_ID))
	(scene.get_node("ResultPanel/Content/ReturnButton") as Button).pressed.emit()
	var result := _check(quit_calls.size() == 1, "result return did not return exactly once") \
		and _check(client.resign_requests == 0, "result return submitted resignation")
	return _cleanup(scene, result)


static func _wires_move_once() -> bool:
	var harness: Dictionary = await _scene_harness(BLACK_ID)
	var scene: Control = harness["scene"]
	var client: FakeMatchClient = harness["client"]
	client.accept_snapshot(_snapshot(0))
	scene._on_cell_pressed(7, 7)
	scene._on_cell_pressed(8, 8)
	var board = scene.get_node("Board")
	if not (_check(client.move_requests == [Vector2i(7, 7)], "pending move allowed duplicate request") \
		and _check(board.stone_at(7, 7) == 0, "local request mutated authoritative board") \
		and _check(board.pending_cell == Vector2i(7, 7), "pending marker not refreshed")):
		return _cleanup(scene)
	client.accept_event(_move(1, BLACK_ID, "black", 7, 7))
	var result := _check(board.stone_at(7, 7) == 1, "accepted event did not place authoritative stone") \
		and _check(board.pending_cell == Vector2i(-1, -1), "accepted event did not clear pending marker") \
		and _check(board.last_move_cell == Vector2i(7, 7), "accepted event did not mark last move")
	return _cleanup(scene, result)


static func _keeps_portrait_touch_layout() -> bool:
	var harness: Dictionary = await _scene_harness(BLACK_ID)
	var scene: Control = harness["scene"]
	var board: Control = scene.get_node("Board")
	var back: Button = scene.get_node("BackButton")
	var resign: Button = scene.get_node("ResignButton")
	var loading: Control = scene.get_node("LoadingOverlay")
	var back_center := back.position + back.size * 0.5
	var result := _check(board.position.is_equal_approx(Vector2(60.0, 360.0)), "fixed board origin changed: %s" % board.position) \
		and _check(board.size.is_equal_approx(Vector2(960.0, 960.0)), "fixed board stopped being square: %s" % board.size) \
		and _check(back.custom_minimum_size.x >= 96.0 and back.custom_minimum_size.y >= 96.0, "back target too small") \
		and _check(resign.custom_minimum_size.x >= 96.0 and resign.custom_minimum_size.y >= 96.0, "resign target too small") \
		and _check(back.position.x >= 48.0 and back.position.y >= 48.0, "back button left portrait safe margin") \
		and _check(resign.position.x >= 48.0 and scene.size.x - resign.position.x - resign.size.x >= 48.0, "resign button left portrait safe margin") \
		and _check(not loading.get_rect().has_point(back_center), "initial loading overlay blocked the visible Back control")
	return _cleanup(scene, result)


static func _waits_for_drawn_frame_marker() -> bool:
	var first := await _scene_with_frame_gate()
	var scene: Control = first["scene"]
	var gate: FakeFrameGate = first["gate"]
	if not (_check(not scene.ready_marker_emitted, "ready marker emitted from _ready or the same frame") \
		and _check(gate.pending_count() == 1, "ready marker did not schedule one frame callback")):
		return _cleanup(scene)
	gate.fire()
	gate.fire()
	if not (_check(scene.ready_marker_emitted, "drawn frame did not emit ready marker") \
		and _check(scene.ready_marker_text == "GAMEBOX_GODOT_READY game=gomoku match=%s" % MATCH_ID, "ready marker format changed") \
		and _check(not scene.ready_marker_text.contains("opaque-test-ticket"), "ready marker exposed launch ticket") \
		and _check(gate.fired_callbacks == 1, "ready marker callback fired more than once")):
		return _cleanup(scene)
	_cleanup(scene, true)

	var cancelled := await _scene_with_frame_gate()
	var cancelled_scene: Control = cancelled["scene"]
	var cancelled_gate: FakeFrameGate = cancelled["gate"]
	cancelled_scene._exit_tree()
	cancelled_gate.fire()
	var result := _check(not cancelled_scene.ready_marker_emitted, "disposed scene emitted a late ready marker") \
		and _check(cancelled_gate.cancel_calls == 1, "disposed scene did not cancel frame callback")
	return _cleanup(cancelled_scene, result)


static func _scene_with_frame_gate() -> Dictionary:
	var tree := Engine.get_main_loop() as SceneTree
	var fake := FakeMatchClient.new()
	fake.local_user_id = BLACK_ID
	var gate := FakeFrameGate.new()
	var scene := GomokuScene.instantiate()
	scene.configure_launch(_launch_config())
	scene.set_match_client_factory(func() -> Variant: return fake)
	scene.set_frame_ready_gate(gate)
	scene.set_quit_callback(func() -> void: pass)
	tree.root.add_child(scene)
	await tree.process_frame
	return {"scene": scene, "client": fake, "gate": gate}


static func _disposes_once() -> bool:
	var harness: Dictionary = await _scene_harness(BLACK_ID)
	var scene: Control = harness["scene"]
	var client: FakeMatchClient = harness["client"]
	scene._exit_tree()
	client.begin_snapshot_sync()
	scene._exit_tree()
	var result := _check(client.dispose_calls == 1, "client disposed more than once") \
		and _check(client.snapshot_sync_started.get_connections().is_empty(), "disposed controller retained snapshot sync signal")
	return _cleanup(scene, result)


static func _scene_harness(local_user_id: String) -> Dictionary:
	var tree := Engine.get_main_loop() as SceneTree
	var fake := FakeMatchClient.new()
	fake.local_user_id = local_user_id
	var scene := GomokuScene.instantiate()
	scene.configure_launch(_launch_config())
	scene.set_match_client_factory(func() -> Variant: return fake)
	var quit_calls: Array[int] = []
	scene.set_quit_callback(func() -> void: quit_calls.append(1))
	tree.root.add_child(scene)
	await tree.process_frame
	return {"scene": scene, "client": fake, "quit_calls": quit_calls}


static func _cleanup(scene: Control, result: bool = false) -> bool:
	if is_instance_valid(scene):
		scene.free()
	return result


static func _status(scene: Control) -> String:
	return (scene.get_node("StatusLabel") as Label).text


static func _has_lightweight_nodes(scene: Control) -> bool:
	return scene.has_node("ConnectionLabel/Content/Message") \
		and scene.has_node("ErrorLabel/Content/Message") \
		and scene.has_node("ResignDialog") \
		and scene.has_node("LoadingOverlay/Content/Message") \
		and scene.has_node("ResultPanel/Content/Result")


static func _connection_visible(scene: Control) -> bool:
	return scene.get_node("ConnectionLabel").visible


static func _connection_message(scene: Control) -> String:
	return (scene.get_node("ConnectionLabel/Content/Message") as Label).text


static func _loading_visible(scene: Control) -> bool:
	return scene.get_node("LoadingOverlay").visible


static func _error(scene: Control) -> String:
	return (scene.get_node("ErrorLabel/Content/Message") as Label).text


static func _error_visible(scene: Control) -> bool:
	return scene.get_node("ErrorLabel").visible


static func _action(action_name: String) -> InputEventAction:
	var event := InputEventAction.new()
	event.action = action_name
	event.pressed = true
	return event


static func _launch_config() -> Dictionary:
	return {"game_id": "gomoku", "match_id": MATCH_ID, "launch_ticket": "opaque-test-ticket", "ws_url": "ws://127.0.0.1:8080/v1/ws"}


static func _snapshot(
	revision: int,
	board: Array = [],
	status: String = "active",
	next_color: String = "black",
	result: Variant = null,
	winner: Variant = null
) -> Dictionary:
	return {
		"protocolVersion": 1, "gameId": "gomoku", "matchId": MATCH_ID,
		"revision": revision, "type": "platform.snapshot",
		"payload": {
			"status": status, "board": _empty_board() if board.is_empty() else board.duplicate(), "boardSize": 15,
			"blackUserId": BLACK_ID, "whiteUserId": WHITE_ID, "nextColor": next_color,
			"winnerUserId": winner, "result": result,
		},
	}


static func _move(revision: int, user_id: String, color: String, x: int, y: int) -> Dictionary:
	return {
		"protocolVersion": 1, "gameId": "gomoku", "matchId": MATCH_ID,
		"revision": revision, "type": "gomoku.move.accepted", "actionId": ACTION_ID,
		"payload": {"userId": user_id, "color": color, "x": x, "y": y},
	}


static func _empty_board() -> Array:
	var board: Array = []
	board.resize(225)
	board.fill(0)
	return board


static func _five_board() -> Array:
	var board := _empty_board()
	for x in 5:
		board[x] = 1
	for x in 4:
		board[15 + x] = 2
	return board


static func _two_stone_board() -> Array:
	var board := _empty_board()
	board[0] = 1
	board[1] = 2
	return board


static func _four_stone_board() -> Array:
	var board := _two_stone_board()
	board[2] = 1
	board[3] = 2
	return board


static func _draw_board() -> Array:
	var board := _empty_board()
	for y in 15:
		for x in 15:
			board[y * 15 + x] = 1 if ((x + 2 * y) % 4) < 2 else 2
	return board


static func _check(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition


class FakeMatchClient:
	extends RefCounted

	signal connection_state_changed(next_state: String)
	signal snapshot_sync_started
	signal snapshot_received(envelope: Dictionary)
	signal event_received(envelope: Dictionary)
	signal match_error(code: String)
	signal return_to_lobby_requested(code: String)

	var connection_state := "closed"
	var local_user_id := ""
	var state: Variant
	var move_requests: Array[Vector2i] = []
	var resign_requests := 0
	var dispose_calls := 0

	func start(_ws_url: String, _match_id: String, _ticket: String, game_state: Variant) -> bool:
		state = game_state
		connection_state = "connecting"
		return true

	func poll() -> void:
		pass

	func request_move(x: int, y: int) -> String:
		if not state.can_request_move(x, y, local_user_id):
			return ""
		if not state.mark_pending(ACTION_ID, x, y):
			return ""
		move_requests.append(Vector2i(x, y))
		return ACTION_ID

	func request_resign() -> String:
		resign_requests += 1
		return ACTION_ID if state.mark_pending_resign(ACTION_ID, local_user_id) else ""

	func dispose() -> void:
		dispose_calls += 1

	func set_connection(next_state: String) -> void:
		connection_state = next_state
		connection_state_changed.emit(next_state)

	func accept_snapshot(envelope: Dictionary) -> void:
		var applied: Dictionary = state.apply_snapshot(envelope)
		if not applied.get("ok", false):
			push_error("fake snapshot invalid")
			return
		connection_state = "connected"
		connection_state_changed.emit(connection_state)
		snapshot_received.emit(envelope)

	func emit_error(code: String) -> void:
		match_error.emit(code)

	func require_return(code: String) -> void:
		return_to_lobby_requested.emit(code)

	func begin_snapshot_sync() -> void:
		snapshot_sync_started.emit()

	func emit_snapshot_raw(envelope: Dictionary) -> void:
		snapshot_received.emit(envelope)

	func accept_event(envelope: Dictionary) -> void:
		var applied: Dictionary = state.apply_event(envelope)
		if not applied.get("ok", false):
			push_error("fake event invalid")
			return
		event_received.emit(envelope)


class FakeFrameGate:
	extends RefCounted

	var callbacks: Array[Callable] = []
	var cancel_calls := 0
	var fired_callbacks := 0

	func schedule(callback: Callable) -> bool:
		callbacks.append(callback)
		return true

	func cancel(callback: Callable) -> void:
		cancel_calls += 1
		callbacks.erase(callback)

	func pending_count() -> int:
		return callbacks.size()

	func fire() -> void:
		var pending := callbacks.duplicate()
		callbacks.clear()
		for callback in pending:
			fired_callbacks += 1
			callback.call()


class ControllerTransport:
	extends RefCounted

	var ready_state := "closed"
	var sent: Array[String] = []
	var incoming: Array[String] = []
	var fail_send := false

	func connect_to_url(_url: String) -> bool:
		ready_state = "connecting"
		return true

	func poll() -> void:
		pass

	func get_ready_state() -> String:
		return ready_state

	func receive_text() -> Dictionary:
		if incoming.is_empty():
			return {"ok": false}
		return {"ok": true, "text": incoming.pop_front()}

	func send_text(value: String) -> bool:
		if fail_send:
			return false
		sent.append(value)
		return true

	func close() -> void:
		ready_state = "closed"

	func get_close_info() -> Dictionary:
		return {"code": -1, "reason": ""}

	func open() -> void:
		ready_state = "open"

	func queue(message: Dictionary) -> void:
		incoming.append(JSON.stringify(message))


class ControllerScheduler:
	extends RefCounted

	var next_handle := 0
	var callback := Callable()

	func schedule(_delay_seconds: float, scheduled: Callable) -> int:
		next_handle += 1
		callback = scheduled
		return next_handle

	func cancel(_handle: int = -1) -> void:
		callback = Callable()

	func fire() -> void:
		var scheduled := callback
		callback = Callable()
		if scheduled.is_valid():
			scheduled.call()


class ControllerRandom:
	extends RefCounted

	func generate_bytes(_count: int) -> PackedByteArray:
		return PackedByteArray(range(16))


static func _connected(revision: int) -> Dictionary:
	return {
		"protocolVersion": 1, "gameId": "gomoku", "matchId": MATCH_ID,
		"revision": revision, "type": "platform.connected",
		"payload": {
			"userId": BLACK_ID, "connectionId": "55555555-5555-4555-8555-555555555555",
			"resumeToken": "resume-secret", "resumeExpiresAt": 4102444800000,
		},
	}


static func _error_bound(revision: int, code: String) -> Dictionary:
	return {
		"protocolVersion": 1, "gameId": "gomoku", "matchId": MATCH_ID,
		"revision": revision, "type": "platform.error",
		"payload": {"code": code, "message": "fixed", "details": {}},
	}


static func _sent_type_count(transport: ControllerTransport, message_type: String, start_index: int = 0) -> int:
	var count := 0
	for index in range(start_index, transport.sent.size()):
		var decoded: Dictionary = Protocol.decode(transport.sent[index])
		if decoded.get("ok", false) and decoded["envelope"].get("type") == message_type:
			count += 1
	return count
