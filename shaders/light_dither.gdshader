shader_type spatial;
render_mode unshaded;

uniform float dither_bands : hint_range(2.0, 16.0, 1.0) = 6.0;

float bayer8(vec2 pixel_position) {
	ivec2 cell = ivec2(mod(floor(pixel_position), 8.0));
	int rank = 0;
	for (int bit_index = 0; bit_index < 3; bit_index++) {
		int x_bit = (cell.x >> bit_index) & 1;
		int y_bit = (cell.y >> bit_index) & 1;
		int rank_2 = ((x_bit ^ y_bit) << 1) | y_bit;
		rank += rank_2 << (bit_index * 2);
	}
	return (float(rank) + 0.5) / 64.0;
}

void fragment() {
	float light_value = clamp(COLOR.a, 0.0, 1.0);
	float scaled = light_value * (dither_bands - 1.0);
	float lower_band = floor(scaled);
	float upper_band = min(lower_band + 1.0, dither_bands - 1.0);
	float threshold = bayer8(FRAGCOORD.xy);
	float band = mix(lower_band, upper_band, step(threshold, fract(scaled)));
	float quantized_light = band / (dither_bands - 1.0);
	ALBEDO = COLOR.rgb * quantized_light;
}
