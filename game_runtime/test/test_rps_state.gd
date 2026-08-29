extends RefCounted

const RpsState = preload("res://games/rps/rps_state.gd")
const Protocol = preload("res://core/protocol.gd")
const RpsScene = preload("res://games/rps/rps_scene.tscn")
const GameboxTokens = preload("res://design_system/generated/gamebox_tokens.gd")
const GameboxTheme = preload("res://design_system/gamebox_theme.gd")
const MATCH_ID := "11111111-1111-4111-8111-111111111111"
const ME := "22222222-2222-4222-8222-222222222222"
const OPPONENT := "33333333-3333-4333-8333-333333333333"
const ACTION_ID := "44444444-4444-4444-8444-444444444444"


static func cases() -> Array:
	return [
		{"name": "rps restores sealed reconnect state without opponent choice", "run": _sealed_snapshot},
		{"name": "rps locks once and advances a draw round", "run": _lock_and_draw},
		{"name": "rps applies authoritative best-of-three completion", "run": _terminal_reveal},
		{"name": "rps rejects reveal winners outside the match", "run": _foreign_reveal_winner},
		{"name": "rps protocol binds choice actions to rps", "run": _protocol_choice},
		{"name": "rps scene uses transparent image choices in rock scissors paper order", "run": _scene_contract},
		{"name": "rps status chips distinguish waiting from choice progress", "run": _status_chip_states},
		{"name": "rps status chips emphasize only the player who acted", "run": _status_chip_player_binding},
		{"name": "rps terminal result preserves reveal evidence and review path", "run": _terminal_result_presentation},
		{"name": "rps single-round loss describes one decisive round", "run": _single_round_loss_presentation},
		{"name": "rps terminal result omits unavailable reveal evidence", "run": _terminal_result_without_reveal},
		{"name": "rps resignation result does not invent round evidence", "run": _resignation_result_presentation},
		{"name": "rps lock events do not replay a stale reveal", "run": _lock_event_does_not_replay_stale_reveal},
		{"name": "rps snapshots cancel stale reveal playback", "run": _snapshot_cancels_reveal_playback},
		{"name": "rps overflow menu requires explicit resign selection", "run": _overflow_menu_requires_explicit_resign},
		{"name": "rps reconnect keeps the confirmed match behind a compact banner", "run": _reconnect_keeps_confirmed_match},
	]


static func _sealed_snapshot() -> bool:
	var state = RpsState.new(MATCH_ID)
	var restored: Dictionary = state.apply_snapshot(_snapshot(4, "best_of_three", 3, {
		"userId": ME, "score": 1, "locked": true, "choice": "paper",
	}, {
		"userId": OPPONENT, "score": 1, "locked": true,
	}))
	var valid := _check(restored.get("ok", false), "expected sealed snapshot") \
		and _check(state.me_choice == "paper", "expected own sealed choice") \
		and _check(state.opponent_locked, "expected opponent lock state")
	var leaked := _snapshot(4, "best_of_three", 3, {
		"userId": ME, "score": 1, "locked": true, "choice": "paper",
	}, {
		"userId": OPPONENT, "score": 1, "locked": true, "choice": "rock",
	})
	return valid and _check(not RpsState.new(MATCH_ID).apply_snapshot(leaked).get("ok", true), "opponent choice must be rejected")


static func _lock_and_draw() -> bool:
	var state = RpsState.new(MATCH_ID)
	if not state.apply_snapshot(_snapshot(0, "best_of_three", 1, {
		"userId": ME, "score": 0, "locked": false,
	}, {
		"userId": OPPONENT, "score": 0, "locked": false,
	})).get("ok", false):
		return _check(false, "expected initial snapshot")
	if not state.mark_pending_choice(ACTION_ID, "rock", ME):
		return _check(false, "expected pending choice")
	var locked := state.apply_event(_event(1, "rps.choice.locked", {
		"round": 1, "userId": ME, "locked": true,
	}, ACTION_ID))
	if not locked.get("ok", false) or not state.me_locked or state.me_choice != "rock" \
		or not state.pending_action.is_empty():
		return _check(false, "expected one authoritative local lock")
	var reveal := state.apply_event(_event(2, "rps.round.revealed", _reveal(
		1, "rock", "rock", null, true, 0, 0, null
	)))
	return _check(reveal.get("ok", false), "expected draw reveal") \
		and _check(state.round_number == 2, "draw must advance the round") \
		and _check(state.me_score == 0 and state.opponent_score == 0, "draw must not score") \
		and _check(not state.me_locked and not state.opponent_locked, "next round must unlock")


static func _terminal_reveal() -> bool:
	var state = RpsState.new(MATCH_ID)
	if not state.apply_snapshot(_snapshot(2, "best_of_three", 2, {
		"userId": ME, "score": 1, "locked": true, "choice": "paper",
	}, {
		"userId": OPPONENT, "score": 0, "locked": true,
	})).get("ok", false):
		return _check(false, "expected round two snapshot")
	var reveal := state.apply_event(_event(3, "rps.round.revealed", _reveal(
		2, "paper", "rock", ME, false, 2, 0, ME
	), ACTION_ID))
	return _check(reveal.get("ok", false), "expected terminal reveal") \
		and _check(state.status == "finished", "expected terminal status") \
		and _check(state.winner_user_id == ME, "expected authoritative winner") \
		and _check(state.me_score == 2, "expected authoritative score")


static func _protocol_choice() -> bool:
	var encoded: Dictionary = Protocol.encode_action(
		Protocol.TYPE_RPS_CHOICE_REQUESTED, MATCH_ID, 7, ACTION_ID, {"choice": "scissors"}, "rps"
	)
	if not encoded.get("ok", false):
		return _check(false, "expected RPS action encoding")
	var decoded: Dictionary = Protocol.decode(encoded["text"])
	return _check(decoded.get("ok", false), "expected RPS action decoding") \
		and _check(decoded["envelope"]["gameId"] == "rps", "expected RPS binding")


static func _foreign_reveal_winner() -> bool:
	var state = RpsState.new(MATCH_ID)
	if not state.apply_snapshot(_snapshot(1, "best_of_three", 1, {
		"userId": ME, "score": 0, "locked": true, "choice": "rock",
	}, {
		"userId": OPPONENT, "score": 0, "locked": true,
	})).get("ok", false):
		return _check(false, "expected locked snapshot")
	var foreign := "55555555-5555-4555-8555-555555555555"
	var reveal := _reveal(1, "rock", "scissors", foreign, false, 1, 0, null)
	return _check(not state.apply_event(_event(2, "rps.round.revealed", reveal)).get("ok", true), "foreign winner must be rejected")


static func _scene_contract() -> bool:
	var scene: Node = RpsScene.instantiate()
	scene.call("_apply_scene_typography")
	scene.call("_apply_scene_spacing")
	var choices: HBoxContainer = scene.get_node("SafeContent/Layout/MySection/ChoicePanel/Choices")
	var rock: Button = scene.get_node("SafeContent/Layout/MySection/ChoicePanel/Choices/RockButton")
	var paper: Button = scene.get_node("SafeContent/Layout/MySection/ChoicePanel/Choices/PaperButton")
	var scissors: Button = scene.get_node("SafeContent/Layout/MySection/ChoicePanel/Choices/ScissorsButton")
	var passed := _check(scene is Control, "expected portrait control scene") \
		and _check(choices.get_child(0) == rock, "rock must be the first choice") \
		and _check(choices.get_child(1) == scissors, "scissors must be the second choice") \
		and _check(choices.get_child(2) == paper, "paper must be the third choice") \
		and _check(rock.custom_minimum_size == paper.custom_minimum_size, "choice targets must be equal") \
		and _check(paper.custom_minimum_size == scissors.custom_minimum_size, "choice targets must be equal") \
		and _check(rock.custom_minimum_size.x >= 192 and rock.custom_minimum_size.y >= 256, "choice targets must be at least 96dp by 128dp") \
		and _check(rock.flat and paper.flat and scissors.flat, "choice backgrounds must stay transparent") \
		and _check(scene.has_node("SafeContent/Layout/OpponentSection/OpponentVisual/Unknown"), "sealed opponent placeholder must exist") \
		and _check(scene.has_node("SafeContent/Layout/OpponentSection/OpponentVisual/Locked"), "sealed opponent lock state must exist") \
		and _check(scene.has_node("SafeContent/Layout/OpponentSection/OpponentVisual/UnknownSurface"), "sealed opponent placeholder needs a dedicated surface") \
		and _check(scene.has_node("SafeContent/Layout/OpponentSection/OpponentVisual/LockedSurface"), "locked opponent needs a dedicated surface") \
		and _check(scene.has_node("SafeContent/Layout/OpponentSection/StatusLine/Spacer"), "opponent status must stay right-aligned") \
		and _check(scene.has_node("SafeContent/Layout/OpponentSection/StatusLine/Identity/Avatar"), "opponent identity must include the prototype avatar") \
		and _check(scene.has_node("SafeContent/Layout/OpponentSection/StatusLine/StatusChip/Content/DotSlot/Dot"), "opponent status must include the prototype dot") \
		and _check(scene.has_node("SafeContent/Layout/RoundStage/Content/RoundMeta/RoundChip/RoundLabel"), "round stage must present the round as a chip") \
		and _check(scene.has_node("SafeContent/Layout/RoundStage/Content/Scoreboard/MySide/ScoreLabel"), "round stage must split the local score from its label") \
		and _check(scene.has_node("SafeContent/Layout/RoundStage/Content/Scoreboard/OpponentSide/ScoreLabel"), "round stage must split the opponent score from its label") \
		and _check(scene.has_node("SafeContent/Layout/RoundStage/Content/RoundMessage/StateSupportLabel"), "round stage must keep primary and supporting copy together") \
		and _check(scene.get_node("SafeContent/Layout/RoundStage").custom_minimum_size.y == 310, "round stage must match the 155dp prototype band") \
		and _check(scene.get_node("SafeContent/Layout/RoundStage/Content/Scoreboard/MySide/ScoreLabel").get_theme_font_size("font_size") == 64, "score digits must use the prototype emphasis") \
		and _check(scene.has_node("SafeContent/Layout/MySection/SelectedPanel"), "selected gesture slot must exist") \
		and _check(scene.get_node("SafeContent/Layout/MySection/TopSpacing").custom_minimum_size.y >= 24, "local status row must keep the prototype top inset") \
		and _check(scene.has_node("SafeContent/Layout/MySection/StatusLine/Spacer"), "local status must stay right-aligned") \
		and _check(scene.has_node("SafeContent/Layout/MySection/StatusLine/Identity/Avatar"), "local identity must include the prototype avatar") \
		and _check(scene.has_node("SafeContent/Layout/MySection/StatusLine/StatusChip/Content/DotSlot/Dot"), "local status must include the prototype dot") \
		and _check(scene.has_node("BackButton") == false, "navigation controls live in the safe constrained layout") \
		and _check(scene.get_node("SafeContent/Layout/TopNavigation").has_method("present"), "shared portrait top bar must own navigation") \
		and _check(scene.has_node("SafeContent/Layout/TopNavigation/BackButton"), "visible back control must remain available") \
		and _check(scene.has_node("SafeContent/Layout/TopNavigation/ActionButton"), "resign menu control must remain available") \
		and _check(not scene.has_node("ResignButton"), "resign must not duplicate the top menu as a bottom button") \
		and _check(scene.get_node("SafeContent/Layout/TopNavigation/BackButton").theme_type_variation == &"GameboxPortraitBackButton", "back icon must use the shared portrait navigation style") \
		and _check(scene.has_node("RevealPanel"), "previous-round result panel must exist") \
		and _check(scene.get_node("RevealPanel/Content/Choices/MyChoice/Icon").texture != null, "my reveal image must load") \
		and _check(scene.get_node("RevealPanel/Content/Choices/OpponentChoice/Icon").texture != null, "opponent reveal image must load") \
		and _check(scene.get_node("TerminalArena/Backdrop").theme_type_variation == &"GameboxTerminalBackdrop", "terminal arena lost its opaque prototype backdrop") \
		and _check((scene.get_node("TerminalArena/Backdrop/Gradient") as ColorRect).material is ShaderMaterial, "terminal arena lost its radial prototype glow")
	var image_nodes_present := rock.has_node("Content/Icon") \
		and scissors.has_node("Content/Icon") and paper.has_node("Content/Icon")
	passed = _check(image_nodes_present, "each choice must render an image") and passed
	if image_nodes_present:
		var neutral_modulate := rock.modulate
		scene.call("_refresh_choice_visuals")
		passed = _check(rock.get_node("Content/Icon").texture != null, "rock image must load") \
			and _check(scissors.get_node("Content/Icon").texture != null, "scissors image must load") \
			and _check(paper.get_node("Content/Icon").texture != null, "paper image must load") \
			and _check(rock.modulate == neutral_modulate, "choice modulation must preserve authored image and text colors") \
			and _check(scissors.modulate == neutral_modulate, "choice modulation must preserve authored image and text colors") \
			and _check(paper.modulate == neutral_modulate, "choice modulation must preserve authored image and text colors") \
			and passed
	scene.free()
	return passed


static func _status_chip_states() -> bool:
	var scene: Node = RpsScene.instantiate()
	var colors: Dictionary = GameboxTokens.DARK
	var waiting: StyleBoxFlat = scene.call("_chip_style", colors, false)
	var active: StyleBoxFlat = scene.call("_chip_style", colors, true)
	var waiting_dot: StyleBoxFlat = scene.call("_status_dot_style", colors, false)
	var active_dot: StyleBoxFlat = scene.call("_status_dot_style", colors, true)
	var passed := _check(waiting.bg_color == colors["surface_container_high"], "waiting chip must use the neutral surface") \
		and _check(active.bg_color == colors["tertiary_container"], "pending and locked chips must use the prototype tertiary surface") \
		and _check(waiting_dot.bg_color == colors["outline"], "waiting chip dot must stay neutral") \
		and _check(active_dot.bg_color == colors["on_tertiary_container"], "pending and locked chip dot must use the prototype active color") \
		and _check(scene.call("_choice_status_emphasized", true, false, false), "pending must emphasize choice status") \
		and _check(scene.call("_choice_status_emphasized", false, true, false), "a player lock must emphasize that player's status") \
		and _check(not scene.call("_choice_status_emphasized", false, false, false), "waiting must remain neutral") \
		and _check(not scene.call("_choice_status_emphasized", false, true, true), "terminal status must not look like an active choice")
	scene.free()
	return passed


static func _status_chip_player_binding() -> bool:
	var harness: Dictionary = await _scene_harness()
	var scene: Control = harness["scene"]
	var client: FakeMatchClient = harness["client"]
	client.set_connection("connecting")
	client.accept_snapshot(_snapshot(1, "single_round", 1, {
		"userId": ME, "score": 0, "locked": false,
	}, {
		"userId": OPPONENT, "score": 0, "locked": false,
	}))
	client.state.mark_pending_choice(ACTION_ID, "paper", ME)
	scene.call("_refresh_ui")
	var opponent_chip := scene.get_node("SafeContent/Layout/OpponentSection/StatusLine/StatusChip") as PanelContainer
	var my_chip := scene.get_node("SafeContent/Layout/MySection/StatusLine/StatusChip") as PanelContainer
	var opponent_label := opponent_chip.get_node("Content/Label") as Label
	var my_label := my_chip.get_node("Content/Label") as Label
	var colors: Dictionary = GameboxTokens.DARK if GameboxTheme.system_prefers_dark() else GameboxTokens.LIGHT
	if not _check((my_chip.get_theme_stylebox("panel") as StyleBoxFlat).bg_color == colors["tertiary_container"], "pending did not emphasize the local chip") \
		or not _check((opponent_chip.get_theme_stylebox("panel") as StyleBoxFlat).bg_color == colors["surface_container_high"], "pending incorrectly emphasized the waiting opponent") \
		or not _check(my_label.text == "提交中", "pending local status copy changed") \
		or not _check(opponent_label.text == "等待出拳", "pending opponent status copy changed"):
		return _cleanup(scene)
	client.accept_snapshot(_snapshot(1, "single_round", 1, {
		"userId": ME, "score": 0, "locked": true, "choice": "paper",
	}, {
		"userId": OPPONENT, "score": 0, "locked": false,
	}))
	if not _check((my_chip.get_theme_stylebox("panel") as StyleBoxFlat).bg_color == colors["tertiary_container"], "local lock did not emphasize the local chip") \
		or not _check((opponent_chip.get_theme_stylebox("panel") as StyleBoxFlat).bg_color == colors["surface_container_high"], "local lock incorrectly emphasized the waiting opponent") \
		or not _check(my_label.text == "已出拳", "local lock status copy changed") \
		or not _check(opponent_label.text == "等待出拳", "waiting opponent status copy changed"):
		return _cleanup(scene)
	client.accept_snapshot(_snapshot(2, "single_round", 1, {
		"userId": ME, "score": 0, "locked": false,
	}, {
		"userId": OPPONENT, "score": 0, "locked": true,
	}))
	var result := _check((opponent_chip.get_theme_stylebox("panel") as StyleBoxFlat).bg_color == colors["tertiary_container"], "opponent lock did not emphasize the opponent chip") \
		and _check((my_chip.get_theme_stylebox("panel") as StyleBoxFlat).bg_color == colors["surface_container_high"], "opponent lock incorrectly emphasized the local waiting chip") \
		and _check(opponent_label.text == "已出拳 · 保密", "opponent lock status copy changed") \
		and _check(my_label.text == "轮到你了", "opponent lock did not identify the local turn")
	if not result:
		return _cleanup(scene)
	client.accept_snapshot(_snapshot(3, "single_round", 1, {
		"userId": ME, "score": 0, "locked": true, "choice": "paper",
	}, {
		"userId": OPPONENT, "score": 0, "locked": true,
	}))
	result = _check((opponent_chip.get_theme_stylebox("panel") as StyleBoxFlat).bg_color == colors["tertiary_container"], "both locks did not keep the opponent chip emphasized") \
		and _check((my_chip.get_theme_stylebox("panel") as StyleBoxFlat).bg_color == colors["tertiary_container"], "both locks did not keep the local chip emphasized")
	return _cleanup(scene, result)


static func _terminal_result_presentation() -> bool:
	var harness: Dictionary = await _scene_harness()
	var scene: Control = harness["scene"]
	var client: FakeMatchClient = harness["client"]
	client.accept_snapshot(_terminal_snapshot(false))
	if not _check(scene.get_node("TerminalArena").visible, "terminal arena stayed hidden") \
		or not _check((scene.get_node("TerminalArena/Score") as Label).text == "1 : 2", "terminal score did not bind") \
		or not _check((scene.get_node("TerminalArena/MyChoice/Label") as Label).text == "你 · 剪刀", "terminal local choice did not bind") \
		or not _check((scene.get_node("TerminalArena/OpponentChoice/Label") as Label).text == "对手 · 石头", "terminal opponent choice did not bind") \
		or not _check((scene.get_node("ResultPanel/Content/Result") as Label).text == "对手先拿到两分", "terminal loss title did not bind") \
		or not _check((scene.get_node("ResultPanel/Content/Summary/Item1/Content/Value") as Label).text == "1 : 2", "terminal score summary did not bind") \
		or not _check(scene.get_node("ResultScrim").visible and scene.get_node("ResultPanel").visible, "terminal result surface stayed hidden") \
		or not _check(not scene.get_node("ResultPill").visible, "terminal result pill duplicated the open card"):
		return _cleanup(scene)
	(scene.get_node("ResultPanel/Content/Actions/ReviewButton") as Button).pressed.emit()
	if not _check(scene.get_node("TerminalArena").visible, "review hid terminal evidence") \
		or not _check(not scene.get_node("ResultPanel").visible and not scene.get_node("ResultScrim").visible, "review did not dismiss the result card") \
		or not _check(scene.get_node("ResultPill").visible, "review did not expose result return path"):
		return _cleanup(scene)
	(scene.get_node("ResultPill") as Button).pressed.emit()
	return _cleanup(scene, _check(scene.get_node("ResultPanel").visible and scene.get_node("ResultScrim").visible, "result pill did not restore the result surface"))


static func _resignation_result_presentation() -> bool:
	var harness: Dictionary = await _scene_harness()
	var scene: Control = harness["scene"]
	var client: FakeMatchClient = harness["client"]
	client.accept_snapshot(_resignation_snapshot(false))
	var support := (scene.get_node("ResultPanel/Content/Support") as Label).text
	var result := _check((scene.get_node("ResultPanel/Content/Result") as Label).text == "你已认输", "resignation loss title did not bind") \
		and _check((scene.get_node("ResultPanel/Content/Meta/OutcomeChip/Outcome") as Label).text == "认输", "resignation loss kept a generic loss chip") \
		and _check(support == "对局因你认输而结束。", "resignation loss invented a round result: %s" % support) \
		and _check((scene.get_node("SafeContent/Layout/RoundStage/Content/RoundMessage/StateLabel") as Label).text == "你已认输", "resignation arena retained a round-win message") \
		and _check((scene.get_node("SafeContent/Layout/RoundStage/Content/RoundMessage/StateSupportLabel") as Label).text == "对局因你认输而结束", "resignation arena retained final-score copy") \
		and _check(not scene.get_node("ResultPanel/Content/Summary").visible, "resignation loss exposed a fabricated round summary") \
		and _check(not scene.get_node("TerminalArena").visible, "resignation loss exposed stale reveal evidence") \
		and _check(not (scene.get_node("ResultPanel/Content/Actions/ReviewButton") as Button).visible, "resignation loss offered unavailable reveal review")
	return _cleanup(scene, result)


static func _single_round_loss_presentation() -> bool:
	var harness: Dictionary = await _scene_harness()
	var scene: Control = harness["scene"]
	var client: FakeMatchClient = harness["client"]
	var snapshot := _terminal_snapshot(false)
	snapshot["payload"]["format"] = "single_round"
	snapshot["payload"]["round"] = 1
	snapshot["payload"]["me"]["score"] = 0
	snapshot["payload"]["opponent"]["score"] = 1
	snapshot["payload"]["lastReveal"] = _reveal(1, "scissors", "rock", OPPONENT, false, 0, 1, OPPONENT)
	client.accept_snapshot(snapshot)
	var result := _check((scene.get_node("ResultPanel/Content/Result") as Label).text == "对手赢得了这一局", "single-round loss claimed a two-point finish") \
		and _check((scene.get_node("ResultPanel/Content/Summary/Item1/Content/Value") as Label).text == "0 : 1", "single-round score summary did not bind")
	return _cleanup(scene, result)


static func _terminal_result_without_reveal() -> bool:
	var harness: Dictionary = await _scene_harness()
	var scene: Control = harness["scene"]
	var client: FakeMatchClient = harness["client"]
	var snapshot := _terminal_snapshot(false)
	snapshot["payload"]["lastReveal"] = null
	client.accept_snapshot(snapshot)
	var result := _check((scene.get_node("ResultPanel/Content/Support") as Label).text == "最终比分已确认。", "missing reveal kept a fabricated comparison") \
		and _check(not scene.get_node("ResultPanel/Content/Summary/Item3").visible, "missing reveal exposed an unknown final choice") \
		and _check(not (scene.get_node("ResultPanel/Content/Actions/ReviewButton") as Button).visible, "missing reveal offered unavailable review")
	return _cleanup(scene, result)


static func _lock_event_does_not_replay_stale_reveal() -> bool:
	var harness: Dictionary = await _scene_harness()
	var scene: Control = harness["scene"]
	var client: FakeMatchClient = harness["client"]
	var stale_reveal := _reveal(1, "rock", "scissors", ME, false, 1, 0, null)
	client.accept_snapshot(_snapshot_with_reveal(1, 2, stale_reveal))
	client.accept_event(_event(2, "rps.choice.locked", {
		"round": 2, "userId": OPPONENT, "locked": true,
	}))
	var result := _check(not scene.get_node("RevealPanel").visible, "choice lock replayed the previous round reveal") \
		and _check(not scene._is_revealing(), "choice lock started a stale reveal timer")
	return _cleanup(scene, result)


static func _snapshot_cancels_reveal_playback() -> bool:
	var harness: Dictionary = await _scene_harness()
	var scene: Control = harness["scene"]
	var client: FakeMatchClient = harness["client"]
	client.accept_snapshot(_snapshot(1, "best_of_three", 1, {
		"userId": ME, "score": 0, "locked": true, "choice": "paper",
	}, {
		"userId": OPPONENT, "score": 0, "locked": true,
	}))
	client.accept_event(_event(2, "rps.round.revealed", _reveal(1, "paper", "rock", ME, false, 1, 0, null)))
	if not _check(scene.get_node("RevealPanel").visible and scene._is_revealing(), "reveal fixture did not start playback"):
		return _cleanup(scene)
	client.accept_snapshot(_snapshot(3, "best_of_three", 2, {
		"userId": ME, "score": 1, "locked": false,
	}, {
		"userId": OPPONENT, "score": 0, "locked": false,
	}))
	var result := _check(not scene.get_node("RevealPanel").visible, "authoritative snapshot retained a stale reveal panel") \
		and _check(not scene._is_revealing(), "authoritative snapshot retained a stale reveal timer") \
		and _check(not (scene.get_node("SafeContent/Layout/MySection/ChoicePanel/Choices/RockButton") as Button).disabled, "stale reveal kept current-round choices disabled")
	return _cleanup(scene, result)


static func _reconnect_keeps_confirmed_match() -> bool:
	var harness: Dictionary = await _scene_harness()
	var scene: Control = harness["scene"]
	var client: FakeMatchClient = harness["client"]
	var quit_calls: Array[int] = harness["quit_calls"]
	var banner := scene.get_node("ConnectionBanner") as Control
	if not _check(scene.get_node("LoadingOverlay").visible, "initial connection did not show the blocking loader") \
		or not _check((scene.get_node("LoadingOverlay/Content/Message") as Label).text == "正在同步对局…", "initial loader copy changed") \
		or not _check(not banner.visible, "initial connection duplicated the blocking loader with a compact banner") \
		or not _check(scene.get_node("SafeContent/Layout/OpponentSection/StatusLine").visible, "initial loader unexpectedly removed the opponent status row") \
		or not _check((scene.get_node("SafeContent/Layout/TopNavigation/TitleGroup/SubtitleLabel") as Label).text == "准备对局", "initial format retained loading copy") \
		or not _check((scene.get_node("SafeContent/Layout/RoundStage/Content/RoundMessage/StateLabel") as Label).text == "准备开始", "initial game state duplicated network status") \
		or not _check(banner.offset_left == GameboxTokens.SPACING["page"] * 2, "connection banner must align with the safe page inset") \
		or not _check(banner.offset_right == -GameboxTokens.SPACING["page"] * 2, "connection banner right edge must align with the safe page inset"):
		return _cleanup(scene)
	client.set_connection("failed")
	if not _check(not scene.get_node("LoadingOverlay").visible, "initial failure kept a dead blocking loader") \
		or not _check(banner.theme_type_variation == &"GameboxConnectionBannerError", "initial failure did not use compact error semantics"):
		return _cleanup(scene)
	client.set_connection("connecting")
	client.accept_snapshot(_snapshot(0, "single_round", 1, {
		"userId": ME, "score": 0, "locked": false,
	}, {
		"userId": OPPONENT, "score": 0, "locked": false,
	}))
	var rock := scene.get_node("SafeContent/Layout/MySection/ChoicePanel/Choices/RockButton") as Button
	if not _check(not scene.get_node("LoadingOverlay").visible, "confirmed match left the blocking loader visible") \
		or not _check(scene.get_node("SafeContent/Layout/OpponentSection/StatusLine").visible, "ready state did not restore the opponent status row") \
		or not _check(not rock.disabled, "confirmed match did not enable choices"):
		return _cleanup(scene)
	client.set_connection("reconnecting")
	var colors: Dictionary = GameboxTokens.DARK if GameboxTheme.system_prefers_dark() else GameboxTokens.LIGHT
	if not _check(not scene.get_node("LoadingOverlay").visible, "reconnect covered the confirmed match with the blocking loader") \
		or not _check(scene.get_node("ConnectionBanner").visible, "reconnect did not show the compact banner") \
		or not _check(not scene.get_node("SafeContent/Layout/OpponentSection/StatusLine").visible, "reconnect banner overlapped the opponent status row") \
		or not _check(_connection_message(scene) == "重连中…", "reconnect shared copy changed") \
		or not _check((scene.get_node("SafeContent/Layout/RoundStage/Content/RoundMessage/StateLabel") as Label).text == "选择你的手势", "reconnect replaced the last confirmed match state") \
		or not _check(((scene.get_node("SafeContent/Layout/OpponentSection/StatusLine/StatusChip") as PanelContainer).get_theme_stylebox("panel") as StyleBoxFlat).bg_color == colors["surface_container_high"], "reconnect left the opponent choice emphasis active") \
		or not _check(((scene.get_node("SafeContent/Layout/MySection/StatusLine/StatusChip") as PanelContainer).get_theme_stylebox("panel") as StyleBoxFlat).bg_color == colors["surface_container_high"], "reconnect left the local choice emphasis active") \
		or not _check(rock.disabled, "reconnect left a server-authoritative choice enabled"):
		return _cleanup(scene)
	client.set_connection("connected")
	if not _check(not scene.get_node("LoadingOverlay").visible, "snapshot sync covered the confirmed match with the blocking loader") \
		or not _check(_connection_message(scene) == "同步中…", "snapshot sync shared copy changed") \
		or not _check(rock.disabled, "snapshot sync enabled choices before authority returned"):
		return _cleanup(scene)
	client.accept_snapshot(_snapshot(0, "single_round", 1, {
		"userId": ME, "score": 0, "locked": false,
	}, {
		"userId": OPPONENT, "score": 0, "locked": false,
	}))
	if not _check(not scene.get_node("ConnectionBanner").visible, "successful recovery did not hide immediately") \
		or not _check(not rock.disabled, "authoritative recovery snapshot did not restore choices"):
		return _cleanup(scene)
	client.set_connection("failed")
	var result := _check(_connection_message(scene) == "连接失败", "failed shared copy changed") \
		and _check((scene.get_node("ConnectionBanner/Content/ReturnButton") as Button).visible, "failed connection did not offer return") \
		and _check((scene.get_node("SafeContent/Layout/MySection/StatusLine/StatusChip/Content/Label") as Label).text == "等待", "failed connection duplicated status in the local chip") \
		and _check((scene.get_node("SafeContent/Layout/OpponentSection/StatusLine/StatusChip/Content/Label") as Label).text == "等待出拳", "failed connection duplicated status in the opponent chip") \
		and _check(rock.disabled, "failed connection left choices enabled")
	(scene.get_node("ConnectionBanner/Content/ReturnButton") as Button).pressed.emit()
	result = result and _check(quit_calls.size() == 1, "RPS connection return did not return exactly once")
	return _cleanup(scene, result)


static func _overflow_menu_requires_explicit_resign() -> bool:
	var harness: Dictionary = await _scene_harness()
	var scene: Control = harness["scene"]
	var client: FakeMatchClient = harness["client"]
	client.set_connection("connected")
	client.accept_snapshot(_snapshot(1, "single_round", 1, {
		"userId": ME, "score": 0, "locked": false,
	}, {
		"userId": OPPONENT, "score": 0, "locked": false,
	}))
	var items := scene.get_node("SafeContent/Layout/TopNavigation/MenuLayer/MenuRoot/MenuPanel/Items") as VBoxContainer
	if not _check(items.get_child_count() == 1 and (items.get_child(0) as Button).text == "认输并结束对局", "RPS overflow menu did not state the resign consequence"):
		return _cleanup(scene)
	(scene.get_node("SafeContent/Layout/TopNavigation/ActionButton") as Button).pressed.emit()
	if not _check(scene.get_node("SafeContent/Layout/TopNavigation/MenuLayer/MenuRoot").visible, "RPS overflow action did not open the menu") \
		or not _check(not scene.get_node("ResignDialog").visible, "RPS overflow action opened resign confirmation directly"):
		return _cleanup(scene)
	(items.get_child(0) as Button).pressed.emit()
	var result := _check(scene.get_node("ResignDialog").visible, "RPS resign menu item did not open confirmation") \
		and _check(client.resign_requests == 0, "RPS overflow menu submitted resignation before confirmation")
	return _cleanup(scene, result)


static func _scene_harness() -> Dictionary:
	var tree := Engine.get_main_loop() as SceneTree
	var fake := FakeMatchClient.new()
	var scene := RpsScene.instantiate()
	scene.configure_launch({
		"game_id": "rps", "match_id": MATCH_ID, "launch_ticket": "opaque-test-ticket",
		"ws_url": "ws://127.0.0.1:8080/v1/ws",
	})
	scene.set_match_client_factory(func() -> Variant: return fake)
	var quit_calls: Array[int] = []
	scene.set_quit_callback(func() -> void: quit_calls.append(1))
	tree.root.add_child(scene)
	await tree.process_frame
	return {"scene": scene, "client": fake, "quit_calls": quit_calls}


static func _connection_message(scene: Control) -> String:
	return (scene.get_node("ConnectionBanner/Content/Message") as Label).text


static func _cleanup(scene: Control, result: bool = false) -> bool:
	if is_instance_valid(scene):
		scene.free()
	return result


static func _snapshot(revision: int, format: String, round_number: int, me: Dictionary, opponent: Dictionary) -> Dictionary:
	return {
		"protocolVersion": 1, "gameId": "rps", "matchId": MATCH_ID,
		"revision": revision, "type": "platform.snapshot",
		"payload": {
			"status": "active", "format": format, "round": round_number,
			"me": me, "opponent": opponent, "lastReveal": null,
			"winnerUserId": null, "result": null,
		},
	}


static func _terminal_snapshot(local_won: bool) -> Dictionary:
	var my_choice := "paper" if local_won else "scissors"
	var opponent_choice := "rock"
	var my_score := 2 if local_won else 1
	var opponent_score := 1 if local_won else 2
	var winner := ME if local_won else OPPONENT
	return {
		"protocolVersion": 1, "gameId": "rps", "matchId": MATCH_ID,
		"revision": 4, "type": "platform.snapshot",
		"payload": {
			"status": "finished", "format": "best_of_three", "round": 3,
			"me": {"userId": ME, "score": my_score, "locked": false},
			"opponent": {"userId": OPPONENT, "score": opponent_score, "locked": false},
			"lastReveal": _reveal(3, my_choice, opponent_choice, winner, false, my_score, opponent_score, winner),
			"winnerUserId": winner, "result": "rounds",
		},
	}


static func _resignation_snapshot(local_won: bool) -> Dictionary:
	var winner := ME if local_won else OPPONENT
	return {
		"protocolVersion": 1, "gameId": "rps", "matchId": MATCH_ID,
		"revision": 3, "type": "platform.snapshot",
		"payload": {
			"status": "finished", "format": "best_of_three", "round": 2,
			"me": {"userId": ME, "score": 1, "locked": false},
			"opponent": {"userId": OPPONENT, "score": 0, "locked": false},
			"lastReveal": null, "winnerUserId": winner, "result": "resignation",
		},
	}


static func _snapshot_with_reveal(revision: int, round_number: int, reveal: Dictionary) -> Dictionary:
	var snapshot := _snapshot(revision, "best_of_three", round_number, {
		"userId": ME, "score": 1, "locked": false,
	}, {
		"userId": OPPONENT, "score": 0, "locked": false,
	})
	snapshot["payload"]["lastReveal"] = reveal
	return snapshot


static func _event(revision: int, type: String, payload: Dictionary, action_id: String = "") -> Dictionary:
	var envelope := {
		"protocolVersion": 1, "gameId": "rps", "matchId": MATCH_ID,
		"revision": revision, "type": type, "payload": payload,
	}
	if not action_id.is_empty():
		envelope["actionId"] = action_id
	return envelope


static func _reveal(
	round_number: int,
	my_choice: String,
	opponent_choice: String,
	round_winner: Variant,
	draw: bool,
	my_score: int,
	opponent_score: int,
	match_winner: Variant
) -> Dictionary:
	return {
		"round": round_number,
		"choices": {ME: my_choice, OPPONENT: opponent_choice},
		"roundWinnerUserId": round_winner,
		"draw": draw,
		"scores": _nonzero_scores(my_score, opponent_score),
		"matchWinnerUserId": match_winner,
		"result": "rounds" if match_winner != null else null,
	}


static func _nonzero_scores(my_score: int, opponent_score: int) -> Dictionary:
	var scores := {}
	if my_score > 0:
		scores[ME] = my_score
	if opponent_score > 0:
		scores[OPPONENT] = opponent_score
	return scores


class FakeMatchClient:
	extends RefCounted

	signal connection_state_changed(next_state: String)
	signal snapshot_sync_started
	signal snapshot_received(envelope: Dictionary)
	signal event_received(envelope: Dictionary)
	signal player_presence_changed(user_id: String, online: bool)
	signal match_error(code: String)
	signal return_to_lobby_requested(code: String)

	var connection_state := "closed"
	var local_user_id := ME
	var state: Variant
	var resign_requests := 0

	func start(_ws_url: String, _match_id: String, _ticket: String, game_state: Variant, _game_id: String) -> bool:
		state = game_state
		connection_state = "connecting"
		return true

	func poll() -> void:
		pass

	func request_choice(_choice: String) -> String:
		return ""

	func request_resign() -> String:
		resign_requests += 1
		return ACTION_ID

	func dispose() -> void:
		pass

	func set_connection(next_state: String) -> void:
		connection_state = next_state
		connection_state_changed.emit(next_state)

	func accept_snapshot(envelope: Dictionary) -> void:
		var applied: Dictionary = state.apply_snapshot(envelope)
		if not applied.get("ok", false):
			push_error("fake RPS snapshot invalid")
			return
		connection_state = "connected"
		connection_state_changed.emit(connection_state)
		snapshot_received.emit(envelope)

	func accept_event(envelope: Dictionary) -> void:
		var applied: Dictionary = state.apply_event(envelope)
		if not applied.get("ok", false):
			push_error("fake RPS event invalid")
			return
		event_received.emit(envelope)


static func _check(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition
