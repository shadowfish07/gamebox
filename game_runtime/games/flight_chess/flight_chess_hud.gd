extends RefCounted

const Tokens = preload("res://design_system/generated/gamebox_tokens.gd")
const Board = preload("res://games/flight_chess/flight_chess_board.gd")
const Stats = preload("res://games/flight_chess/flight_chess_stats.gd")

static func setup(scene: Control) -> void:
	var left := scene.get_node("LeftRail/Content")
	for node_name in ["MenuButton", "RulesButton", "ThemeButton"]:
		var button := Button.new()
		button.name = node_name
		left.add_child(button)
	left.get_node("MenuButton").text = "⋯"
	left.get_node("RulesButton").text = "本局规则"
	left.get_node("ThemeButton").text = "切换明暗"
	left.get_node("RulesButton").hide()
	left.get_node("ThemeButton").hide()
	for card_name in ["OpponentCard", "LocalCard"]:
		var content := left.get_node(card_name + "/Content")
		var stats := Stats.new()
		stats.name = "Stats"
		content.add_child(stats)
		var badge := Label.new()
		badge.name = "TurnBadge"
		badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		var overlay := Control.new()
		overlay.name = "BadgeOverlay"
		overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		left.get_node(card_name).add_child(overlay)
		overlay.add_child(badge)
		var stripe := ColorRect.new()
		stripe.name = "Stripe"
		stripe.mouse_filter = Control.MOUSE_FILTER_IGNORE
		overlay.add_child(stripe)
	var versus := Label.new()
	versus.name = "Versus"
	versus.text = "VS"
	versus.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	left.add_child(versus)
	var right := scene.get_node("RightRail/Content")
	for node_name in ["DiceLabel", "SyncLabel"]:
		var label := Label.new()
		label.name = node_name
		right.add_child(label)
	var cancel := Button.new()
	cancel.name = "CancelSelection"
	cancel.text = "取消选择"
	cancel.visible = false
	right.add_child(cancel)
	var board_status := Label.new()
	board_status.name = "BoardStatus"
	board_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	scene.add_child(board_status)
	# Godot Control hit order follows the tree, independently of z_index.
	for name in ["RulesButton", "ThemeButton", "ResignButton", "MenuButton"]:
		left.move_child(left.get_node(name), -1)

static func box(fill: Color, border: Color, radius: float, width: float = 1.0) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(roundi(width))
	style.set_corner_radius_all(roundi(radius))
	return style

static func place(node: Control, rect: Rect2) -> void:
	node.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	node.custom_minimum_size = Vector2.ZERO
	node.position = rect.position
	node.size = rect.size

static func layout(scene: Control, regions: Dictionary, dark: bool) -> void:
	var colors: Dictionary = Tokens.DARK if dark else Tokens.LIGHT
	var unit: float = minf(regions.board.size.y / 344.0,minf(regions.left.size.x / 180.0, regions.right.size.x / 196.0))
	scene._hud_unit = unit
	var height: float = regions.board.size.y / unit
	var left := scene.get_node("LeftRail/Content")
	var right := scene.get_node("RightRail/Content")
	var lw: float = regions.left.size.x / unit
	var rw: float = regions.right.size.x / unit
	for rail in [scene.get_node("LeftRail"), scene.get_node("RightRail")]:
		rail.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	scene.get_node("RightRail").add_theme_stylebox_override("panel", box(colors.surface_container_low, colors.outline_variant, 22 * unit, unit))
	for name in ["Eyebrow", "Spacer"]:
		left.get_node(name).hide()
	left.get_node("BackButton").text = "‹"
	for pair in [["BackButton", Rect2(0,0,48,48)], ["Title",Rect2(48,0,lw-96,48)], ["MenuButton",Rect2(lw-48,0,48,48)]]:
		place(left.get_node(pair[0]), Rect2(pair[1].position * unit, pair[1].size * unit))
	for name in ["BackButton", "MenuButton"]:
		left.get_node(name).custom_minimum_size = Vector2(96,96)
	left.get_node("Title").horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	left.get_node("Title").vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	for button in [left.get_node("BackButton"), left.get_node("MenuButton")]:
		button.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
		button.add_theme_stylebox_override("hover", box(colors.surface_container_high, colors.surface_container_low, 24 * unit, 0))
		button.add_theme_color_override("font_color", colors.on_surface)
		button.add_theme_font_size_override("font_size", roundi(Tokens.TYPOGRAPHY.headline_small.font_size*unit))
	left.get_node("Title").add_theme_font_size_override("font_size", roundi(Tokens.TYPOGRAPHY.title_medium.font_size * unit))
	for i in 3:
		var button := left.get_node(["RulesButton", "ThemeButton", "ResignButton"][i])
		place(button, Rect2(Vector2(0,48+i*48)*unit,Vector2(lw,48)*unit))
		button.z_index = 40
		button.add_theme_font_size_override("font_size",roundi(Tokens.TYPOGRAPHY.label_medium.font_size*unit))
		button.add_theme_stylebox_override("normal",box(colors.surface_container_high,colors.outline_variant,8*unit,unit))
		button.add_theme_color_override("font_color",colors.error if i == 2 else colors.on_surface)
	var card_height := 112.0
	for pair in [["OpponentCard", 56], ["LocalCard",56+card_height+24]]:
		var card := left.get_node(pair[0])
		place(card, Rect2(Vector2(0,pair[1]) * unit, Vector2(lw,card_height) * unit))
		var content := card.get_node("Content")
		content.add_theme_constant_override("separation", roundi(4 * unit))
		content.alignment = BoxContainer.ALIGNMENT_BEGIN
		content.get_node("Role").add_theme_font_size_override("font_size", roundi(Tokens.TYPOGRAPHY.label_medium.font_size*unit))
		content.get_node("Name").add_theme_font_override("font",scene.theme.default_font)
		content.get_node("Name").add_theme_color_override("font_color",colors.on_surface_variant)
		content.get_node("Name").add_theme_font_size_override("font_size", roundi(Tokens.TYPOGRAPHY.label_small.font_size*unit))
		content.get_node("Meta").hide()
		content.get_node("Stats").custom_minimum_size = Vector2(132,24) * unit
		card.get_node("BadgeOverlay/TurnBadge").mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.get_node("BadgeOverlay/TurnBadge").set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
		card.get_node("BadgeOverlay/TurnBadge").offset_left = -36 * unit
		card.get_node("BadgeOverlay/TurnBadge").offset_right = -8 * unit
		card.get_node("BadgeOverlay/TurnBadge").offset_top = -8*unit
		card.get_node("BadgeOverlay/TurnBadge").offset_bottom = 14*unit
		card.get_node("BadgeOverlay/TurnBadge").add_theme_font_size_override("font_size", roundi(Tokens.TYPOGRAPHY.label_small.font_size*unit))
	place(left.get_node("Versus"), Rect2(Vector2(0,56+card_height)*unit,Vector2(lw,24)*unit))
	left.get_node("Versus").add_theme_font_size_override("font_size", roundi(Tokens.TYPOGRAPHY.label_medium.font_size*unit))
	for pair in [["StatusLabel",Rect2(12,12,76,26)], ["SyncLabel",Rect2(rw-60,12,48,26)], ["TurnLabel",Rect2(12,46,rw-24,30)], ["HintLabel",Rect2(12,74,rw-24,30)], ["RuleLabel",Rect2(12,108,rw-24,28)], ["DiceCard",Rect2(12,height-150,80,80)], ["DiceLabel",Rect2(100,height-136,rw-112,52)], ["RollButton",Rect2(12,height-60,rw-24,48)], ["CancelSelection",Rect2(12,height-60,rw-24,48)]]:
		place(right.get_node(pair[0]),Rect2(pair[1].position*unit,pair[1].size*unit))
	right.get_node("ActionSpacer").hide()
	right.get_node("RollButton").custom_minimum_size.y = 96
	right.get_node("RollButton").position.y = regions.right.size.y - maxf(96,48*unit) - 12*unit
	for name in ["StatusLabel", "TurnLabel", "HintLabel", "RuleLabel", "DiceLabel"]:
		var label := right.get_node(name) as Label
		label.show()
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		label.add_theme_font_size_override("font_size", roundi(Tokens.TYPOGRAPHY["title_medium" if name == "TurnLabel" else "label_small" if name == "HintLabel" else "label_medium" if name == "DiceLabel" else "label_small"].font_size * unit))
		label.custom_maximum_size.x = (rw-24)*unit
	right.get_node("HintLabel").visible = regions.board.size.y >= 650
	right.get_node("SyncLabel").text = ""
	right.get_node("DiceCard").add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	right.get_node("DiceCard/Content/Dice").custom_minimum_size = Vector2(80,80)*unit
	for name in ["RollButton", "CancelSelection"]:
		right.get_node(name).add_theme_font_size_override("font_size", roundi(Tokens.TYPOGRAPHY.label_large.font_size*unit))
	right.get_node("CancelSelection").add_theme_stylebox_override("normal",StyleBoxEmpty.new())
	right.get_node("CancelSelection").add_theme_color_override("font_color",colors.on_surface)
	var rule_style := box(colors.surface_container_high,colors.surface_container_low,12*unit,0)
	rule_style.content_margin_left = 8*unit
	right.get_node("RuleLabel").add_theme_stylebox_override("normal",rule_style)
	var status := scene.get_node("BoardStatus")
	place(status,Rect2(regions.board.position+Vector2(0,regions.board.size.y-22*unit),Vector2(regions.board.size.x,20*unit)))
	status.add_theme_font_size_override("font_size",roundi(9*unit))
	status.add_theme_color_override("font_color",Board.BOARD_INK)
	place(scene.get_node("ConnectionLabel"),Rect2(regions.board.position+Vector2(8,8)*unit,Vector2(regions.board.size.x-16*unit,48*unit)))
	scene.get_node("ConnectionLabel/Content/Message").add_theme_font_size_override("font_size",roundi(Tokens.TYPOGRAPHY.label_medium.font_size*unit))
	scene.get_node("ConnectionLabel/Content/ReturnButton").custom_minimum_size = Vector2(96,48)*unit
	scene.get_node("ConnectionLabel/Content/ReturnButton").add_theme_font_size_override("font_size",roundi(Tokens.TYPOGRAPHY.label_medium.font_size*unit))
	place(scene.get_node("ErrorLabel"),Rect2(regions.board.position+Vector2(8,288)*unit,Vector2(regions.board.size.x-16*unit,48*unit)))
	scene.get_node("ErrorLabel/Content/Message").add_theme_font_size_override("font_size",roundi(Tokens.TYPOGRAPHY.label_medium.font_size*unit))

	layout_result(scene,dark)
	var dialog := scene.get_node("ResignDialog/Dialog")
	place(dialog,Rect2(Vector2.ZERO,Vector2(400*unit,0)))
	var dialog_style := box(colors.surface_container_high,colors.outline_variant,24*unit,unit)
	for edge in ["left","right","top","bottom"]:
		dialog_style.set("content_margin_"+edge,24*unit)
	dialog.add_theme_stylebox_override("panel",dialog_style)
	var dialog_content := dialog.get_node("Content")
	dialog_content.add_theme_constant_override("separation",roundi(12*unit))
	for name in ["Title","Message"]:
		dialog_content.get_node(name).horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	var actions := dialog_content.get_node("Actions")
	actions.add_theme_constant_override("separation",roundi(12*unit))
	actions.custom_minimum_size.y = 60*unit
	dialog_content.get_node("Title").add_theme_font_size_override("font_size",roundi(Tokens.TYPOGRAPHY.title_large.font_size*unit))
	dialog_content.get_node("Message").add_theme_font_size_override("font_size",roundi(Tokens.TYPOGRAPHY.body_small.font_size*unit))
	dialog_content.get_node("Actions/ConfirmButton").text = "认输并结束本局"
	for name in ["CancelButton","ConfirmButton"]:
		dialog_content.get_node("Actions/"+name).custom_minimum_size = Vector2(160,48)*unit
		dialog_content.get_node("Actions/"+name).size_flags_horizontal = Control.SIZE_EXPAND_FILL
		dialog_content.get_node("Actions/"+name).size_flags_vertical = Control.SIZE_SHRINK_END
		dialog_content.get_node("Actions/"+name).add_theme_font_size_override("font_size",roundi(Tokens.TYPOGRAPHY.body_small.font_size*unit))


static func present_card(scene: Control, node_name: String, color: String, active: bool, presence: String, pieces: Array) -> void:
	var card := scene.get_node("LeftRail/Content/" + node_name)
	var colors: Dictionary = Tokens.DARK if scene._preview_dark == true else Tokens.LIGHT
	var unit: float = scene._hud_unit
	var fill: Color = colors.surface_container_low.lerp(Board.PLAYER_COLORS[color],0.14) if active else colors.surface_container_low
	var style := box(fill,Board.PLAYER_COLORS[color] if active else colors.outline_variant,16*unit,unit)
	var stripe := card.get_node("BadgeOverlay/Stripe")
	stripe.hide()
	place(stripe,Rect2(Vector2(-9,-8)*unit,Vector2(3,card.size.y/unit-32)*unit))
	style.content_margin_left = 14*unit
	style.content_margin_right = 8*unit
	style.content_margin_top = 20*unit
	style.content_margin_bottom = 16*unit
	card.add_theme_stylebox_override("panel",style)
	card.get_node("Content/Name").text = "● " + presence
	card.get_node("Content/Stats").present(pieces)
	card.get_node("BadgeOverlay/TurnBadge").text = "当前" if active else "等待"
	card.get_node("BadgeOverlay/TurnBadge").add_theme_stylebox_override("normal",box(Board.PLAYER_COLORS[color] if active else colors.surface_container_high,colors.surface_container_low,12*unit,0))
	card.get_node("BadgeOverlay/TurnBadge").add_theme_color_override("font_color",Board.BOARD_INK if active else colors.on_surface_variant)


static func layout_result(scene: Control, dark: bool) -> void:
	var colors: Dictionary = Tokens.DARK if dark else Tokens.LIGHT
	var unit: float = scene._hud_unit
	var panel := scene.get_node("ResultPanel")
	var dimensions := Vector2(544,220)*unit
	place(panel,Rect2((scene.size-dimensions)/2,dimensions))
	var style := box(colors.surface_container_lowest,colors.outline_variant,28*unit,unit)
	style.border_width_left = roundi(6*unit)
	style.content_margin_left = 22*unit
	style.content_margin_right = 22*unit
	style.content_margin_top = 22*unit
	style.content_margin_bottom = 22*unit
	panel.add_theme_stylebox_override("panel",style)
	var content := panel.get_node("Content")
	content.add_theme_constant_override("separation",roundi(Tokens.TYPOGRAPHY.label_medium.font_size*unit))
	content.get_node("Result").add_theme_font_size_override("font_size",roundi(Tokens.TYPOGRAPHY.headline_large.font_size*unit))
	content.get_node("Support").add_theme_font_size_override("font_size",roundi(Tokens.TYPOGRAPHY.body_medium.font_size*unit))
	content.get_node("Support").size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.get_node("Meta/Confirmed").add_theme_font_size_override("font_size",roundi(Tokens.TYPOGRAPHY.label_small.font_size*unit))
	content.get_node("Meta/OutcomeChip/Outcome").add_theme_font_size_override("font_size",roundi(Tokens.TYPOGRAPHY.label_medium.font_size*unit))
	content.get_node("Actions").alignment = BoxContainer.ALIGNMENT_END
	content.get_node("Actions/ReturnButton").size_flags_horizontal = Control.SIZE_SHRINK_END
	content.get_node("Actions/ReturnButton").custom_minimum_size = Vector2(136,48)*unit
	content.get_node("Actions/ReturnButton").add_theme_font_size_override("font_size",roundi(Tokens.TYPOGRAPHY.label_large.font_size*unit))
