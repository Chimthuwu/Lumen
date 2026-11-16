shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

uniform vec4 ridge_color : source_color = vec4(0.24, 0.26, 0.32, 1.0);
uniform vec4 haze_color : source_color = vec4(0.72, 0.66, 0.58, 1.0);
uniform float haze_strength = 0.75;

varying float height_factor;

void vertex() {
	// COLOR.r is 0 at the ridge foot and 1 at the crest.
	height_factor = COLOR.r;
}

void fragment() {
	float body = smoothstep(0.0, 0.62, height_factor);
	ALBEDO = mix(haze_color.rgb, ridge_color.rgb, mix(1.0 - haze_strength, 1.0, body));
}
