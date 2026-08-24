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
	theme.set_type_variation("GameboxSnackbar", "PanelContainer")
	theme.set_type_variation("GameboxSnackbarError", "PanelContainer")
	theme.set_type_variation("GameboxLoadingOverlay", "PanelContainer")
	theme.set_type_variation("GameboxResultPanel", "PanelContainer")
	theme.set_type_variation("GameboxDialogScrim", "PanelContainer")
	theme.set_type_variation("GameboxConfirmationDialog", "PanelContainer")
	theme.set_type_variation("GameboxDialogTitle", "Label")
	theme.set_type_variation("GameboxDialogContent", "VBoxContainer")
	theme.set_type_variation("GameboxDialogActions", "HBoxContainer")
	theme.set_type_variation("GameboxDialogCancelButton", "Button")
	theme.set_stylebox("panel", "GameboxConnectionBanner", _style_box(colors["secondary_container"], card_radius))
	theme.set_stylebox("panel", "GameboxSnackbar", _style_box(colors["inverse_surface"], card_radius))
	theme.set_stylebox("panel", "GameboxSnackbarError", _style_box(colors["error_container"], card_radius))
	theme.set_stylebox("panel", "GameboxLoadingOverlay", _style_box(colors["surface_container_high"], card_radius))
	theme.set_stylebox("panel", "GameboxResultPanel", _style_box(colors["surface_container_high"], dialog_radius, colors["outline_variant"]))
	theme.set_stylebox("panel", "GameboxDialogScrim", _solid_style_box(Color(colors["scrim"], GameboxTokens.COMPONENT["dialog_scrim_opacity"])))
	theme.set_stylebox("panel", "GameboxConfirmationDialog", _style_box(colors["surface_container_high"], dialog_radius, colors["outline_variant"]))
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


static func _solid_style_box(fill: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	return box
