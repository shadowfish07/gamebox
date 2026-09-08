extends Control

const Tokens = preload("res://design_system/generated/gamebox_tokens.gd")
const Board = preload("res://games/flight_chess/flight_chess_board.gd")
const Stats = preload("res://games/flight_chess/flight_chess_stats.gd")

var count := -1
var delta := 0
var unit := 1.0
var ink: Color
var fill: Color
var text: String:
	get: return "撞回 %s 架" % (str(count) if count >= 0 else "—")
var feedback_phase := 1.0:
	set(value):
		feedback_phase = value
		queue_redraw()
var _feedback_tween: Tween


func present(value: int, color: String, dark: bool) -> void:
	count = value
	var colors: Dictionary = Tokens.DARK if dark else Tokens.LIGHT
	ink = colors.on_surface_variant if count <= 0 else Board.PLAYER_COLORS[color] if dark else Board.PLAYER_DARK[color]
	fill = colors.surface_container_low.lerp(ink, 0.10)
	tooltip_text = text
	queue_redraw()


func play_capture(amount: int) -> void:
	cancel_feedback()
	if amount <= 0:
		return
	delta = amount
	feedback_phase = 0.0
	_feedback_tween = create_tween()
	_feedback_tween.tween_property(self, "feedback_phase", 1.0, (Tokens.MOTION.standard + Tokens.MOTION.slow) / 1000.0)
	_feedback_tween.tween_callback(func() -> void:
		delta = 0
		queue_redraw()
	)


func cancel_feedback() -> void:
	if _feedback_tween != null:
		_feedback_tween.kill()
		_feedback_tween = null
	delta = 0
	feedback_phase = 1.0


func _draw() -> void:
	var font := get_theme_font("font", "FlightChessPlayerName")
	var font_size := maxi(1, roundi(Tokens.TYPOGRAPHY.label_medium.font_size * unit))
	var value := str(count) if count >= 0 else "—"
	var width := font.get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x + 32 * unit
	var rect := Rect2(Vector2(size.x - width, 0), Vector2(width, size.y))
	var pulse := 1.0 + 0.10 * sin(minf(feedback_phase / 0.6, 1.0) * PI)
	draw_set_transform(rect.get_center() * (1.0 - pulse), 0.0, Vector2.ONE * pulse)
	var background := StyleBoxFlat.new()
	background.bg_color = fill
	background.set_corner_radius_all(roundi(size.y / 2))
	draw_style_box(background, rect)
	var center := rect.position + Vector2(12 * unit, size.y / 2)
	var plane := PackedVector2Array()
	for point in Stats.PLANE:
		plane.append(center + (point - Vector2(12, 12)).rotated(PI / 2) * 0.58 * unit)
	draw_colored_polygon(plane, ink)
	var spark := PackedVector2Array()
	var spark_center := center + Vector2(10, -4) * unit
	for i in 8:
		var radius := 3.4 if i % 2 == 0 else 1.1
		spark.append(spark_center + Vector2.UP.rotated(i * PI / 4) * radius * unit)
	draw_colored_polygon(spark, ink)
	var baseline := (size.y - font.get_height(font_size)) / 2 + font.get_ascent(font_size)
	draw_string(font, Vector2(rect.position.x + 27 * unit, baseline), value, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, ink)
	draw_set_transform(Vector2.ZERO)
	if delta > 0:
		var feedback_ink := ink
		feedback_ink.a = 1.0 - smoothstep(0.45, 1.0, feedback_phase)
		var feedback := "+%d" % delta
		var feedback_size := maxi(1, roundi(Tokens.TYPOGRAPHY.label_small.font_size * unit))
		var feedback_width := font.get_string_size(feedback, HORIZONTAL_ALIGNMENT_LEFT, -1, feedback_size).x
		# Use the gap beside the capsule so the popup never crosses the turn pill above it.
		draw_string(font, Vector2(rect.position.x - feedback_width - 4 * unit, baseline - (2 + 4 * feedback_phase) * unit), feedback, HORIZONTAL_ALIGNMENT_LEFT, -1, feedback_size, feedback_ink)
