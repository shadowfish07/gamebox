shader_type canvas_item;

void fragment() {
	float strength = 1.0 - smoothstep(0.0, 0.42, distance(UV, vec2(0.5)));
	COLOR.a *= strength;
}
