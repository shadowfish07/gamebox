extends Control

var counts := [0, 0, 0]

func present(pieces: Array) -> void:
	counts = [0, 0, 0]
	for piece in pieces:
		counts[1 if piece.zone == "hangar" else 2 if piece.zone == "finished" else 0] += 1
	tooltip_text = "在途 %d · 待机 %d · 抵达 %d" % counts
	queue_redraw()

func _draw() -> void:
	var unit := size.y / 24.0
	var ink := get_theme_color("font_color", "Label")
	for i in 3:
		var origin := Vector2(i * 44.0 + 2.0, 5.0) * unit
		var points: Array
		match i:
			0: points = [Vector2(7, 0), Vector2(9, 1), Vector2(9, 6), Vector2(14, 10), Vector2(14, 12), Vector2(9, 10), Vector2(9, 14), Vector2(11, 16), Vector2(5, 16), Vector2(7, 14), Vector2(7, 10), Vector2(2, 12), Vector2(2, 10), Vector2(7, 6), Vector2(7, 0)]
			1: points = [Vector2(1, 15), Vector2(1, 5), Vector2(8, 0), Vector2(15, 5), Vector2(15, 15), Vector2(1, 15), Vector2(4, 15), Vector2(4, 7), Vector2(12, 7), Vector2(12, 15)]
			_: points = [Vector2(2, 16), Vector2(2, 1), Vector2(8, 1), Vector2(10, 3), Vector2(15, 3), Vector2(15, 10), Vector2(10, 10), Vector2(8, 8), Vector2(2, 8)]
		var line := PackedVector2Array()
		for point in points:
			line.append(origin + point * unit)
		draw_polyline(line, ink, 1.3 * unit, true)
		draw_string(get_theme_default_font(), origin + Vector2(21, 13) * unit, str(counts[i]), HORIZONTAL_ALIGNMENT_LEFT, -1, maxi(1,roundi(12 * unit)), ink)
