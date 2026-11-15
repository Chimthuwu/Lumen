shader_type spatial;
render_mode unshaded;

uniform float dither_bands : hint_range(2.0, 16.0, 1.0) = 6.0;
uniform vec3 flashlight_position = vec3(0.0);
uniform vec3 flashlight_direction = vec3(0.0, 0.0, -1.0);
uniform float flashlight_range = 12.0;
uniform float flashlight_inner_cos = 0.94;
uniform float flashlight_outer_cos = 0.82;
uniform float flashlight_intensity = 0.85;
uniform bool flashlight_enabled = true;

varying vec3 fragment_world_position;

void vertex() {
	fragment_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

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

float dynamic_flashlight_level() {
	if (!flashlight_enabled) {
		return 0.0;
	}
	vec3 from_source = fragment_world_position - flashlight_position;
	float distance_to_fragment = length(from_source);
	if (distance_to_fragment <= 0.001 || distance_to_fragment >= flashlight_range) {
		return 0.0;
	}
	float cone_alignment = dot(from_source / distance_to_fragment, normalize(flashlight_direction));
	float cone = smoothstep(flashlight_outer_cos, flashlight_inner_cos, cone_alignment);
	float distance_falloff = 1.0 - distance_to_fragment / flashlight_range;
	return clamp(flashlight_intensity * cone * distance_falloff * distance_falloff, 0.0, 1.0);
}

void fragment() {
	float static_light = clamp(COLOR.a, 0.0, 1.0);
	float flashlight_light = dynamic_flashlight_level();
	float light_value = max(static_light, flashlight_light);
	float scaled = light_value * (dither_bands - 1.0);
	float lower_band = floor(scaled);
	float upper_band = min(lower_band + 1.0, dither_bands - 1.0);
	float threshold = bayer8(FRAGCOORD.xy);
	float band = mix(lower_band, upper_band, step(threshold, fract(scaled)));
	float quantized_light = band / (dither_bands - 1.0);
	ALBEDO = COLOR.rgb * quantized_light;
}