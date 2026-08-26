# GENERATED CODE - DO NOT MODIFY BY HAND.
# Source: design_system/tokens/gamebox.tokens.json

class_name GameboxTokens
extends RefCounted

const VERSION := "2.0.0"
const BRAND_SEED := "#006B60"

const LIGHT := {
    "error": Color("#BA1A1A"),
    "error_container": Color("#FFDAD6"),
    "inverse_primary": Color("#82D5C7"),
    "inverse_surface": Color("#2B3230"),
    "on_error": Color("#FFFFFF"),
    "on_error_container": Color("#93000A"),
    "on_inverse_surface": Color("#ECF2EF"),
    "on_primary": Color("#FFFFFF"),
    "on_primary_container": Color("#005048"),
    "on_primary_fixed": Color("#00201C"),
    "on_primary_fixed_variant": Color("#005048"),
    "on_secondary": Color("#FFFFFF"),
    "on_secondary_container": Color("#334B47"),
    "on_secondary_fixed": Color("#05201C"),
    "on_secondary_fixed_variant": Color("#334B47"),
    "on_surface": Color("#161D1B"),
    "on_surface_variant": Color("#3F4946"),
    "on_tertiary": Color("#FFFFFF"),
    "on_tertiary_container": Color("#2D4960"),
    "on_tertiary_fixed": Color("#001E31"),
    "on_tertiary_fixed_variant": Color("#2D4960"),
    "outline": Color("#6F7976"),
    "outline_variant": Color("#BEC9C5"),
    "primary": Color("#006B60"),
    "primary_container": Color("#9EF2E3"),
    "primary_fixed": Color("#9EF2E3"),
    "primary_fixed_dim": Color("#82D5C7"),
    "scrim": Color("#000000"),
    "secondary": Color("#4A635E"),
    "secondary_container": Color("#CCE8E2"),
    "secondary_fixed": Color("#CCE8E2"),
    "secondary_fixed_dim": Color("#B1CCC6"),
    "shadow": Color("#000000"),
    "surface": Color("#F4FBF8"),
    "surface_bright": Color("#F4FBF8"),
    "surface_container": Color("#E9EFEC"),
    "surface_container_high": Color("#E3EAE7"),
    "surface_container_highest": Color("#DDE4E1"),
    "surface_container_low": Color("#EFF5F2"),
    "surface_container_lowest": Color("#FFFFFF"),
    "surface_dim": Color("#D5DBD9"),
    "surface_tint": Color("#006B60"),
    "tertiary": Color("#456179"),
    "tertiary_container": Color("#CCE5FF"),
    "tertiary_fixed": Color("#CCE5FF"),
    "tertiary_fixed_dim": Color("#ADCAE5"),
}

const DARK := {
    "error": Color("#FFB4AB"),
    "error_container": Color("#93000A"),
    "inverse_primary": Color("#006B60"),
    "inverse_surface": Color("#DDE4E1"),
    "on_error": Color("#690005"),
    "on_error_container": Color("#FFDAD6"),
    "on_inverse_surface": Color("#2B3230"),
    "on_primary": Color("#003731"),
    "on_primary_container": Color("#9EF2E3"),
    "on_primary_fixed": Color("#00201C"),
    "on_primary_fixed_variant": Color("#005048"),
    "on_secondary": Color("#1C3531"),
    "on_secondary_container": Color("#CCE8E2"),
    "on_secondary_fixed": Color("#05201C"),
    "on_secondary_fixed_variant": Color("#334B47"),
    "on_surface": Color("#DDE4E1"),
    "on_surface_variant": Color("#BEC9C5"),
    "on_tertiary": Color("#143349"),
    "on_tertiary_container": Color("#CCE5FF"),
    "on_tertiary_fixed": Color("#001E31"),
    "on_tertiary_fixed_variant": Color("#2D4960"),
    "outline": Color("#899390"),
    "outline_variant": Color("#3F4946"),
    "primary": Color("#82D5C7"),
    "primary_container": Color("#005048"),
    "primary_fixed": Color("#9EF2E3"),
    "primary_fixed_dim": Color("#82D5C7"),
    "scrim": Color("#000000"),
    "secondary": Color("#B1CCC6"),
    "secondary_container": Color("#334B47"),
    "secondary_fixed": Color("#CCE8E2"),
    "secondary_fixed_dim": Color("#B1CCC6"),
    "shadow": Color("#000000"),
    "surface": Color("#0E1513"),
    "surface_bright": Color("#343B39"),
    "surface_container": Color("#1A211F"),
    "surface_container_high": Color("#252B2A"),
    "surface_container_highest": Color("#303634"),
    "surface_container_low": Color("#161D1B"),
    "surface_container_lowest": Color("#090F0E"),
    "surface_dim": Color("#0E1513"),
    "surface_tint": Color("#82D5C7"),
    "tertiary": Color("#ADCAE5"),
    "tertiary_container": Color("#2D4960"),
    "tertiary_fixed": Color("#CCE5FF"),
    "tertiary_fixed_dim": Color("#ADCAE5"),
}

const GAME := {
    "black_piece": Color("#151A24"),
    "board": Color("#D8A85F"),
    "grid": Color("#493217"),
    "last_move": Color("#F04438"),
    "pending_move": Color("#0072B2"),
    "pending_overlay_alpha": 0.56,
    "pressed_move": Color("#7A5AF8"),
    "white_piece": Color("#F8FAFC"),
    "white_piece_outline": Color("#667085"),
}

const TYPOGRAPHY := {
    "body_large": {
        "font_size": 16,
        "font_weight": 400,
        "line_height": 24,
    },
    "body_medium": {
        "font_size": 14,
        "font_weight": 400,
        "line_height": 20,
    },
    "body_small": {
        "font_size": 12,
        "font_weight": 400,
        "line_height": 16,
    },
    "display_large": {
        "font_size": 57,
        "font_weight": 400,
        "line_height": 64,
    },
    "display_medium": {
        "font_size": 45,
        "font_weight": 400,
        "line_height": 52,
    },
    "display_small": {
        "font_size": 36,
        "font_weight": 400,
        "line_height": 44,
    },
    "headline_large": {
        "font_size": 32,
        "font_weight": 400,
        "line_height": 40,
    },
    "headline_medium": {
        "font_size": 28,
        "font_weight": 400,
        "line_height": 36,
    },
    "headline_small": {
        "font_size": 24,
        "font_weight": 400,
        "line_height": 32,
    },
    "label_large": {
        "font_size": 14,
        "font_weight": 500,
        "line_height": 20,
    },
    "label_medium": {
        "font_size": 12,
        "font_weight": 500,
        "line_height": 16,
    },
    "label_small": {
        "font_size": 11,
        "font_weight": 500,
        "line_height": 16,
    },
    "title_large": {
        "font_size": 22,
        "font_weight": 400,
        "line_height": 28,
    },
    "title_medium": {
        "font_size": 16,
        "font_weight": 500,
        "line_height": 24,
    },
    "title_small": {
        "font_size": 14,
        "font_weight": 500,
        "line_height": 20,
    },
}

const SPACING := {
    "base": 4,
    "compact": 12,
    "large": 32,
    "layout": 8,
    "page": 16,
    "section": 24,
    "xlarge": 40,
    "xxlarge": 48,
}

const SHAPE := {
    "card": 12,
    "dialog": 28,
    "floating": 16,
    "full": 999,
    "input": 8,
}

const MOTION := {
    "fast": 100,
    "page_enter": 400,
    "slow": 300,
    "standard": 200,
}

const COMPONENT := {
    "dialog_scrim_opacity": 0.32,
    "media_viewport_height": 260,
    "minimum_touch_target": 48,
    "page_max_width": 560,
    "page_padding": 16,
    "section_spacing": 24,
    "small_progress_size": 20,
}
