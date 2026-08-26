extends RefCounted

const RpsState = preload("res://games/rps/rps_state.gd")
const Protocol = preload("res://core/protocol.gd")
const RpsScene = preload("res://games/rps/rps_scene.tscn")
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
		and _check(rock.custom_minimum_size.x >= 96 and rock.custom_minimum_size.y >= 256, "choice targets must be touch safe") \
		and _check(rock.flat and paper.flat and scissors.flat, "choice backgrounds must stay transparent") \
		and _check(scene.has_node("SafeContent/Layout/OpponentSection/OpponentVisual/Unknown"), "sealed opponent placeholder must exist") \
		and _check(scene.has_node("SafeContent/Layout/OpponentSection/OpponentVisual/Locked"), "sealed opponent lock state must exist") \
		and _check(scene.has_node("SafeContent/Layout/OpponentSection/OpponentVisual/UnknownSurface"), "sealed opponent placeholder needs a dedicated surface") \
		and _check(scene.has_node("SafeContent/Layout/OpponentSection/OpponentVisual/LockedSurface"), "locked opponent needs a dedicated surface") \
		and _check(scene.has_node("SafeContent/Layout/RoundStage/Content/StateSupportLabel"), "round stage must keep primary and supporting copy together") \
		and _check(scene.get_node("SafeContent/Layout/RoundStage").custom_minimum_size.y >= 400, "round stage must retain the portrait information band") \
		and _check(scene.has_node("SafeContent/Layout/MySection/SelectedPanel"), "selected gesture slot must exist") \
		and _check(scene.has_node("BackButton") == false, "navigation controls live in the safe constrained layout") \
		and _check(scene.has_node("SafeContent/Layout/TopNavigation/BackButton"), "visible back control must remain available") \
		and _check(scene.has_node("SafeContent/Layout/TopNavigation/MoreButton"), "resign menu control must remain available") \
		and _check(scene.has_node("RevealPanel"), "previous-round result panel must exist") \
		and _check(scene.get_node("RevealPanel/Content/Choices/MyChoice/Icon").texture != null, "my reveal image must load") \
		and _check(scene.get_node("RevealPanel/Content/Choices/OpponentChoice/Icon").texture != null, "opponent reveal image must load") \
		and _check(scene.get_node("ResignButton").text == "认输并结束对局", "destructive action must name its consequence")
	var image_nodes_present := rock.has_node("Content/Icon") \
		and scissors.has_node("Content/Icon") and paper.has_node("Content/Icon")
	passed = _check(image_nodes_present, "each choice must render an image") and passed
	if image_nodes_present:
		passed = _check(rock.get_node("Content/Icon").texture != null, "rock image must load") \
			and _check(scissors.get_node("Content/Icon").texture != null, "scissors image must load") \
			and _check(paper.get_node("Content/Icon").texture != null, "paper image must load") \
			and passed
	scene.free()
	return passed


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


static func _check(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
	return condition
