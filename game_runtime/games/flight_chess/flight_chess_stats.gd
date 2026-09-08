extends Control

const Tokens = preload("res://design_system/generated/gamebox_tokens.gd")
const PLANE = [Vector2(12,0),Vector2(14,2),Vector2(14,9),Vector2(23,15),Vector2(23,18),Vector2(14,14),Vector2(14,20),Vector2(18,23),Vector2(18,24),Vector2(12,22),Vector2(6,24),Vector2(6,23),Vector2(10,20),Vector2(10,14),Vector2(1,18),Vector2(1,15),Vector2(10,9),Vector2(10,2)]

var counts := [0, 0, 0]
var arrival_color: Color = Tokens.LIGHT.primary
var empty_color: Color = Tokens.LIGHT.outline_variant

func present(pieces: Array) -> void:
	counts = [0, 0, 0]
	for piece in pieces:
		counts[1 if piece.zone == "hangar" else 2 if piece.zone == "finished" else 0] += 1
	tooltip_text = "已抵达 %d / 4" % counts[2]
	queue_redraw()

func _draw() -> void:
	var unit := size.y / 48.0
	var ink := get_theme_color("font_color", "Label")
	var font := get_theme_default_font()
	var font_size := maxi(1,roundi(Tokens.TYPOGRAPHY.label_small.font_size * unit))
	var value := "%d / 4" % counts[2]
	draw_string(font,Vector2(0,11)*unit,"全部抵达" if counts[2] == 4 else "已抵达",HORIZONTAL_ALIGNMENT_LEFT,-1,font_size,ink)
	draw_string(font,Vector2(size.x-font.get_string_size(value,HORIZONTAL_ALIGNMENT_LEFT,-1,font_size).x,11*unit),value,HORIZONTAL_ALIGNMENT_LEFT,-1,font_size,ink)
	for i in 4:
		var origin := Vector2(i * (size.x-24*unit)/3.0,24*unit)
		var polygon := PackedVector2Array()
		for point in PLANE:
			polygon.append(origin + point * unit)
		if i < counts[2]:
			draw_colored_polygon(polygon,arrival_color)
		else:
			polygon.append(polygon[0])
			draw_polyline(polygon,empty_color,1.3*unit,true)
