shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;

uniform vec3 sun_direction = vec3(0.42, 0.78, 0.45);
uniform vec3 sun_color = vec3(1.0, 0.86, 0.64);
uniform float sun_strength = 0.0;
uniform vec3 sky_tint = vec3(0.74, 0.84, 1.0);
uniform float ambient_sky_level = 0.0;
uniform float wind_strength = 0.0;
uniform float wind_speed = 1.7;
uniform float ground_cover = 0.0;

varying vec3 base_color;
varying float height_factor;

void vertex() {
	base_color = COLOR.rgb;
	height_factor = COLOR.a;
	if (wind_strength > 0.0001) {
		vec3 world_origin = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
		float phase = world_origin.x * 0.45 + world_origin.z * 0.37;
		float sway = sin(TIME * wind_speed + phase) + 0.35 * sin(TIME * wind_speed * 2.3 + phase * 1.7);
		float bend = wind_strength * height_factor * height_factor;
		VERTEX.x += sway * bend;
		VERTEX.z += cos(TIME * wind_speed * 0.8 + phase) * bend * 0.5;
	}
}

void fragment() {
	if (ground_cover > 0.5) {
		// Flat blades would read as dark slivers with their sideways normals;
		// treating cover as ground-facing keeps it lit like the soil it grows from.
		NORMAL = vec3(0.0, 1.0, 0.0);
	}
	ALBEDO = base_color;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
	// Unshadowed sky/ambient term; sunlight arrives through the light() pass with
	// the directional shadow map folded into ATTENUATION.
	EMISSION = base_color * sky_tint * (ambient_sky_level * 0.45);
}

void light() {
	float wrapped = clamp((dot(normalize(NORMAL), LIGHT) + 0.25) / 1.25, 0.0, 1.0);
	float sun_light = sun_strength * wrapped;
	if (sun_light > 0.001) {
		DIFFUSE_LIGHT += sun_color * (sun_light * ATTENUATION);
	}
}
