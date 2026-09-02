class_name GameboxTheme
extends RefCounted

const GameboxTokens = preload("res://design_system/generated/gamebox_tokens.gd")
const LOGICAL_SCALE := 2.0


static func create(dark: bool) -> Theme:
	var colors: Dictionary = GameboxTokens.DARK if dark else GameboxTokens.LIGHT
	var theme := Theme.new()
	var body_size := _scaled(GameboxTokens.TYPOGRAPHY["body_medium"]["font_size"])
	var label_size := _scaled(GameboxTokens.TYPOGRAPHY["label_large"]["font_size"])
	var title_size := _scaled(GameboxTokens.TYPOGRAPHY["headline_small"]["font_size"])
	var minimum_touch_target := _scaled(GameboxTokens.COMPONENT["minimum_touch_target"])
	var card_radius: float = GameboxTokens.SHAPE["card"]
	var dialog_radius: float = GameboxTokens.SHAPE["dialog"]
	var result_bold_font := SystemFont.new()
	result_bold_font.font_weight = 700
	var result_semibold_font := SystemFont.new()
	result_semibold_font.font_weight = 600
	var loss_accent: Color = GameboxTokens.GAME["result_loss_dark"] if dark else GameboxTokens.GAME["result_loss_light"]
	var loss_container: Color = GameboxTokens.GAME["result_loss_container_dark"] if dark else GameboxTokens.GAME["result_loss_container_light"]

	theme.set_color("font_color", "Label", colors["on_surface"])
	theme.set_color("font_shadow_color", "Label", colors["shadow"])
	theme.set_font_size("font_size", "Label", body_size)

	theme.set_color("font_color", "Button", colors["on_primary"])
	theme.set_color("font_hover_color", "Button", colors["on_primary_container"])
	theme.set_color("font_pressed_color", "Button", colors["on_secondary_container"])
	theme.set_color("font_disabled_color", "Button", colors["on_surface_variant"])
	theme.set_font_size("font_size", "Button", label_size)
	theme.set_stylebox("normal", "Button", _style_box(colors["primary"], GameboxTokens.SHAPE["full"]))
	theme.set_stylebox("hover", "Button", _style_box(colors["primary_container"], GameboxTokens.SHAPE["full"]))
	theme.set_stylebox("pressed", "Button", _style_box(colors["secondary_container"], GameboxTokens.SHAPE["full"]))
	theme.set_stylebox("disabled", "Button", _style_box(colors["surface_dim"], GameboxTokens.SHAPE["full"]))

	theme.set_stylebox("panel", "PanelContainer", _style_box(colors["surface_container"], card_radius, colors["outline_variant"]))
	theme.set_stylebox("background", "ProgressBar", _style_box(colors["surface_container_highest"], GameboxTokens.SHAPE["full"]))
	theme.set_stylebox("fill", "ProgressBar", _style_box(colors["primary"], GameboxTokens.SHAPE["full"]))

	theme.set_color("title_color", "Window", colors["on_surface"])
	theme.set_font_size("title_font_size", "Window", title_size)
	theme.set_stylebox("panel", "Window", _style_box(colors["surface_container_high"], dialog_radius, colors["outline_variant"]))
	theme.set_constant("buttons_min_width", "AcceptDialog", minimum_touch_target)
	theme.set_constant("buttons_min_height", "AcceptDialog", minimum_touch_target)
	theme.set_constant("buttons_separation", "AcceptDialog", _scaled(GameboxTokens.SPACING["layout"]))

	theme.set_type_variation("GameboxOnSecondaryContainer", "Label")
	theme.set_type_variation("GameboxOnInverseSurface", "Label")
	theme.set_type_variation("GameboxOnErrorContainer", "Label")
	theme.set_color("font_color", "GameboxOnSecondaryContainer", colors["on_secondary_container"])
	theme.set_color("font_color", "GameboxOnInverseSurface", colors["on_inverse_surface"])
	theme.set_color("font_color", "GameboxOnErrorContainer", colors["on_error_container"])
	theme.set_type_variation("GameboxConnectionBanner", "PanelContainer")
	theme.set_type_variation("GameboxPortraitTopBar", "HBoxContainer")
	theme.set_type_variation("GameboxPortraitTitleGroup", "VBoxContainer")
	theme.set_type_variation("GameboxPortraitTitle", "Label")
	theme.set_type_variation("GameboxPortraitSubtitle", "Label")
	theme.set_type_variation("GameboxPortraitBackButton", "Button")
	theme.set_type_variation("GameboxPortraitActionButton", "Button")
	theme.set_type_variation("GameboxOverflowMenu", "PanelContainer")
	theme.set_type_variation("GameboxOverflowMenuItems", "VBoxContainer")
	theme.set_type_variation("GameboxOverflowMenuItem", "Button")
	theme.set_type_variation("GameboxOverflowMenuDangerItem", "Button")
	theme.set_type_variation("GameboxOverflowMenuDismissButton", "Button")
	theme.set_type_variation("GameboxConnectionBannerError", "PanelContainer")
	theme.set_type_variation("GameboxConnectionBannerContent", "HBoxContainer")
	theme.set_type_variation("GameboxConnectionActionButton", "Button")
	theme.set_type_variation("GameboxSnackbar", "PanelContainer")
	theme.set_type_variation("GameboxSnackbarError", "PanelContainer")
	theme.set_type_variation("GameboxLoadingOverlay", "PanelContainer")
	theme.set_type_variation("GameboxResultPanel", "PanelContainer")
	theme.set_type_variation("GameboxResultPanelPositive", "PanelContainer")
	theme.set_type_variation("GameboxResultPanelLoss", "PanelContainer")
	theme.set_type_variation("GameboxResultPanelNeutral", "PanelContainer")
	theme.set_type_variation("GameboxResultContent", "VBoxContainer")
	theme.set_type_variation("GameboxResultMeta", "HBoxContainer")
	theme.set_type_variation("GameboxResultChipPositive", "PanelContainer")
	theme.set_type_variation("GameboxResultChipLoss", "PanelContainer")
	theme.set_type_variation("GameboxResultChipNeutral", "PanelContainer")
	theme.set_type_variation("GameboxResultChipLabelPositive", "Label")
	theme.set_type_variation("GameboxResultChipLabelLoss", "Label")
	theme.set_type_variation("GameboxResultChipLabelNeutral", "Label")
	theme.set_type_variation("GameboxResultConfirmed", "Label")
	theme.set_type_variation("GameboxResultTitle", "Label")
	theme.set_type_variation("GameboxResultSupport", "Label")
	theme.set_type_variation("GameboxResultSummary", "HBoxContainer")
	theme.set_type_variation("GameboxResultSummaryItem", "PanelContainer")
	theme.set_type_variation("GameboxResultSummaryItemContent", "VBoxContainer")
	theme.set_type_variation("GameboxResultSummaryValue", "Label")
	theme.set_type_variation("GameboxResultSummaryLabel", "Label")
	theme.set_type_variation("GameboxResultActions", "HBoxContainer")
	theme.set_type_variation("GameboxResultReviewButton", "Button")
	theme.set_type_variation("GameboxResultReturnButton", "Button")
	theme.set_type_variation("GameboxResultEvidence", "PanelContainer")
	theme.set_type_variation("GameboxResultEvidenceTitle", "Label")
	theme.set_type_variation("GameboxResultEvidenceSupport", "Label")
	theme.set_type_variation("GameboxResultEvidencePiece", "Label")
	theme.set_type_variation("GameboxTerminalChoice", "VBoxContainer")
	theme.set_type_variation("GameboxTerminalBackdrop", "PanelContainer")
	theme.set_type_variation("GameboxTerminalHandSurface", "PanelContainer")
	theme.set_type_variation("GameboxTerminalChoiceLabel", "Label")
	theme.set_type_variation("GameboxTerminalScore", "Label")
	theme.set_type_variation("GameboxDialogScrim", "PanelContainer")
	theme.set_type_variation("GameboxConfirmationDialog", "PanelContainer")
	theme.set_type_variation("GameboxDialogTitle", "Label")
	theme.set_type_variation("GameboxDialogContent", "VBoxContainer")
	theme.set_type_variation("GameboxDialogActions", "HBoxContainer")
	theme.set_type_variation("GameboxDialogCancelButton", "Button")
	theme.set_type_variation("GameboxDialogConfirmButton", "Button")
	theme.set_type_variation("GameboxSecondaryButton", "Button")
	theme.set_type_variation("GameboxSettingsSheet", "PanelContainer")
	theme.set_type_variation("GameboxMoveConfirmationBar", "PanelContainer")
	theme.set_type_variation("GameboxSettingsContent", "VBoxContainer")
	theme.set_type_variation("GameboxMoveConfirmationContent", "VBoxContainer")
	theme.set_type_variation("GameboxMoveConfirmationActions", "HBoxContainer")
	theme.set_type_variation("GameboxSettingsRow", "Button")
	theme.set_type_variation("GameboxSettingsRowContent", "HBoxContainer")
	theme.set_type_variation("GameboxSettingsLabels", "VBoxContainer")
	theme.set_type_variation("GameboxSettingsTitle", "Label")
	theme.set_type_variation("GameboxSettingsDescription", "Label")
	theme.set_type_variation("GameboxSwitchVisual", "Control")
	theme.set_stylebox("panel", "GameboxConnectionBanner", _connection_banner_style(colors["secondary_container"], card_radius))
	theme.set_constant("separation", "GameboxPortraitTopBar", _scaled(GameboxTokens.SPACING["base"]))
	theme.set_constant("separation", "GameboxPortraitTitleGroup", 0)
	theme.set_color("font_color", "GameboxPortraitTitle", colors["on_surface"])
	theme.set_font_size("font_size", "GameboxPortraitTitle", _scaled(GameboxTokens.TYPOGRAPHY["title_large"]["font_size"]))
	theme.set_color("font_color", "GameboxPortraitSubtitle", colors["on_surface_variant"])
	theme.set_font_size("font_size", "GameboxPortraitSubtitle", body_size)
	for button_type in ["GameboxPortraitBackButton", "GameboxPortraitActionButton"]:
		for state in ["font_color", "font_hover_color", "font_pressed_color"]:
			theme.set_color(state, button_type, colors["on_surface"])
		theme.set_stylebox("normal", button_type, StyleBoxEmpty.new())
		theme.set_stylebox("hover", button_type, _style_box(colors["surface_container_high"], GameboxTokens.SHAPE["full"]))
		theme.set_stylebox("pressed", button_type, _style_box(colors["surface_container_highest"], GameboxTokens.SHAPE["full"]))
		theme.set_stylebox("focus", button_type, StyleBoxEmpty.new())
	theme.set_font_size("font_size", "GameboxPortraitBackButton", _scaled(GameboxTokens.TYPOGRAPHY["headline_medium"]["font_size"]))
	theme.set_font_size("font_size", "GameboxPortraitActionButton", label_size)
	theme.set_stylebox("panel", "GameboxOverflowMenu", _style_box(colors["surface_container_high"], card_radius, colors["outline_variant"]))
	theme.set_constant("separation", "GameboxOverflowMenuItems", 0)
	for menu_item_type in ["GameboxOverflowMenuItem", "GameboxOverflowMenuDangerItem"]:
		theme.set_font_size("font_size", menu_item_type, label_size)
		theme.set_color("font_color", menu_item_type, colors["on_surface"])
		theme.set_color("font_hover_color", menu_item_type, colors["on_surface"])
		theme.set_color("font_pressed_color", menu_item_type, colors["on_surface"])
		theme.set_color("font_disabled_color", menu_item_type, colors["on_surface_variant"])
		theme.set_stylebox("normal", menu_item_type, StyleBoxEmpty.new())
		theme.set_stylebox("hover", menu_item_type, _style_box(colors["surface_container_highest"], card_radius))
		theme.set_stylebox("pressed", menu_item_type, _style_box(colors["secondary_container"], card_radius))
		theme.set_stylebox("disabled", menu_item_type, StyleBoxEmpty.new())
		theme.set_stylebox("focus", menu_item_type, StyleBoxEmpty.new())
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		theme.set_stylebox(state, "GameboxOverflowMenuDismissButton", StyleBoxEmpty.new())
	theme.set_color("font_color", "GameboxOverflowMenuDangerItem", colors["error"])
	theme.set_color("font_hover_color", "GameboxOverflowMenuDangerItem", colors["error"])
	theme.set_color("font_pressed_color", "GameboxOverflowMenuDangerItem", colors["error"])
	theme.set_stylebox("panel", "GameboxConnectionBannerError", _connection_banner_style(colors["error_container"], card_radius))
	theme.set_constant("separation", "GameboxConnectionBannerContent", _scaled(GameboxTokens.SPACING["section"]))
	theme.set_stylebox("panel", "GameboxSnackbar", _style_box(colors["inverse_surface"], card_radius))
	theme.set_stylebox("panel", "GameboxSnackbarError", _style_box(colors["error_container"], card_radius))
	theme.set_stylebox("panel", "GameboxLoadingOverlay", _style_box(colors["surface_container_high"], card_radius))
	theme.set_stylebox("panel", "GameboxResultPanel", _result_panel_style(colors["surface"], colors["outline_variant"], colors["outline_variant"], colors["shadow"]))
	theme.set_stylebox("panel", "GameboxResultPanelPositive", _result_panel_style(colors["surface"].lerp(colors["primary_container"], GameboxTokens.COMPONENT["result_tint_mix"]), colors["primary"], colors["primary"], colors["shadow"]))
	theme.set_stylebox("panel", "GameboxResultPanelLoss", _result_panel_style(colors["surface"].lerp(loss_container, GameboxTokens.COMPONENT["result_tint_mix"]), loss_accent, loss_accent, colors["shadow"]))
	theme.set_stylebox("panel", "GameboxResultPanelNeutral", _result_panel_style(colors["surface"].lerp(colors["tertiary_container"], GameboxTokens.COMPONENT["result_tint_mix"]), colors["tertiary"], colors["tertiary"], colors["shadow"]))
	theme.set_constant("separation", "GameboxResultContent", _scaled(GameboxTokens.COMPONENT["result_content_spacing"]))
	theme.set_constant("separation", "GameboxResultMeta", _scaled(GameboxTokens.COMPONENT["result_meta_spacing"]))
	theme.set_stylebox("panel", "GameboxResultChipPositive", _result_chip_style(colors["primary_container"]))
	theme.set_stylebox("panel", "GameboxResultChipLoss", _result_chip_style(loss_container))
	theme.set_stylebox("panel", "GameboxResultChipNeutral", _result_chip_style(colors["tertiary_container"]))
	theme.set_color("font_color", "GameboxResultChipLabelPositive", colors["on_primary_container"])
	theme.set_color("font_color", "GameboxResultChipLabelLoss", loss_accent)
	theme.set_color("font_color", "GameboxResultChipLabelNeutral", colors["on_tertiary_container"])
	theme.set_font_size("font_size", "GameboxResultChipLabelPositive", _scaled(GameboxTokens.COMPONENT["result_chip_font_size"]))
	theme.set_font_size("font_size", "GameboxResultChipLabelLoss", _scaled(GameboxTokens.COMPONENT["result_chip_font_size"]))
	theme.set_font_size("font_size", "GameboxResultChipLabelNeutral", _scaled(GameboxTokens.COMPONENT["result_chip_font_size"]))
	theme.set_font("font", "GameboxResultChipLabelPositive", result_bold_font)
	theme.set_font("font", "GameboxResultChipLabelLoss", result_bold_font)
	theme.set_font("font", "GameboxResultChipLabelNeutral", result_bold_font)
	theme.set_color("font_color", "GameboxResultConfirmed", colors["on_surface_variant"])
	theme.set_font_size("font_size", "GameboxResultConfirmed", _scaled(GameboxTokens.COMPONENT["result_confirmed_font_size"]))
	theme.set_color("font_color", "GameboxResultTitle", colors["on_surface"])
	theme.set_font_size("font_size", "GameboxResultTitle", _scaled(GameboxTokens.COMPONENT["result_title_font_size"]))
	theme.set_font("font", "GameboxResultTitle", result_bold_font)
	theme.set_color("font_color", "GameboxResultSupport", colors["on_surface_variant"])
	theme.set_font_size("font_size", "GameboxResultSupport", _scaled(GameboxTokens.COMPONENT["result_support_font_size"]))
	theme.set_constant("separation", "GameboxResultSummary", _scaled(GameboxTokens.COMPONENT["result_summary_spacing"]))
	theme.set_stylebox("panel", "GameboxResultSummaryItem", _result_summary_style(colors["surface_container_highest"], card_radius))
	theme.set_constant("separation", "GameboxResultSummaryItemContent", 0)
	theme.set_color("font_color", "GameboxResultSummaryValue", colors["on_surface"])
	theme.set_font_size("font_size", "GameboxResultSummaryValue", _scaled(GameboxTokens.COMPONENT["result_summary_value_font_size"]))
	theme.set_font("font", "GameboxResultSummaryValue", result_bold_font)
	theme.set_color("font_color", "GameboxResultSummaryLabel", colors["on_surface_variant"])
	theme.set_font_size("font_size", "GameboxResultSummaryLabel", _scaled(GameboxTokens.COMPONENT["result_summary_label_font_size"]))
	theme.set_constant("separation", "GameboxResultActions", _scaled(GameboxTokens.COMPONENT["result_action_spacing"]))
	for state in ["font_color", "font_hover_color", "font_pressed_color"]:
		theme.set_color(state, "GameboxResultReviewButton", colors["on_surface"])
	theme.set_stylebox("normal", "GameboxResultReviewButton", _outlined_button_style(colors["outline"], colors["surface_container_high"]))
	theme.set_stylebox("hover", "GameboxResultReviewButton", _outlined_button_style(colors["primary"], colors["surface_container_highest"]))
	theme.set_stylebox("pressed", "GameboxResultReviewButton", _outlined_button_style(colors["primary"], colors["secondary_container"]))
	theme.set_stylebox("focus", "GameboxResultReviewButton", StyleBoxEmpty.new())
	theme.set_font_size("font_size", "GameboxResultReviewButton", _scaled(GameboxTokens.COMPONENT["result_action_font_size"]))
	theme.set_font_size("font_size", "GameboxResultReturnButton", _scaled(GameboxTokens.COMPONENT["result_action_font_size"]))
	theme.set_font("font", "GameboxResultReviewButton", result_semibold_font)
	theme.set_font("font", "GameboxResultReturnButton", result_semibold_font)
	theme.set_stylebox("panel", "GameboxResultEvidence", _result_evidence_style(colors["surface_container_high"], card_radius))
	theme.set_color("font_color", "GameboxResultEvidenceTitle", colors["on_surface"])
	theme.set_font_size("font_size", "GameboxResultEvidenceTitle", _scaled(GameboxTokens.TYPOGRAPHY["title_small"]["font_size"]))
	theme.set_color("font_color", "GameboxResultEvidenceSupport", colors["on_surface_variant"])
	theme.set_font_size("font_size", "GameboxResultEvidenceSupport", _scaled(GameboxTokens.TYPOGRAPHY["body_small"]["font_size"]))
	theme.set_color("font_color", "GameboxResultEvidencePiece", colors["on_surface"])
	theme.set_font_size("font_size", "GameboxResultEvidencePiece", _scaled(GameboxTokens.TYPOGRAPHY["headline_medium"]["font_size"]))
	theme.set_constant("separation", "GameboxTerminalChoice", _scaled(GameboxTokens.SPACING["layout"]))
	theme.set_stylebox("panel", "GameboxTerminalBackdrop", _solid_style_box(colors["surface"]))
	theme.set_stylebox("panel", "GameboxTerminalHandSurface", _style_box(colors["surface_container_high"], dialog_radius, colors["outline_variant"]))
	theme.set_color("font_color", "GameboxTerminalChoiceLabel", colors["on_surface_variant"])
	theme.set_font_size("font_size", "GameboxTerminalChoiceLabel", _scaled(GameboxTokens.TYPOGRAPHY["body_small"]["font_size"]))
	theme.set_color("font_color", "GameboxTerminalScore", colors["on_surface"])
	theme.set_font_size("font_size", "GameboxTerminalScore", _scaled(GameboxTokens.TYPOGRAPHY["display_small"]["font_size"]))
	theme.set_stylebox("panel", "GameboxDialogScrim", _solid_style_box(Color(colors["scrim"], GameboxTokens.COMPONENT["dialog_scrim_opacity"])))
	theme.set_stylebox("panel", "GameboxConfirmationDialog", _style_box(colors["surface_container_high"], dialog_radius, colors["outline_variant"]))
	theme.set_stylebox("panel", "GameboxSettingsSheet", _style_box(colors["surface_container_high"], dialog_radius, colors["outline_variant"]))
	theme.set_stylebox("panel", "GameboxMoveConfirmationBar", _style_box(colors["surface_container_high"], card_radius, colors["outline_variant"]))
	theme.set_color("font_color", "GameboxConnectionActionButton", colors["on_error_container"])
	theme.set_color("font_hover_color", "GameboxConnectionActionButton", colors["on_error"])
	theme.set_color("font_pressed_color", "GameboxConnectionActionButton", colors["on_error_container"])
	theme.set_stylebox("normal", "GameboxConnectionActionButton", StyleBoxEmpty.new())
	theme.set_stylebox("hover", "GameboxConnectionActionButton", _style_box(colors["error"], GameboxTokens.SHAPE["full"]))
	theme.set_stylebox("pressed", "GameboxConnectionActionButton", StyleBoxEmpty.new())
	theme.set_stylebox("focus", "GameboxConnectionActionButton", StyleBoxEmpty.new())
	theme.set_color("font_color", "GameboxDialogTitle", colors["on_surface"])
	theme.set_font_size("font_size", "GameboxDialogTitle", title_size)
	theme.set_constant("separation", "GameboxDialogContent", _scaled(GameboxTokens.SPACING["section"]))
	theme.set_constant("separation", "GameboxDialogActions", _scaled(GameboxTokens.SPACING["layout"]))
	theme.set_color("font_color", "GameboxDialogCancelButton", colors["on_secondary_container"])
	theme.set_color("font_hover_color", "GameboxDialogCancelButton", colors["on_secondary_container"])
	theme.set_color("font_pressed_color", "GameboxDialogCancelButton", colors["on_secondary_container"])
	theme.set_stylebox("normal", "GameboxDialogCancelButton", _style_box(colors["secondary_container"], GameboxTokens.SHAPE["full"]))
	theme.set_stylebox("hover", "GameboxDialogCancelButton", _style_box(colors["secondary_fixed_dim"], GameboxTokens.SHAPE["full"]))
	theme.set_stylebox("pressed", "GameboxDialogCancelButton", _style_box(colors["secondary_container"], GameboxTokens.SHAPE["full"]))
	theme.set_stylebox("focus", "GameboxDialogCancelButton", StyleBoxEmpty.new())
	theme.set_stylebox("focus", "GameboxDialogConfirmButton", StyleBoxEmpty.new())
	theme.set_color("font_color", "GameboxSecondaryButton", colors["on_secondary_container"])
	theme.set_color("font_hover_color", "GameboxSecondaryButton", colors["on_secondary_container"])
	theme.set_color("font_pressed_color", "GameboxSecondaryButton", colors["on_secondary_container"])
	theme.set_stylebox("normal", "GameboxSecondaryButton", _style_box(colors["secondary_container"], GameboxTokens.SHAPE["full"]))
	theme.set_stylebox("hover", "GameboxSecondaryButton", _style_box(colors["secondary_fixed_dim"], GameboxTokens.SHAPE["full"]))
	theme.set_stylebox("pressed", "GameboxSecondaryButton", _style_box(colors["secondary_container"], GameboxTokens.SHAPE["full"]))
	theme.set_constant("separation", "GameboxSettingsContent", _scaled(GameboxTokens.SPACING["section"]))
	theme.set_constant("separation", "GameboxMoveConfirmationContent", _scaled(GameboxTokens.SPACING["layout"]))
	theme.set_constant("separation", "GameboxMoveConfirmationActions", _scaled(GameboxTokens.SPACING["layout"]))
	theme.set_stylebox("normal", "GameboxSettingsRow", _style_box(colors["surface_container"], card_radius, colors["outline_variant"]))
	theme.set_stylebox("hover", "GameboxSettingsRow", _style_box(colors["surface_container_high"], card_radius, colors["outline_variant"]))
	theme.set_stylebox("pressed", "GameboxSettingsRow", _style_box(colors["surface_container_highest"], card_radius, colors["outline"]))
	theme.set_stylebox("hover_pressed", "GameboxSettingsRow", _style_box(colors["surface_container_highest"], card_radius, colors["outline"]))
	theme.set_stylebox("disabled", "GameboxSettingsRow", _style_box(colors["surface_dim"], card_radius, colors["outline_variant"]))
	theme.set_color("font_color", "GameboxSettingsTitle", colors["on_surface"])
	theme.set_font_size("font_size", "GameboxSettingsTitle", label_size)
	theme.set_color("font_color", "GameboxSettingsDescription", colors["on_surface_variant"])
	theme.set_font_size("font_size", "GameboxSettingsDescription", body_size)
	theme.set_constant("separation", "GameboxSettingsRowContent", _scaled(GameboxTokens.SPACING["layout"]))
	theme.set_constant("separation", "GameboxSettingsLabels", _scaled(GameboxTokens.SPACING["base"]))
	theme.set_color("track_off", "GameboxSwitchVisual", colors["surface_container_highest"])
	theme.set_color("track_on", "GameboxSwitchVisual", colors["primary"])
	theme.set_color("thumb_off", "GameboxSwitchVisual", colors["on_surface_variant"])
	theme.set_color("thumb_on", "GameboxSwitchVisual", colors["on_primary"])
	return theme


static func system_prefers_dark() -> bool:
	if not DisplayServer.is_dark_mode_supported():
		return false
	return DisplayServer.is_dark_mode()


static func _scaled(value: Variant) -> int:
	return roundi(float(value) * LOGICAL_SCALE)


static func _style_box(fill: Color, radius: float, border: Variant = null) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	var corner_radius := _scaled(radius)
	box.corner_radius_top_left = corner_radius
	box.corner_radius_top_right = corner_radius
	box.corner_radius_bottom_right = corner_radius
	box.corner_radius_bottom_left = corner_radius
	var content_margin := float(_scaled(GameboxTokens.SPACING["page"]))
	box.content_margin_left = content_margin
	box.content_margin_top = content_margin
	box.content_margin_right = content_margin
	box.content_margin_bottom = content_margin
	if border is Color:
		var border_width := _scaled(GameboxTokens.SPACING["base"]) / int(LOGICAL_SCALE)
		box.border_color = border
		box.border_width_left = border_width
		box.border_width_top = border_width
		box.border_width_right = border_width
		box.border_width_bottom = border_width
	return box


static func _connection_banner_style(fill: Color, radius: float) -> StyleBoxFlat:
	var box := _style_box(fill, radius)
	box.content_margin_top = 0.0
	box.content_margin_bottom = 0.0
	return box


static func _result_chip_style(fill: Color) -> StyleBoxFlat:
	var box := _style_box(fill, GameboxTokens.SHAPE["full"])
	box.content_margin_left = _scaled(GameboxTokens.COMPONENT["result_chip_horizontal_padding"])
	box.content_margin_right = _scaled(GameboxTokens.COMPONENT["result_chip_horizontal_padding"])
	box.content_margin_top = _scaled(GameboxTokens.COMPONENT["result_chip_vertical_padding"])
	box.content_margin_bottom = _scaled(GameboxTokens.COMPONENT["result_chip_vertical_padding"])
	return box


static func _result_panel_style(fill: Color, border: Color, accent: Color, shadow: Color) -> StyleBoxFlat:
	var box := _style_box(fill, GameboxTokens.COMPONENT["result_panel_radius"], border)
	box.content_margin_left = _scaled(GameboxTokens.COMPONENT["result_panel_horizontal_padding"])
	box.content_margin_top = _scaled(GameboxTokens.COMPONENT["result_panel_top_padding"])
	box.content_margin_right = _scaled(GameboxTokens.COMPONENT["result_panel_horizontal_padding"])
	box.content_margin_bottom = _scaled(GameboxTokens.COMPONENT["result_panel_bottom_padding"])
	box.border_width_top = _scaled(GameboxTokens.COMPONENT["result_panel_accent_width"])
	box.border_color = accent
	box.shadow_color = Color(shadow, GameboxTokens.COMPONENT["result_shadow_opacity"])
	box.shadow_size = _scaled(GameboxTokens.COMPONENT["result_panel_shadow_size"])
	box.shadow_offset = Vector2(0, _scaled(GameboxTokens.COMPONENT["result_panel_shadow_offset"]))
	return box


static func _result_summary_style(fill: Color, radius: float) -> StyleBoxFlat:
	var box := _style_box(fill, radius)
	box.content_margin_left = _scaled(GameboxTokens.SPACING["base"])
	box.content_margin_right = _scaled(GameboxTokens.SPACING["base"])
	box.content_margin_top = _scaled(GameboxTokens.SPACING["base"])
	box.content_margin_bottom = _scaled(GameboxTokens.SPACING["base"])
	return box


static func _result_evidence_style(fill: Color, radius: float) -> StyleBoxFlat:
	var box := _style_box(fill, radius)
	box.content_margin_left = _scaled(GameboxTokens.SPACING["compact"])
	box.content_margin_right = _scaled(GameboxTokens.SPACING["compact"])
	box.content_margin_top = _scaled(GameboxTokens.SPACING["layout"])
	box.content_margin_bottom = _scaled(GameboxTokens.SPACING["layout"])
	return box


static func _outlined_button_style(border: Color, fill: Color) -> StyleBoxFlat:
	return _style_box(fill, GameboxTokens.SHAPE["full"], border)


static func _solid_style_box(fill: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	return box
