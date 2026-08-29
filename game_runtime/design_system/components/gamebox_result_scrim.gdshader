shader_type canvas_item;

void fragment() {
	COLOR.a *= smoothstep(0.22, 0.68, UV.y);
}
