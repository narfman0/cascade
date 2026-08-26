shader_type spatial;
// Minor-body rock surface: flat Synty-ish base colour plus the shared ground
// micro-detail, so walking an asteroid reads as regolith instead of vinyl.

#include "res://assets/shaders/ground_detail.gdshaderinc"

uniform vec4 base_color : source_color = vec4(0.5, 0.5, 0.5, 1.0);
uniform float roughness_value : hint_range(0.0, 1.0) = 0.95;
uniform float body_radius = 200.0;
uniform float ground_detail_strength : hint_range(0.0, 0.6) = 0.26;

varying vec3 v_pos_m;      // body-local metres, stable under the node's spin
varying float v_view_dist;

void vertex() {
	v_pos_m = VERTEX * body_radius;   // mesh is unit-scale, node scales it
	v_view_dist = length((MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz);
}

void fragment() {
	ROUGHNESS = roughness_value;
	METALLIC = 0.0;
	ALBEDO = base_color.rgb;
	if (ground_detail_strength > 0.0) {
		vec3 gd_grad;
		float gd_mul = gd_detail(v_pos_m, normalize(v_pos_m), v_view_dist,
			ground_detail_strength, gd_grad);
		ALBEDO *= gd_mul;
		if (dot(gd_grad, gd_grad) > 0.0) {
			mat3 mv = mat3(VIEW_MATRIX * MODEL_MATRIX);
			NORMAL = normalize(NORMAL + mv * gd_grad * 2.4);
		}
	}
}
