shader_type spatial;
render_mode cull_back, depth_draw_opaque;

uniform float dither_bands : hint_range(2.0, 16.0, 1.0) = 6.0;
uniform vec3 camera_position = vec3(0.0);
uniform vec3 camera_direction = vec3(0.0, 0.0, -1.0);
uniform float flashlight_range = 12.0;
uniform float flashlight_inner_cos = 0.94;
uniform float flashlight_outer_cos = 0.82;
uniform float flashlight_intensity = 0.85;
uniform bool flashlight_enabled = true;
uniform float ambient_sky_level = 0.0;
uniform vec3 sun_direction = vec3(0.42, 0.78, 0.45);
uniform float sun_strength = 0.0;
uniform vec3 sun_color = vec3(1.0, 0.86, 0.64);
uniform vec3 sky_tint = vec3(0.80, 0.87, 1.0);
uniform vec3 flashlight_color = vec3(1.0, 0.89, 0.72);
uniform vec3 static_light_color = vec3(1.0);
uniform sampler2D detail_texture : source_color, filter_nearest, repeat_enable;
uniform float detail_strength : hint_range(0.0, 1.0) = 0.65;

varying vec3 fragment_world_position;
varying vec3 fragment_world_normal;
varying vec3 base_color_detail;
varying float static_light_value;
varying float sky_light_value;
varying float canopy_shade;

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

float hash31(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

float value_noise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = hash31(i);
	float n100 = hash31(i + vec3(1.0, 0.0, 0.0));
	float n010 = hash31(i + vec3(0.0, 1.0, 0.0));
	float n110 = hash31(i + vec3(1.0, 1.0, 0.0));
	float n001 = hash31(i + vec3(0.0, 0.0, 1.0));
	float n101 = hash31(i + vec3(1.0, 0.0, 1.0));
	float n011 = hash31(i + vec3(0.0, 1.0, 1.0));
	float n111 = hash31(i + vec3(1.0, 1.0, 1.0));
	return mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
		mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
}

float dynamic_flashlight_level() {
	if (!flashlight_enabled) {
		return 0.0;
	}
	vec3 from_source = fragment_world_position - camera_position;
	float distance_to_fragment = length(from_source);
	if (distance_to_fragment <= 0.001 || distance_to_fragment >= flashlight_range) {
		return 0.0;
	}
	float cone_alignment = dot(from_source / distance_to_fragment, normalize(camera_direction));
	float cone = smoothstep(flashlight_outer_cos, flashlight_inner_cos, cone_alignment);
	float distance_falloff = 1.0 - distance_to_fragment / flashlight_range;
	return clamp(flashlight_intensity * cone * distance_falloff * distance_falloff, 0.0, 1.0);
}

void vertex() {
	fragment_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	fragment_world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
	static_light_value = clamp(COLOR.a, 0.0, 1.0);
	sky_light_value = clamp(UV2.x * ambient_sky_level, 0.0, 1.0);
	canopy_shade = UV2.y > 0.001 ? UV2.y : 1.0;

	// World-space surface detail is evaluated per vertex so the shadowed sun
	// pass can reuse the same mottling and bevel as the emissive fill pass.
	vec3 detail_position = fragment_world_position * 2.4;
	float mottle = value_noise(detail_position) * 0.6 + value_noise(detail_position * 3.1) * 0.4;
	float grain = mix(0.93, 1.07, mottle);
	vec3 cell = fract(fragment_world_position);
	float edge_distance = min(min(cell.x, 1.0 - cell.x), min(min(cell.y, 1.0 - cell.y), min(cell.z, 1.0 - cell.z)));
	float bevel = mix(0.88, 1.0, smoothstep(0.0, 0.08, edge_distance));
	base_color_detail = COLOR.rgb * grain * bevel;
}

void fragment() {
	float flashlight_light = dynamic_flashlight_level();
	float fill_light = static_light_value;
	vec3 fill_tint = static_light_color;
	if (flashlight_light > fill_light) {
		fill_light = flashlight_light;
		fill_tint = flashlight_color;
	}
	if (sky_light_value > fill_light) {
		fill_light = sky_light_value;
		fill_tint = sky_tint;
	}

	float band_count = max(dither_bands - 1.0, 1.0);
	float scaled = fill_light * band_count;
	float lower_band = floor(scaled);
	float upper_band = min(lower_band + 1.0, band_count);
	float threshold = bayer8(FRAGCOORD.xy);
	float band = mix(lower_band, upper_band, step(threshold, fract(scaled)));
	float quantized_light = band / band_count;
	float dither_gate = 1.0 - smoothstep(0.26, 0.60, fill_light);
	float graded_light = mix(fill_light, quantized_light, dither_gate);

	// Block-aligned projected detail: each world unit repeats one textured tile,
	// so grout lines land on block seams and the grain stays crisp up close.
	vec3 detail_weights = abs(normalize(fragment_world_normal));
	detail_weights /= max(detail_weights.x + detail_weights.y + detail_weights.z, 0.001);
	vec3 detail_x = texture(detail_texture, fragment_world_position.zy).rgb;
	vec3 detail_y = texture(detail_texture, fragment_world_position.xz).rgb;
	vec3 detail_z = texture(detail_texture, fragment_world_position.xy).rgb;
	vec3 block_detail = detail_x * detail_weights.x + detail_y * detail_weights.y + detail_z * detail_weights.z;
	vec3 surface_color = base_color_detail * mix(vec3(1.0), block_detail, detail_strength);

	EMISSION = surface_color * graded_light * fill_tint;
	ALBEDO = surface_color;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}

void light() {
	float wrapped = clamp((dot(normalize(NORMAL), LIGHT) + 0.32) / 1.32, 0.0, 1.0);
	float sun_light = clamp(sun_strength * wrapped, 0.0, 1.0);
	if (sun_light > 0.001) {
		float fill_light = max(static_light_value, sky_light_value);
		fill_light = max(fill_light, dynamic_flashlight_level());
		// The engine multiplies the light pass by ALBEDO; fill light is emitted
		// separately, so sun only adds the headroom above that fill.
		DIFFUSE_LIGHT += sun_color * (sun_light * canopy_shade * (1.0 - clamp(fill_light, 0.0, 1.0)) * ATTENUATION);
	}
}
