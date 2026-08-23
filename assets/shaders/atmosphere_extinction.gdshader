shader_type spatial;
render_mode blend_mul, depth_draw_never, depth_test_disabled, cull_front, unshaded, fog_disabled;

// Atmosphere shell, EXTINCTION pass (Track SL4). Multiplies everything behind
// the shell by per-channel transmittance along the same ray the in-scatter
// pass (this material's next_pass) marches: the setting sun seen through the
// limb reddens and flattens, city lights keep their colour through thin air,
// and thick air extinguishes them — per channel, which the old single-pass
// scalar alpha could not do. A discard leaves the scene untouched, which for
// a multiply pass is exactly "transmittance one".

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
	vec3 unused_l;
	if (!atmo_trace(
			ro, rd, NODE_POSITION_WORLD, shell_scale,
			texture(depth_tex, SCREEN_UV).r, SCREEN_UV, INV_PROJECTION_MATRIX,
			false, tau, unused_l)) {
		discard;
	}
	ALBEDO = exp(-min(tau, vec3(60.0)));
	ALPHA = 1.0;
}
