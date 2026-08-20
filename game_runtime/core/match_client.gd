extends RefCounted

signal connection_state_changed(next_state: String)
signal snapshot_received(envelope: Dictionary)
signal event_received(envelope: Dictionary)
signal match_error(code: String)
signal return_to_lobby_requested(code: String)

const Protocol = preload("res://core/protocol.gd")

const STATE_CONNECTING := "connecting"
const STATE_CONNECTED := "connected"
const STATE_RECONNECTING := "reconnecting"
const STATE_FAILED := "failed"
const STATE_CLOSED := "closed"
const RETRY_DELAYS := [1.0, 2.0, 4.0, 8.0, 15.0]
const MAX_FAILURES := 6
const ATTEMPT_TIMEOUT_SECONDS := 10.0
const INBOUND_TIMEOUT_SECONDS := 45.0
const POLICY_VIOLATION_CLOSE_CODE := 1008
const TERMINAL_HANDSHAKE_REASONS := ["resume_expired", "ticket_invalid", "invalid_request"]
const KNOWN_ERROR_CODES := [
	"ticket_invalid", "resume_expired", "stale_revision", "action_conflict",
	"not_your_turn", "cell_occupied", "invalid_request", "match_not_found", "internal_error",
]

var connection_state := STATE_CLOSED
var local_user_id := ""
var last_error_code := ""

var _transport: Variant
var _scheduler: Variant
var _random_source: Variant
var _game_state: Variant
var _ws_url := ""
var _match_id := ""
var _launch_ticket := ""
var _resume_token := ""
var _attempt_active := false
var _connect_sent := false
var _snapshot_requested := false
var _awaiting_initial_snapshot := false
var _handshake_revision := -1
var _failure_count := 0
var _retry_handle := -1
var _retry_generation := 0
var _watchdog_handle := -1
var _watchdog_generation := 0
var _issued_action_ids := {}


func _init(
	transport: Variant = null,
	scheduler: Variant = null,
	random_source: Variant = null,
	clock: Variant = null
) -> void:
	_transport = transport if transport != null else _WebSocketTransport.new()
	_random_source = random_source if random_source != null else _CryptoRandom.new()
	_scheduler = scheduler if scheduler != null else _PollingScheduler.new(
		clock if clock != null else _MonotonicClock.new()
	)


func start(ws_url: String, match_id: String, launch_ticket: String, game_state: Variant) -> bool:
	if connection_state != STATE_CLOSED or not _dependencies_configured() \
		or not _valid_ws_url(ws_url) or not _canonical_uuid(match_id) \
		or launch_ticket.is_empty() or launch_ticket.length() > 256 or launch_ticket.to_utf8_buffer().size() > 256 \
		or game_state == null:
		return false
	_ws_url = ws_url
	_match_id = match_id
	_launch_ticket = launch_ticket
	_game_state = game_state
	_failure_count = 0
	_issued_action_ids.clear()
	last_error_code = ""
	_begin_attempt(true)
	return true


func poll() -> void:
	if _scheduler.has_method("poll"):
		_scheduler.poll()
	if connection_state in [STATE_FAILED, STATE_CLOSED] or not _attempt_active:
		return
	_transport.poll()
	var ready: String = _transport.get_ready_state()
	if ready == "open":
		if not _connect_sent and not _send_connect():
			_attempt_failed("send_failed")
			return
	if ready in ["open", "closing", "closed"]:
		while connection_state not in [STATE_FAILED, STATE_CLOSED]:
			var received: Dictionary = _transport.receive_text()
			if not received.get("ok", false):
				if received.get("fatal", false):
					_attempt_failed("invalid_message")
					return
				break
			if not _handle_text(received.get("text", "")):
				return
	if ready == "closed" and _attempt_active:
		_handle_transport_closed()


func request_move(x: int, y: int) -> String:
	if connection_state != STATE_CONNECTED or _awaiting_initial_snapshot or _snapshot_requested \
		or not _game_state.can_request_move(x, y, local_user_id):
		return ""
	var action_id := _new_action_id()
	if action_id.is_empty() or not _game_state.mark_pending(action_id, x, y):
		return ""
	var encoded: Dictionary = Protocol.encode_action(
		Protocol.TYPE_GOMOKU_MOVE_REQUESTED,
		_match_id,
		_game_state.revision,
		action_id,
		{"x": x, "y": y},
	)
	if not encoded.get("ok", false) or not _transport.send_text(encoded.get("text", "")):
		_game_state.clear_pending(action_id)
		_attempt_failed("send_failed")
		return ""
	return action_id


func request_resign() -> String:
	if connection_state != STATE_CONNECTED or _awaiting_initial_snapshot or _snapshot_requested \
		or not _game_state.can_request_resign(local_user_id):
		return ""
	var action_id := _new_action_id()
	if action_id.is_empty() or not _game_state.mark_pending_resign(action_id, local_user_id):
		return ""
	var encoded: Dictionary = Protocol.encode_action(
		Protocol.TYPE_GOMOKU_RESIGN_REQUESTED,
		_match_id,
		_game_state.revision,
		action_id,
		{},
	)
	if not encoded.get("ok", false) or not _transport.send_text(encoded.get("text", "")):
		_game_state.clear_pending(action_id)
		_attempt_failed("send_failed")
		return ""
	return action_id


func close() -> void:
	if connection_state == STATE_CLOSED:
		return
	_retry_generation += 1
	_scheduler.cancel(_retry_handle)
	_retry_handle = -1
	_cancel_watchdog()
	_attempt_active = false
	_connect_sent = false
	_transport.close()
	_launch_ticket = ""
	_resume_token = ""
	_ws_url = ""
	_awaiting_initial_snapshot = false
	_handshake_revision = -1
	_set_connection_state(STATE_CLOSED)


func dispose() -> void:
	close()


static func generate_uuid_v4(random_source: Variant) -> String:
	if random_source == null or not random_source.has_method("generate_bytes"):
		return ""
	var bytes: Variant = random_source.generate_bytes(16)
	if not bytes is PackedByteArray or bytes.size() != 16:
		return ""
	bytes = bytes.duplicate()
	bytes[6] = (bytes[6] & 0x0f) | 0x40
	bytes[8] = (bytes[8] & 0x3f) | 0x80
	var encoded := ""
	for index in 16:
		if index in [4, 6, 8, 10]:
			encoded += "-"
		encoded += "%02x" % bytes[index]
	return encoded


func _new_action_id() -> String:
	# Crypto collisions are vanishingly unlikely, but the wire contract still
	# requires every action in this client lifetime to use a fresh id. A
	# bounded retry also makes deterministic/random-source failures fail closed.
	for _attempt in 8:
		var candidate := generate_uuid_v4(_random_source)
		if candidate.is_empty():
			return ""
		if not _issued_action_ids.has(candidate):
			_issued_action_ids[candidate] = true
			return candidate
	return ""


func _begin_attempt(initial: bool = false) -> void:
	if connection_state in [STATE_FAILED, STATE_CLOSED] and not initial:
		return
	_retry_handle = -1
	_attempt_active = true
	_connect_sent = false
	_snapshot_requested = false
	_awaiting_initial_snapshot = false
	_handshake_revision = -1
	_set_connection_state(STATE_CONNECTING if initial else STATE_RECONNECTING)
	_schedule_watchdog(ATTEMPT_TIMEOUT_SECONDS, "attempt")
	if not _transport.connect_to_url(_ws_url):
		_attempt_active = false
		_attempt_failed("connect_failed")


func _send_connect() -> bool:
	var credential_name := "resumeToken" if not _resume_token.is_empty() else "launchTicket"
	var credential := _resume_token if credential_name == "resumeToken" else _launch_ticket
	var encoded: Dictionary = Protocol.encode_connect(credential_name, credential)
	if not encoded.get("ok", false) or not _transport.send_text(encoded.get("text", "")):
		return false
	_connect_sent = true
	return true


func _handle_text(text: String) -> bool:
	var decoded: Dictionary = Protocol.decode(text)
	if not decoded.get("ok", false):
		_attempt_failed("invalid_message")
		return false
	var envelope: Dictionary = decoded["envelope"]
	var message_type: String = envelope["type"]
	var handled := false
	match message_type:
		Protocol.TYPE_PLATFORM_CONNECTED:
			handled = _handle_connected(envelope)
		Protocol.TYPE_PLATFORM_SNAPSHOT:
			handled = _handle_snapshot(envelope)
		Protocol.TYPE_PLATFORM_PING:
			handled = _handle_ping(envelope)
		Protocol.TYPE_PLATFORM_ERROR:
			handled = _handle_error(envelope)
		Protocol.TYPE_GOMOKU_MOVE_ACCEPTED, Protocol.TYPE_GOMOKU_RESIGNED, \
		Protocol.TYPE_PLATFORM_MATCH_CANCELLED, Protocol.TYPE_PLATFORM_MATCH_ABANDONED:
			handled = _handle_event(envelope)
		_:
			_attempt_failed("invalid_message")
			return false
	if handled:
		_record_valid_inbound()
	return handled


func _handle_connected(envelope: Dictionary) -> bool:
	if not _connect_sent or connection_state not in [STATE_CONNECTING, STATE_RECONNECTING] \
		or not _exact_keys(envelope, ["gameId", "matchId", "payload", "protocolVersion", "revision", "type"]) \
		or not _valid_bound(envelope, Protocol.TYPE_PLATFORM_CONNECTED):
		return _protocol_failure()
	var payload: Variant = envelope["payload"]
	if not payload is Dictionary or not _exact_keys(payload, ["connectionId", "resumeExpiresAt", "resumeToken", "userId"]) \
		or not _canonical_uuid(payload.get("userId")) or not _canonical_uuid(payload.get("connectionId")) \
		or not payload.get("resumeToken") is String or payload["resumeToken"].is_empty() \
		or payload["resumeToken"].length() > 256 or payload["resumeToken"].to_utf8_buffer().size() > 256 \
		or typeof(payload.get("resumeExpiresAt")) != TYPE_INT or payload["resumeExpiresAt"] <= 0:
		return _protocol_failure()
	if not local_user_id.is_empty() and local_user_id != payload["userId"]:
		return _protocol_failure()
	local_user_id = payload["userId"]
	_resume_token = payload["resumeToken"]
	_launch_ticket = ""
	_handshake_revision = envelope["revision"]
	_awaiting_initial_snapshot = true
	_set_connection_state(STATE_CONNECTED)
	return true


func _handle_snapshot(envelope: Dictionary) -> bool:
	if connection_state != STATE_CONNECTED or local_user_id.is_empty() \
		or not _valid_bound(envelope, Protocol.TYPE_PLATFORM_SNAPSHOT) \
		or (_awaiting_initial_snapshot and envelope["revision"] != _handshake_revision):
		return _protocol_failure()
	var applied: Dictionary = _game_state.apply_snapshot(envelope)
	if not applied.get("ok", false) or applied.get("status") != "applied" \
		or local_user_id not in [_game_state.black_user_id, _game_state.white_user_id]:
		return _protocol_failure()
	_snapshot_requested = false
	_awaiting_initial_snapshot = false
	_handshake_revision = -1
	_cancel_watchdog()
	# Only a complete authoritative snapshot makes a connection attempt
	# meaningful enough to reset the consecutive-failure budget.
	_failure_count = 0
	_set_connection_state(STATE_CONNECTED)
	snapshot_received.emit(envelope.duplicate(true))
	return true


func _handle_event(envelope: Dictionary) -> bool:
	if connection_state != STATE_CONNECTED or _awaiting_initial_snapshot or local_user_id.is_empty() \
		or not _valid_bound(envelope, envelope.get("type", "")):
		return _protocol_failure()
	var applied: Dictionary = _game_state.apply_event(envelope)
	if not applied.get("ok", false):
		return _protocol_failure()
	if applied.get("status") == "needs_snapshot":
		return _request_snapshot()
	if applied.get("status") == "applied":
		event_received.emit(envelope.duplicate(true))
	return true


func _handle_ping(envelope: Dictionary) -> bool:
	if connection_state != STATE_CONNECTED \
		or not _exact_keys(envelope, ["gameId", "matchId", "payload", "protocolVersion", "revision", "type"]) \
		or not _valid_bound(envelope, Protocol.TYPE_PLATFORM_PING):
		return _protocol_failure()
	var payload: Variant = envelope["payload"]
	if not payload is Dictionary or not _exact_keys(payload, ["nonce"]) or not _canonical_uuid(payload.get("nonce")):
		return _protocol_failure()
	var encoded: Dictionary = Protocol.encode_pong(_match_id, payload["nonce"])
	if not encoded.get("ok", false) or not _transport.send_text(encoded.get("text", "")):
		_attempt_failed("send_failed")
		return false
	return true


func _handle_error(envelope: Dictionary) -> bool:
	var bound := envelope.has("gameId")
	if bound:
		if connection_state != STATE_CONNECTED or _awaiting_initial_snapshot \
			or not _valid_bound(envelope, Protocol.TYPE_PLATFORM_ERROR):
			return _protocol_failure()
	else:
		if not _exact_keys(envelope, ["payload", "protocolVersion", "type"]) \
			or connection_state not in [STATE_CONNECTING, STATE_RECONNECTING] or not _connect_sent \
			or envelope.get("protocolVersion") != 1 or envelope.get("type") != Protocol.TYPE_PLATFORM_ERROR:
			return _protocol_failure()
	var payload: Variant = envelope["payload"]
	if not payload is Dictionary or not _exact_keys(payload, ["code", "details", "message"]) \
		or not payload.get("code") is String or payload["code"].is_empty() or payload["code"].length() > 64 \
		or not payload.get("message") is String or payload["message"].is_empty() or payload["message"].length() > 256 \
		or not payload.get("details") is Dictionary or not payload["details"].is_empty():
		return _protocol_failure()
	var code: String = payload["code"]
	if code not in KNOWN_ERROR_CODES:
		return _protocol_failure()
	last_error_code = code
	if code in TERMINAL_HANDSHAKE_REASONS and not bound:
		_fail(code)
		return false
	if not bound:
		_attempt_failed(code)
		return false
	var handled: Dictionary = _game_state.apply_error(envelope)
	if not handled.get("ok", false):
		return _protocol_failure()
	if handled.get("status") == "needs_snapshot":
		_snapshot_requested = true
	match_error.emit(code)
	return true


func _request_snapshot() -> bool:
	if _snapshot_requested:
		return true
	var encoded: Dictionary = Protocol.encode_snapshot_request(_match_id, max(_game_state.revision, 0))
	if not encoded.get("ok", false) or not _transport.send_text(encoded.get("text", "")):
		_attempt_failed("send_failed")
		return false
	_snapshot_requested = true
	return true


func _protocol_failure() -> bool:
	_attempt_failed("invalid_message")
	return false


func _attempt_failed(code: String) -> void:
	if connection_state in [STATE_FAILED, STATE_CLOSED]:
		return
	_attempt_active = false
	_connect_sent = false
	_cancel_watchdog()
	_transport.close()
	_failure_count += 1
	last_error_code = code
	if _failure_count >= MAX_FAILURES:
		_fail("connection_failed")
		return
	_set_connection_state(STATE_RECONNECTING)
	_retry_generation += 1
	var generation := _retry_generation
	var client_reference: WeakRef = weakref(self)
	_retry_handle = _scheduler.schedule(RETRY_DELAYS[_failure_count - 1], func() -> void:
		var client: Variant = client_reference.get_ref()
		if client != null:
			client._run_retry(generation)
	)


func _run_retry(generation: int) -> void:
	if generation != _retry_generation or connection_state != STATE_RECONNECTING:
		return
	_begin_attempt(false)


func _fail(code: String) -> void:
	_retry_generation += 1
	_scheduler.cancel(_retry_handle)
	_retry_handle = -1
	_cancel_watchdog()
	_attempt_active = false
	_transport.close()
	_launch_ticket = ""
	_resume_token = ""
	_awaiting_initial_snapshot = false
	_handshake_revision = -1
	last_error_code = code
	_set_connection_state(STATE_FAILED)
	return_to_lobby_requested.emit(code)


func _set_connection_state(next_state: String) -> void:
	if connection_state == next_state:
		return
	connection_state = next_state
	connection_state_changed.emit(next_state)


func _valid_bound(envelope: Dictionary, message_type: String) -> bool:
	return envelope.get("protocolVersion") == 1 and envelope.get("gameId") == "gomoku" \
		and envelope.get("matchId") == _match_id and envelope.get("type") == message_type \
		and typeof(envelope.get("revision")) == TYPE_INT and envelope["revision"] >= 0 \
		and not envelope.has("expectedRevision")


func _record_valid_inbound() -> void:
	if connection_state == STATE_CONNECTED and not _awaiting_initial_snapshot:
		_schedule_watchdog(INBOUND_TIMEOUT_SECONDS, "inbound")


func _schedule_watchdog(delay_seconds: float, kind: String) -> void:
	_cancel_watchdog()
	_watchdog_generation += 1
	var generation := _watchdog_generation
	var client_reference: WeakRef = weakref(self)
	_watchdog_handle = _scheduler.schedule(delay_seconds, func() -> void:
		var client: Variant = client_reference.get_ref()
		if client != null:
			client._on_watchdog(generation, kind)
	)


func _cancel_watchdog() -> void:
	_watchdog_generation += 1
	if _watchdog_handle >= 0:
		_scheduler.cancel(_watchdog_handle)
	_watchdog_handle = -1


func _on_watchdog(generation: int, kind: String) -> void:
	if generation != _watchdog_generation or not _attempt_active:
		return
	_watchdog_handle = -1
	if kind == "attempt" and (connection_state in [STATE_CONNECTING, STATE_RECONNECTING] or _awaiting_initial_snapshot):
		_attempt_failed("connection_timeout")
	elif kind == "inbound" and connection_state == STATE_CONNECTED and not _awaiting_initial_snapshot:
		_attempt_failed("connection_lost")


func _handle_transport_closed() -> void:
	var info: Dictionary = _transport.get_close_info()
	var code: Variant = info.get("code", -1)
	var reason: Variant = info.get("reason", "")
	var handshake_phase := connection_state in [STATE_CONNECTING, STATE_RECONNECTING] or _awaiting_initial_snapshot
	if handshake_phase and typeof(code) == TYPE_INT and code == POLICY_VIOLATION_CLOSE_CODE \
		and reason is String and reason in TERMINAL_HANDSHAKE_REASONS:
		_fail(reason)
		return
	_attempt_failed("connection_lost")


static func _exact_keys(value: Dictionary, expected: Array) -> bool:
	if value.size() != expected.size():
		return false
	for key in value:
		if not key is String or not expected.has(key):
			return false
	return true


static func _canonical_uuid(value: Variant) -> bool:
	if not value is String:
		return false
	var pattern := RegEx.create_from_string("^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
	return pattern.search(value) != null


static func _valid_ws_url(value: String) -> bool:
	if not (value.begins_with("ws://") or value.begins_with("wss://")) or value.length() > 2048:
		return false
	for index in value.length():
		var code := value.unicode_at(index)
		if code <= 32 or code == 127:
			return false
	var separator := value.find("://")
	var authority_and_suffix := value.substr(separator + 3)
	var authority_end := authority_and_suffix.length()
	for delimiter in ["/", "?", "#"]:
		var delimiter_index := authority_and_suffix.find(delimiter)
		if delimiter_index >= 0:
			authority_end = min(authority_end, delimiter_index)
	var authority := authority_and_suffix.left(authority_end)
	return not authority.is_empty() and not authority.contains("@") and not authority.contains("\\") \
		and not authority.contains("%")


func _dependencies_configured() -> bool:
	if _transport == null or _scheduler == null or _random_source == null:
		return false
	for method in ["connect_to_url", "poll", "get_ready_state", "receive_text", "send_text", "get_close_info", "close"]:
		if not _transport.has_method(method):
			return false
	for method in ["schedule", "cancel"]:
		if not _scheduler.has_method(method):
			return false
	return _random_source.has_method("generate_bytes")


class _CryptoRandom:
	extends RefCounted
	var _crypto := Crypto.new()

	func generate_bytes(count: int) -> PackedByteArray:
		return _crypto.generate_random_bytes(count)


class _MonotonicClock:
	extends RefCounted

	func now_msec() -> int:
		return Time.get_ticks_msec()


class _PollingScheduler:
	extends RefCounted
	var _clock: Variant
	var _callback := Callable()
	var _generation := 0
	var _due_msec := -1

	func _init(clock: Variant) -> void:
		_clock = clock

	func schedule(delay_seconds: float, callback: Callable) -> int:
		cancel()
		_generation += 1
		_callback = callback
		_due_msec = _clock.now_msec() + int(delay_seconds * 1000.0)
		return _generation

	func cancel(_handle: int = -1) -> void:
		_callback = Callable()
		_due_msec = -1

	func poll() -> void:
		if _due_msec < 0 or _clock.now_msec() < _due_msec:
			return
		var callback := _callback
		_callback = Callable()
		_due_msec = -1
		if callback.is_valid():
			callback.call()


class _WebSocketTransport:
	extends RefCounted
	var _peer: WebSocketPeer
	var _close_code := -1
	var _close_reason := ""

	func connect_to_url(url: String) -> bool:
		close()
		_close_code = -1
		_close_reason = ""
		_peer = WebSocketPeer.new()
		return _peer.connect_to_url(url) == OK

	func poll() -> void:
		if _peer != null:
			_peer.poll()
			if _peer.get_ready_state() == WebSocketPeer.STATE_CLOSED:
				_close_code = _peer.get_close_code()
				_close_reason = _peer.get_close_reason()

	func get_ready_state() -> String:
		if _peer == null:
			return "closed"
		match _peer.get_ready_state():
			WebSocketPeer.STATE_CONNECTING:
				return "connecting"
			WebSocketPeer.STATE_OPEN:
				return "open"
			WebSocketPeer.STATE_CLOSING:
				return "closing"
			_:
				return "closed"

	func receive_text() -> Dictionary:
		if _peer == null or _peer.get_available_packet_count() == 0:
			return {"ok": false}
		var packet := _peer.get_packet()
		if not _peer.was_string_packet() or packet.size() > Protocol.MAX_MESSAGE_BYTES:
			return {"ok": false, "fatal": true}
		var text := packet.get_string_from_utf8()
		if text.to_utf8_buffer() != packet:
			return {"ok": false, "fatal": true}
		return {"ok": true, "text": text}

	func send_text(text: String) -> bool:
		return _peer != null and _peer.get_ready_state() == WebSocketPeer.STATE_OPEN \
			and text.to_utf8_buffer().size() <= Protocol.MAX_MESSAGE_BYTES and _peer.send_text(text) == OK

	func get_close_info() -> Dictionary:
		return {"code": _close_code, "reason": _close_reason}

	func close() -> void:
		if _peer != null:
			if _peer.get_ready_state() in [WebSocketPeer.STATE_CONNECTING, WebSocketPeer.STATE_OPEN, WebSocketPeer.STATE_CLOSING]:
				_peer.close(1000, "")
			_peer = null
