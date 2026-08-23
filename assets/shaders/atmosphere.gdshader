shader_type spatial;
render_mode blend_add, depth_draw_never, depth_test_disabled, cull_front, unshaded, fog_disabled;

// Atmosphere shell, IN-SCATTER pass (PR4; two-pass since Track SL4). Runs as
// the next_pass of atmosphere_extinction.gdshader on the same back-face shell:
// the extinction pass has already multiplied the scene by per-channel
// transmittance, so this pass simply adds the in-scattered light on top —
// Hillaire's L_scene * T + L_inscatter composite, exact per channel, no
// scalar-alpha compromise. All shared math lives in atmosphere_common.

#include "res://assets/shaders/atmosphere_common.gdshaderinc"

varying vec3 v_world_pos;


void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}


void fragment() {
	if (!luts_ok) {
		discard;
	}
	vec3 ro = CAMERA_POSITION_WORLD;
	vec3 rd = normalize(v_world_pos - ro);
	float shell_scale = length(MODEL_MATRIX[0].xyz);
	vec3 tau;
	vec3 radiance;
	if (!atmo_trace(
			ro, rd, NODE_POSITION_WORLD, shell_scale,
			texture(depth_tex, SCREEN_UV).r, SCREEN_UV, INV_PROJECTION_MATRIX,
			true, tau, radiance)) {
		discard;
	}
	ALBEDO = radiance;
	ALPHA = 1.0;
}
