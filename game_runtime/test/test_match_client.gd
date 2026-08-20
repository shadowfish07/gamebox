extends RefCounted

const MatchClient = preload("res://core/match_client.gd")
const GomokuState = preload("res://games/gomoku/gomoku_state.gd")
const Protocol = preload("res://core/protocol.gd")

const MATCH_ID := "11111111-1111-4111-8111-111111111111"
const BLACK_ID := "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
const WHITE_ID := "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
const CONNECTION_ID := "cccccccc-cccc-4ccc-8ccc-cccccccccccc"


class FakeTransport:
	extends RefCounted
	var ready_state := "closed"
	var sent: Array[String] = []
	var incoming: Array = []
	var urls: Array[String] = []
	var fail_connect := false
	var fail_send := false
	var closed_count := 0
	var close_code := -1
	var close_reason := ""

	func connect_to_url(url: String) -> bool:
		urls.append(url)
		ready_state = "closed" if fail_connect else "connecting"
		return not fail_connect

	func poll() -> void:
		pass

	func get_ready_state() -> String:
		return ready_state

	func receive_text() -> Dictionary:
		if incoming.is_empty():
			return {"ok": false}
		return {"ok": true, "text": incoming.pop_front()}

	func send_text(text: String) -> bool:
		if fail_send:
			return false
		sent.append(text)
		return true

	func close() -> void:
		closed_count += 1
		ready_state = "closed"

	func get_close_info() -> Dictionary:
		return {"code": close_code, "reason": close_reason}

	func open() -> void:
		ready_state = "open"

	func disconnect_now() -> void:
		ready_state = "closed"

	func remote_close(code: int, reason: String) -> void:
		close_code = code
		close_reason = reason
		ready_state = "closed"

	func queue(message: Dictionary) -> void:
		incoming.append(JSON.stringify(message))


class FakeScheduler:
	extends RefCounted
	var delays: Array[float] = []
	var callback: Callable
	var active := false

	func schedule(delay_seconds: float, scheduled: Callable) -> int:
		delays.append(delay_seconds)
		callback = scheduled
		active = true
		return delays.size()

	func cancel(_handle: int = -1) -> void:
		active = false
		callback = Callable()

	func fire() -> void:
		var scheduled := callback
		active = false
		callback = Callable()
		if scheduled.is_valid():
			scheduled.call()


class FakeRandom:
	extends RefCounted
	var next_bytes := PackedByteArray()
	var calls := 0

	func _init(bytes: PackedByteArray = PackedByteArray(range(16))) -> void:
		next_bytes = bytes

	func generate_bytes(_count: int) -> PackedByteArray:
		var generated := next_bytes.duplicate()
		if generated.size() == 16:
			generated[0] = (generated[0] + calls) & 0xff
		calls += 1
		return generated


class ReplayableScheduler:
	extends RefCounted
	var callbacks := {}
	var active := {}
	var latest_handle := -1
	var next_handle := 0

	func schedule(_delay_seconds: float, scheduled: Callable) -> int:
		next_handle += 1
		latest_handle = next_handle
		callbacks[latest_handle] = scheduled
		active[latest_handle] = true
		return latest_handle

	func cancel(handle: int = -1) -> void:
		if handle >= 0:
			active.erase(handle)

	func replay(handle: int) -> void:
		var scheduled: Callable = callbacks.get(handle, Callable())
		if scheduled.is_valid():
			scheduled.call()

	func active_count() -> int:
		return active.size()


class FakeClock:
	extends RefCounted
	var current_msec := 0

	func now_msec() -> int:
		return current_msec

	func advance(delta_msec: int) -> void:
		current_msec += delta_msec


class LocalPolicyWebSocketServer:
	extends RefCounted
	const WEBSOCKET_GUID := "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
	var _server := TCPServer.new()
	var _peer: StreamPeerTCP
	var _request_bytes := PackedByteArray()
	var _reason := ""
	var _send_error := false
	var _upgraded := false
	var _sent_terminal := false
	var _polls_after_terminal := 0

	func start(reason: String, send_error: bool) -> bool:
		_reason = reason
		_send_error = send_error
		return _server.listen(0, "127.0.0.1") == OK

	func url() -> String:
		return "ws://127.0.0.1:%d/v1/ws" % _server.get_local_port()

	func sent_terminal() -> bool:
		return _sent_terminal

	func poll() -> void:
		if _peer == null and _server.is_connection_available():
			_peer = _server.take_connection()
		if _peer == null or _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			return
		if _sent_terminal:
			_polls_after_terminal += 1
			if _polls_after_terminal >= 4:
				_peer.disconnect_from_host()
			return
		var available := _peer.get_available_bytes()
		if available <= 0:
			return
		var received: Array = _peer.get_data(available)
		if received[0] != OK:
			return
		if not _upgraded:
			_request_bytes.append_array(received[1])
			var request := _request_bytes.get_string_from_ascii()
			if not request.contains("\r\n\r\n"):
				return
			var websocket_key := ""
			for line in request.split("\r\n"):
				if line.to_lower().begins_with("sec-websocket-key:"):
					websocket_key = line.substr(line.find(":") + 1).strip_edges()
			if websocket_key.is_empty():
				return
			var hash := HashingContext.new()
			hash.start(HashingContext.HASH_SHA1)
			hash.update((websocket_key + WEBSOCKET_GUID).to_utf8_buffer())
			var accept := Marshalls.raw_to_base64(hash.finish())
			var response := "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n" % accept
			_peer.put_data(response.to_utf8_buffer())
			_upgraded = true
			return
		_send_terminal_frames()

	func stop() -> void:
		if _peer != null:
			_peer.disconnect_from_host()
		_server.stop()

	func _send_terminal_frames() -> void:
		var frames := PackedByteArray()
		if _send_error:
			var error_text := '{"protocolVersion":1,"type":"platform.error","payload":{"code":"%s","message":"fixed","details":{}}}' % _reason
			frames.append_array(_server_frame(0x1, error_text.to_utf8_buffer()))
		var close_payload := PackedByteArray([0x03, 0xf0])
		close_payload.append_array(_reason.to_utf8_buffer())
		frames.append_array(_server_frame(0x8, close_payload))
		_peer.put_data(frames)
		_sent_terminal = true

	static func _server_frame(opcode: int, payload: PackedByteArray) -> PackedByteArray:
		var frame := PackedByteArray([0x80 | opcode])
		if payload.size() < 126:
			frame.append(payload.size())
		else:
			frame.append(126)
			frame.append((payload.size() >> 8) & 0xff)
			frame.append(payload.size() & 0xff)
		frame.append_array(payload)
		return frame


static func cases() -> Array:
	return [
		{"name": "match client connects with launch then resumes in memory", "run": _connects_and_resumes},
		{"name": "match client retries with bounded deterministic backoff", "run": _bounds_retries},
		{"name": "match client watchdog bounds every incomplete handshake phase", "run": _bounds_incomplete_handshakes},
		{"name": "match client inbound watchdog resets only on valid messages", "run": _bounds_half_open_connections},
		{"name": "match client watchdog callbacks are generation safe", "run": _ignores_stale_watchdogs},
		{"name": "match client watchdog callbacks do not retain disposed clients", "run": _does_not_leak_disposed_clients},
		{"name": "match client real WebSocketPeer bounds a hanging TCP handshake", "run": _bounds_real_hanging_tcp},
		{"name": "match client production scheduler uses injected monotonic time", "run": _uses_injected_clock},
		{"name": "match client resets retry budget only after a snapshot", "run": _resets_retry_budget_after_snapshot},
		{"name": "match client fails immediately when resume expires", "run": _fails_expired_resume},
		{"name": "match client drains policy errors before handling close", "run": _drains_policy_error_before_close},
		{"name": "match client maps close reasons through a fixed allowlist", "run": _maps_policy_close_reasons},
		{"name": "match client production transport handles real policy closes", "run": _handles_real_policy_closes},
		{"name": "match client answers ping and requests snapshots on gaps", "run": _handles_ping_and_gap},
		{"name": "match client signals every transition into snapshot recovery once", "run": _signals_snapshot_recovery_once},
		{"name": "match client sends UUIDv4 actions without optimistic stones", "run": _sends_actions_authoritatively},
		{"name": "match client sends a fresh resignation action after the first move", "run": _sends_resignation},
		{"name": "match client rolls back pending when send fails", "run": _rolls_back_failed_send},
		{"name": "match client never replays ambiguous pending actions", "run": _never_replays_pending},
		{"name": "match client rejects malformed and oversized server messages", "run": _rejects_bad_server_messages},
		{"name": "match client object and errors never stringify credentials", "run": _does_not_stringify_credentials},
		{"name": "match client close cancels all future retries", "run": _closes_permanently},
		{"name": "match client UUID formatter sets RFC4122 version and variant", "run": _formats_uuid_v4},
	]


static func _connects_and_resumes() -> bool:
	var fixture := _fixture()
	var client = fixture.client
	var transport = fixture.transport
	if not _check(client.start("ws://10.0.2.2:8080/v1/ws", MATCH_ID, "launch-secret", fixture.state), "client did not start") \
		or not _check(client.connection_state == "connecting", "initial state must be connecting"):
		return false
	transport.open()
	client.poll()
	var connect := _last_sent(transport)
	if not _check(connect.get("type") == "platform.connect", "missing platform.connect") \
		or not _check(connect.get("payload") == {"launchTicket": "launch-secret"}, "initial connect did not use launch ticket only"):
		return false
	transport.queue(_connected(0, "resume-secret"))
	transport.queue(_snapshot(0))
	client.poll()
	if not _check(client.connection_state == "connected", "valid handshake did not connect") \
		or not _check(client.local_user_id == BLACK_ID, "connected user not retained"):
		return false
	transport.disconnect_now()
	client.poll()
	fixture.scheduler.fire()
	transport.open()
	client.poll()
	var resumed := _last_sent(transport)
	return _check(resumed.get("payload") == {"resumeToken": "resume-secret"}, "reconnect did not use resume token only") \
		and _check(not JSON.stringify(resumed).contains("launch-secret"), "launch ticket leaked into resume handshake")


static func _bounds_retries() -> bool:
	var fixture := _fixture()
	fixture.transport.fail_connect = true
	fixture.client.start("ws://127.0.0.1:8080/v1/ws", MATCH_ID, "ticket", fixture.state)
	for expected_delay in [1.0, 2.0, 4.0, 8.0, 15.0]:
		if not _check(fixture.client.connection_state == "reconnecting", "failed attempt did not enter reconnecting") \
			or not _check(fixture.scheduler.delays.back() == expected_delay, "unexpected retry delay"):
			return false
		fixture.scheduler.fire()
	return _check(fixture.client.connection_state == "failed", "sixth failure must stop") \
		and _check(not fixture.scheduler.active, "failed client left a retry scheduled") \
		and _check(fixture.transport.urls.size() == 6, "expected exactly six connection attempts")


static func _fails_expired_resume() -> bool:
	var fixture := _connected_fixture()
	fixture.transport.disconnect_now()
	fixture.client.poll()
	fixture.scheduler.fire()
	fixture.transport.open()
	fixture.client.poll()
	fixture.transport.queue(_error_unbound("resume_expired"))
	fixture.client.poll()
	return _check(fixture.client.connection_state == "failed", "resume_expired must fail immediately") \
		and _check(not fixture.scheduler.active, "resume_expired scheduled a retry")


static func _bounds_incomplete_handshakes() -> bool:
	var tcp = _fixture()
	tcp.client.start("ws://127.0.0.1:8080/v1/ws", MATCH_ID, "ticket", tcp.state)
	for expected_delay in [1.0, 2.0, 4.0, 8.0, 15.0]:
		tcp.scheduler.fire()
		if not _check(tcp.client.connection_state == "reconnecting" and tcp.scheduler.delays.back() == expected_delay, "TCP watchdog retry delay was not exact"):
			return false
		tcp.scheduler.fire()
	tcp.scheduler.fire()
	if not _check(tcp.client.connection_state == "failed" and not tcp.scheduler.active, "sixth TCP watchdog failure did not stop") \
		or not _check(tcp.transport.urls.size() == 6, "watchdog retry sequence did not make exactly six attempts"):
		return false

	var opened = _fixture()
	opened.client.start("ws://127.0.0.1:8080/v1/ws", MATCH_ID, "ticket", opened.state)
	opened.transport.open()
	opened.client.poll()
	opened.scheduler.fire()
	if not _check(opened.client.connection_state == "reconnecting" and opened.scheduler.delays.back() == 1.0, "open-without-connected watchdog failed"):
		return false

	var no_snapshot = _fixture()
	no_snapshot.client.start("ws://127.0.0.1:8080/v1/ws", MATCH_ID, "ticket", no_snapshot.state)
	no_snapshot.transport.open()
	no_snapshot.client.poll()
	no_snapshot.transport.queue(_connected(0, "resume"))
	no_snapshot.client.poll()
	no_snapshot.scheduler.fire()
	return _check(no_snapshot.client.connection_state == "reconnecting" and no_snapshot.scheduler.delays.back() == 1.0, "connected-without-snapshot watchdog failed")


static func _bounds_half_open_connections() -> bool:
	var fixture := _connected_fixture()
	if not _check(fixture.scheduler.active and fixture.scheduler.delays.back() == 45.0, "connected inbound watchdog missing"):
		return false
	var schedules_before: int = fixture.scheduler.delays.size()
	fixture.transport.queue(_ping(0, "dddddddd-dddd-4ddd-8ddd-dddddddddddd"))
	fixture.client.poll()
	if not _check(fixture.scheduler.active and fixture.scheduler.delays.size() == schedules_before + 1, "valid inbound did not reset watchdog"):
		return false
	fixture.scheduler.fire()
	return _check(fixture.client.connection_state == "reconnecting" and fixture.scheduler.delays.back() == 1.0, "half-open inbound timeout did not retry")


static func _ignores_stale_watchdogs() -> bool:
	var scheduler := ReplayableScheduler.new()
	var transport := FakeTransport.new()
	var state = GomokuState.new(MATCH_ID)
	var client = MatchClient.new(transport, scheduler, FakeRandom.new())
	client.start("ws://127.0.0.1:8080/v1/ws", MATCH_ID, "ticket", state)
	var attempt_watchdog: int = scheduler.latest_handle
	transport.open()
	client.poll()
	transport.queue(_connected(0, "resume"))
	transport.queue(_snapshot(0))
	client.poll()
	var first_inbound_watchdog: int = scheduler.latest_handle
	scheduler.replay(attempt_watchdog)
	if not _check(client.connection_state == "connected", "cancelled attempt watchdog changed connected state"):
		return false
	transport.queue(_ping(0, "dddddddd-dddd-4ddd-8ddd-dddddddddddd"))
	client.poll()
	var current_inbound_watchdog: int = scheduler.latest_handle
	scheduler.replay(first_inbound_watchdog)
	if not _check(client.connection_state == "connected", "replaced inbound watchdog changed connected state"):
		return false
	client.dispose()
	scheduler.replay(current_inbound_watchdog)
	return _check(client.connection_state == "closed" and scheduler.active_count() == 0, "disposed client accepted a stale watchdog callback")


static func _does_not_leak_disposed_clients() -> bool:
	for _iteration in 250:
		var scheduler := ReplayableScheduler.new()
		var client = MatchClient.new(FakeTransport.new(), scheduler, FakeRandom.new())
		var state = GomokuState.new(MATCH_ID)
		client.start("ws://127.0.0.1:8080/v1/ws", MATCH_ID, "ticket", state)
		var watchdog_handle: int = scheduler.latest_handle
		var reference: WeakRef = weakref(client)
		client.dispose()
		client = null
		scheduler.replay(watchdog_handle)
		if not _check(reference.get_ref() == null and scheduler.active_count() == 0, "disposed client was retained by a watchdog callback"):
			return false
	return true


static func _bounds_real_hanging_tcp() -> bool:
	var server := TCPServer.new()
	if server.listen(0, "127.0.0.1") != OK:
		return _check(false, "unable to start local hanging TCP fixture")
	var scheduler := FakeScheduler.new()
	var state = GomokuState.new(MATCH_ID)
	var client = MatchClient.new(null, scheduler, FakeRandom.new())
	client.start("ws://127.0.0.1:%d/v1/ws" % server.get_local_port(), MATCH_ID, "ticket", state)
	var peer: StreamPeerTCP = null
	var tree := Engine.get_main_loop() as SceneTree
	for _iteration in 120:
		client.poll()
		if server.is_connection_available():
			peer = server.take_connection()
			break
		await tree.process_frame
	if peer == null:
		server.stop()
		client.close()
		return _check(false, "real WebSocketPeer never reached local hanging TCP server")
	scheduler.fire()
	var bounded: bool = client.connection_state == "reconnecting" and scheduler.delays.back() == 1.0
	peer.disconnect_from_host()
	server.stop()
	client.close()
	return _check(bounded, "real hanging WebSocket handshake was not bounded")


static func _drains_policy_error_before_close() -> bool:
	var fixture := _fixture()
	fixture.client.start("ws://127.0.0.1:8080/v1/ws", MATCH_ID, "ticket", fixture.state)
	fixture.transport.open()
	fixture.client.poll()
	fixture.transport.queue(_error_unbound("resume_expired"))
	fixture.transport.remote_close(1008, "resume_expired")
	fixture.client.poll()
	return _check(fixture.client.connection_state == "failed" and fixture.client.last_error_code == "resume_expired", "queued policy error was not drained before close") \
		and _check(not fixture.scheduler.active, "terminal policy error scheduled retry")


static func _maps_policy_close_reasons() -> bool:
	for reason in ["resume_expired", "ticket_invalid", "invalid_request"]:
		var terminal := _fixture()
		terminal.client.start("ws://127.0.0.1:8080/v1/ws", MATCH_ID, "ticket", terminal.state)
		terminal.transport.open()
		terminal.client.poll()
		terminal.transport.remote_close(1008, reason)
		terminal.client.poll()
		if not _check(terminal.client.connection_state == "failed" and terminal.client.last_error_code == reason, "allowlisted policy reason was not terminal") \
			or not _check(not terminal.scheduler.active, "allowlisted policy reason retried"):
			return false
	var unknown := _fixture()
	unknown.client.start("ws://127.0.0.1:8080/v1/ws", MATCH_ID, "ticket", unknown.state)
	unknown.transport.open()
	unknown.client.poll()
	unknown.transport.remote_close(1008, "untrusted-secret-close-reason")
	unknown.client.poll()
	return _check(unknown.client.connection_state == "reconnecting" and unknown.client.last_error_code == "connection_lost", "unknown close reason was not mapped to fixed failure") \
		and _check(not unknown.client.last_error_code.contains("secret"), "unknown close reason leaked")


static func _handles_real_policy_closes() -> bool:
	for send_error in [true, false]:
		var server := LocalPolicyWebSocketServer.new()
		var reason := "resume_expired" if send_error else "ticket_invalid"
		if not server.start(reason, send_error):
			return _check(false, "unable to start local policy-close fixture")
		var scheduler := FakeScheduler.new()
		var state = GomokuState.new(MATCH_ID)
		var client = MatchClient.new(null, scheduler, FakeRandom.new())
		client.start(server.url(), MATCH_ID, "ticket", state)
		var tree := Engine.get_main_loop() as SceneTree
		for _iteration in 240:
			server.poll()
			client.poll()
			if client.connection_state == "failed":
				break
			await tree.process_frame
		var terminal_seen: bool = server.sent_terminal()
		var terminal_result: bool = client.connection_state == "failed" \
			and client.last_error_code == reason and not scheduler.active
		client.dispose()
		server.stop()
		if not _check(terminal_seen, "real WebSocket fixture never sent terminal frames") \
			or not _check(terminal_result, "production transport did not preserve real policy-close semantics"):
			return false
	return true


static func _uses_injected_clock() -> bool:
	var transport := FakeTransport.new()
	transport.fail_connect = true
	var clock := FakeClock.new()
	var client = MatchClient.new(transport, null, FakeRandom.new(), clock)
	var state = GomokuState.new(MATCH_ID)
	client.start("ws://127.0.0.1:8080/v1/ws", MATCH_ID, "ticket", state)
	client.poll()
	if not _check(transport.urls.size() == 1, "polling scheduler retried before deadline"):
		return false
	clock.advance(999)
	client.poll()
	if not _check(transport.urls.size() == 1, "polling scheduler fired one millisecond early"):
		return false
	clock.advance(1)
	client.poll()
	client.close()
	return _check(transport.urls.size() == 2, "polling scheduler did not fire at deadline")


static func _resets_retry_budget_after_snapshot() -> bool:
	var fixture := _fixture()
	fixture.transport.fail_connect = true
	fixture.client.start("ws://127.0.0.1:8080/v1/ws", MATCH_ID, "ticket", fixture.state)
	fixture.transport.fail_connect = false
	fixture.scheduler.fire()
	fixture.transport.open()
	fixture.client.poll()
	fixture.transport.queue(_connected(0, "resume-one"))
	fixture.client.poll()
	fixture.transport.disconnect_now()
	fixture.client.poll()
	if not _check(fixture.scheduler.delays.back() == 2.0, "connected without snapshot incorrectly reset retry budget"):
		return false
	fixture.scheduler.fire()
	fixture.transport.open()
	fixture.client.poll()
	fixture.transport.queue(_connected(0, "resume-two"))
	fixture.transport.queue(_snapshot(0))
	fixture.client.poll()
	fixture.transport.disconnect_now()
	fixture.client.poll()
	return _check(fixture.scheduler.delays.back() == 1.0, "authoritative snapshot did not reset retry budget")


static func _handles_ping_and_gap() -> bool:
	var fixture := _connected_fixture()
	var nonce := "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
	fixture.transport.queue(_ping(0, nonce))
	fixture.client.poll()
	var pong := _last_sent(fixture.transport)
	if not _check(pong.get("type") == "platform.pong" and pong.get("payload") == {"nonce": nonce}, "ping was not answered exactly"):
		return false
	fixture.transport.queue(_move(2, "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", BLACK_ID, "black", 7, 7))
	fixture.client.poll()
	var requested := _last_sent(fixture.transport)
	return _check(requested.get("type") == "platform.snapshot.requested", "gap did not request snapshot") \
		and _check(requested.get("payload") == {"currentRevision": 0}, "snapshot request revision wrong") \
		and _check(fixture.state.revision == 0 and fixture.state.cell(7, 7) == 0, "gap event changed state")


static func _signals_snapshot_recovery_once() -> bool:
	var fixture := _connected_fixture()
	if not fixture.client.has_signal("snapshot_sync_started"):
		return _check(false, "match client does not expose snapshot recovery signal")
	var sync_starts: Array[int] = []
	fixture.client.snapshot_sync_started.connect(func() -> void: sync_starts.append(1))
	var sent_before: int = fixture.transport.sent.size()
	fixture.transport.queue(_move(2, "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", BLACK_ID, "black", 7, 7))
	fixture.client.poll()
	fixture.transport.queue(_move(3, "ffffffff-ffff-4fff-8fff-ffffffffffff", BLACK_ID, "black", 8, 8))
	fixture.client.poll()
	if not (_check(sync_starts.size() == 1, "duplicate revision gaps emitted repeated recovery signals") \
		and _check(_sent_type_count(fixture.transport, "platform.snapshot.requested", sent_before) == 1, "duplicate revision gaps sent repeated snapshot requests")):
		return false

	fixture.transport.queue(_snapshot(0))
	fixture.client.poll()
	fixture.client._request_snapshot()
	fixture.client._request_snapshot()
	if not (_check(sync_starts.size() == 2, "manual recovery emitted repeated signals") \
		and _check(_sent_type_count(fixture.transport, "platform.snapshot.requested", sent_before) == 2, "manual recovery sent repeated snapshot requests")):
		return false
	fixture.transport.queue(_snapshot(0))
	fixture.client.poll()
	fixture.transport.queue(_error_bound(0, "stale_revision"))
	fixture.client.poll()
	fixture.transport.queue(_error_bound(0, "stale_revision"))
	fixture.client.poll()
	return _check(sync_starts.size() == 3, "stale revision did not start exactly one new recovery") \
		and _check(_sent_type_count(fixture.transport, "platform.snapshot.requested", sent_before) == 3, "stale revision did not send exactly one new snapshot request")


static func _sends_actions_authoritatively() -> bool:
	var fixture := _connected_fixture()
	var action_id: String = fixture.client.request_move(7, 7)
	if not _check(action_id == "00010203-0405-4607-8809-0a0b0c0d0e0f", "deterministic action UUID wrong: %s" % action_id) \
		or not _check(fixture.state.cell(7, 7) == 0, "move request placed an optimistic stone") \
		or not _check(not fixture.state.pending_action.is_empty(), "move request did not mark pending"):
		return false
	var action := _last_sent(fixture.transport)
	if not _check(action.get("type") == "gomoku.move.requested", "wrong move type") \
		or not _check(action.get("expectedRevision") == 0 and action.get("actionId") == action_id, "action binding wrong") \
		or not _check(action.get("payload") == {"x": 7, "y": 7}, "move payload wrong") \
		or not _check(fixture.client.request_move(8, 8).is_empty(), "second pending move was allowed") \
		or not _check(fixture.client.request_resign().is_empty(), "pending move did not block resign"):
		return false
	fixture.transport.queue(_move(1, action_id, BLACK_ID, "black", 7, 7))
	fixture.client.poll()
	return _check(fixture.state.cell(7, 7) == 1 and fixture.state.pending_action.is_empty(), "accepted move did not commit and clear pending")


static func _rolls_back_failed_send() -> bool:
	var fixture := _connected_fixture()
	fixture.transport.fail_send = true
	var action_id: String = fixture.client.request_move(7, 7)
	return _check(action_id.is_empty(), "failed send returned an action id") \
		and _check(fixture.state.pending_action.is_empty(), "failed send left pending marker") \
		and _check(fixture.state.cell(7, 7) == 0, "failed send changed board") \
		and _check(fixture.client.connection_state == "reconnecting", "failed send did not reconnect")


static func _sends_resignation() -> bool:
	var fixture := _connected_fixture()
	var move_id: String = fixture.client.request_move(7, 7)
	fixture.transport.queue(_move(1, move_id, BLACK_ID, "black", 7, 7))
	fixture.client.poll()
	var resign_id: String = fixture.client.request_resign()
	if not _check(not resign_id.is_empty() and resign_id != move_id, "resign did not receive a fresh action id"):
		return false
	var action := _last_sent(fixture.transport)
	return _check(action.get("type") == "gomoku.resign.requested", "wrong resign type") \
		and _check(action.get("actionId") == resign_id and action.get("expectedRevision") == 1, "resign binding wrong") \
		and _check(action.get("payload") == {}, "resign payload must be exactly empty") \
		and _check(not fixture.state.pending_action.is_empty() and fixture.state.cell(7, 7) == 1, "resign pending corrupted board state")


static func _never_replays_pending() -> bool:
	var fixture := _connected_fixture()
	var action_id: String = fixture.client.request_move(7, 7)
	var sent_before: int = fixture.transport.sent.size()
	fixture.transport.disconnect_now()
	fixture.client.poll()
	fixture.scheduler.fire()
	fixture.transport.open()
	fixture.client.poll()
	fixture.transport.queue(_connected(0, "resume-2"))
	fixture.client.poll()
	if not _check(fixture.transport.sent.size() == sent_before + 1, "pending action was replayed during resume") \
		or not _check(_last_sent(fixture.transport).get("type") == "platform.connect", "resume handshake missing") \
		or not _check(fixture.state.pending_action.get("action_id") == action_id, "ambiguous pending changed before snapshot"):
		return false
	fixture.transport.queue(_snapshot(0))
	fixture.client.poll()
	return _check(fixture.state.pending_action.is_empty(), "authoritative resume snapshot did not settle pending")


static func _rejects_bad_server_messages() -> bool:
	var bad_messages := [
		'{"protocolVersion":1,"gameId":"gomoku","matchId":"%s","revision":0,"type":"platform.ping","payload":{"nonce":"%s","nonce":"%s"}}' % [MATCH_ID, CONNECTION_ID, CONNECTION_ID],
		'{"protocolVersion":1,"gameId":"gomoku","matchId":"%s","revision":0,"type":"platform.snapshot","payload":{"status":"active"}}' % MATCH_ID,
		'{"protocolVersion":1,"type":"platform.error","payload":{"code":"resume_expired","message":"fixed","details":{}}}%s' % "x".repeat(Protocol.MAX_MESSAGE_BYTES),
	]
	for message in bad_messages:
		var fixture := _connected_fixture()
		var revision_before: int = fixture.state.revision
		fixture.transport.incoming.append(message)
		fixture.client.poll()
		if not _check(fixture.client.connection_state == "reconnecting", "malformed server message did not fail closed") \
			or not _check(fixture.state.revision == revision_before, "malformed server message changed state"):
			return false
	return true


static func _closes_permanently() -> bool:
	var fixture := _fixture()
	fixture.transport.fail_connect = true
	fixture.client.start("ws://127.0.0.1:8080/v1/ws", MATCH_ID, "ticket", fixture.state)
	var attempts: int = fixture.transport.urls.size()
	fixture.client.close()
	fixture.scheduler.fire()
	fixture.client.poll()
	return _check(fixture.client.connection_state == "closed", "close did not enter closed state") \
		and _check(not fixture.scheduler.active and fixture.transport.urls.size() == attempts, "closed client retried")


static func _does_not_stringify_credentials() -> bool:
	var fixture := _fixture()
	var launch_secret := "launch-secret-string-canary"
	var resume_secret := "resume-secret-string-canary"
	fixture.client.start("ws://127.0.0.1:8080/v1/ws", MATCH_ID, launch_secret, fixture.state)
	fixture.transport.open()
	fixture.client.poll()
	if str(fixture.client).contains(launch_secret):
		return _check(false, "client string exposed launch ticket")
	fixture.transport.queue(_connected(0, resume_secret))
	fixture.transport.queue(_snapshot(0))
	fixture.client.poll()
	var public_text := "%s %s" % [str(fixture.client), fixture.client.last_error_code]
	fixture.client.close()
	return _check(not public_text.contains(launch_secret) and not public_text.contains(resume_secret), "client public string exposed a credential")


static func _formats_uuid_v4() -> bool:
	var bytes := PackedByteArray([255, 238, 221, 204, 187, 170, 153, 136, 119, 102, 85, 68, 51, 34, 17, 0])
	var value: String = MatchClient.generate_uuid_v4(FakeRandom.new(bytes))
	return _check(value == "ffeeddcc-bbaa-4988-b766-554433221100", "UUID bits/format wrong: %s" % value) \
		and _check(MatchClient.generate_uuid_v4(FakeRandom.new(PackedByteArray([1, 2]))).is_empty(), "short random input accepted")


static func _fixture() -> Dictionary:
	var transport := FakeTransport.new()
	var scheduler := FakeScheduler.new()
	var random := FakeRandom.new()
	var state = GomokuState.new(MATCH_ID)
	var client = MatchClient.new(transport, scheduler, random)
	return {"client": client, "transport": transport, "scheduler": scheduler, "random": random, "state": state}


static func _connected_fixture() -> Dictionary:
	var fixture := _fixture()
	fixture.client.start("ws://127.0.0.1:8080/v1/ws", MATCH_ID, "launch-secret", fixture.state)
	fixture.transport.open()
	fixture.client.poll()
	fixture.transport.queue(_connected(0, "resume-secret"))
	fixture.transport.queue(_snapshot(0))
	fixture.client.poll()
	return fixture


static func _last_sent(transport: FakeTransport) -> Dictionary:
	if transport.sent.is_empty():
		return {}
	var decoded: Dictionary = Protocol.decode(transport.sent.back())
	return decoded.get("envelope", {}) if decoded.get("ok", false) else {}


static func _sent_type_count(transport: FakeTransport, message_type: String, start_index: int = 0) -> int:
	var count := 0
	for index in range(start_index, transport.sent.size()):
		var decoded: Dictionary = Protocol.decode(transport.sent[index])
		if decoded.get("ok", false) and decoded["envelope"].get("type") == message_type:
			count += 1
	return count


static func _connected(revision: int, resume_token: String) -> Dictionary:
	return {
		"protocolVersion": 1, "gameId": "gomoku", "matchId": MATCH_ID, "revision": revision,
		"type": "platform.connected", "payload": {
			"userId": BLACK_ID, "connectionId": CONNECTION_ID,
			"resumeToken": resume_token, "resumeExpiresAt": 4102444800000,
		},
	}


static func _snapshot(revision: int) -> Dictionary:
	var board: Array = []
	board.resize(225)
	board.fill(0)
	return {
		"protocolVersion": 1, "gameId": "gomoku", "matchId": MATCH_ID, "revision": revision,
		"type": "platform.snapshot", "payload": {
			"status": "active", "board": board, "boardSize": 15,
			"blackUserId": BLACK_ID, "whiteUserId": WHITE_ID, "nextColor": "black",
			"winnerUserId": null, "result": null,
		},
	}


static func _move(revision: int, action_id: String, user_id: String, color: String, x: int, y: int) -> Dictionary:
	return {
		"protocolVersion": 1, "gameId": "gomoku", "matchId": MATCH_ID, "revision": revision,
		"type": "gomoku.move.accepted", "actionId": action_id,
		"payload": {"x": x, "y": y, "color": color, "userId": user_id},
	}


static func _ping(revision: int, nonce: String) -> Dictionary:
	return {
		"protocolVersion": 1, "gameId": "gomoku", "matchId": MATCH_ID,
		"revision": revision, "type": "platform.ping", "payload": {"nonce": nonce},
	}


static func _error_unbound(code: String) -> Dictionary:
	return {"protocolVersion": 1, "type": "platform.error", "payload": {"code": code, "message": "fixed", "details": {}}}


static func _error_bound(revision: int, code: String) -> Dictionary:
	return {
		"protocolVersion": 1, "gameId": "gomoku", "matchId": MATCH_ID,
		"revision": revision, "type": "platform.error",
		"payload": {"code": code, "message": "fixed", "details": {}},
	}


static func _check(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition
