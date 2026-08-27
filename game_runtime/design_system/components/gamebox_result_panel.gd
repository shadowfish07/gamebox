extends PanelContainer

signal review_requested
signal return_requested

const GameboxTokens = preload("res://design_system/generated/gamebox_tokens.gd")

var _entrance_tween: Tween


func _ready() -> void:
	visible = false


func present(status: String, local_won: bool) -> void:
	var outcome := ""
	match status:
		"finished":
			outcome = "won" if local_won else "lost"
		"won", "lost", "draw", "cancelled", "abandoned":
			outcome = status
		_:
			present_details({})
			return
	var defaults := _default_content(outcome)
	defaults["review_available"] = outcome in ["won", "lost", "draw"]
	present_details(defaults)


func present_details(details: Dictionary) -> void:
	var title := str(details.get("title", ""))
	if title.is_empty():
		visible = false
		return
	var outcome := str(details.get("outcome", "lost"))
	var positive := outcome == "won"
	var loss := outcome == "lost"
	theme_type_variation = &"GameboxResultPanelPositive" if positive else &"GameboxResultPanelLoss" if loss else &"GameboxResultPanelNeutral"
	$Content/Meta/OutcomeChip.theme_type_variation = &"GameboxResultChipPositive" if positive else &"GameboxResultChipLoss" if loss else &"GameboxResultChipNeutral"
	$Content/Meta/OutcomeChip/Outcome.theme_type_variation = &"GameboxResultChipLabelPositive" if positive else &"GameboxResultChipLabelLoss" if loss else &"GameboxResultChipLabelNeutral"
	$Content/Meta/OutcomeChip/Outcome.text = str(details.get("outcome_label", _outcome_label(outcome)))
	$Content/Meta/Confirmed.text = str(details.get("confirmed_text", "✓ 结果已确认"))
	$Content/Result.text = title
	$Content/Support.text = str(details.get("support", ""))
	_bind_summary(details.get("summary", []))
	$Content/Actions/ReviewButton.visible = bool(details.get("review_available", false))
	show_animated()


func show_animated() -> void:
	var was_hidden := not visible
	visible = true
	if not was_hidden or not is_inside_tree():
		return
	if _entrance_tween != null and _entrance_tween.is_valid():
		_entrance_tween.kill()
	modulate.a = 0.0
	_entrance_tween = create_tween()
	_entrance_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_entrance_tween.tween_property(self, "modulate:a", 1.0, float(GameboxTokens.MOTION["standard"]) / 1000.0)


func _bind_summary(summary: Variant) -> void:
	var values: Array = summary if summary is Array else []
	var items := [$Content/Summary/Item1, $Content/Summary/Item2, $Content/Summary/Item3]
	for index in items.size():
		var item: PanelContainer = items[index]
		var entry: Variant = values[index] if index < values.size() else null
		item.visible = entry is Dictionary
		if entry is Dictionary:
			item.get_node("Content/Value").text = str(entry.get("value", ""))
			item.get_node("Content/Label").text = str(entry.get("label", ""))
	$Content/Summary.visible = not values.is_empty()


static func _default_content(outcome: String) -> Dictionary:
	match outcome:
		"won":
			return {"outcome": outcome, "title": "漂亮的一局", "support": "终局已经保留。"}
		"lost":
			return {"outcome": outcome, "title": "这局差一点", "support": "终局已经保留。"}
		"draw":
			return {"outcome": outcome, "title": "势均力敌", "support": "双方未分胜负。"}
		"cancelled":
			return {"outcome": outcome, "title": "对局已取消", "support": "本局不会计入结果。", "confirmed_text": "对局已结束"}
		"abandoned":
			return {"outcome": outcome, "title": "对局已作废", "support": "本局不会计入结果。", "confirmed_text": "对局已结束"}
	return {}


static func _outcome_label(outcome: String) -> String:
	return {
		"won": "胜利",
		"lost": "惜败",
		"draw": "和棋",
		"cancelled": "已取消",
		"abandoned": "已作废",
	}.get(outcome, "结果")


func _on_review_button_pressed() -> void:
	review_requested.emit()


func _on_return_button_pressed() -> void:
	return_requested.emit()
