shader_type spatial;
render_mode blend_add, unshaded, depth_draw_never, cull_disabled, fog_disabled;

// Additive billboard glare around the Sun: a tight halo plus a wide soft
// bloom skirt. Depth testing stays ON so a planet crossing the sun occludes
// the glare per-pixel; the quad is pulled toward the camera in view space so
// the Sun's own sphere (which sits in front of the quad's plane) does not
// occlude its own glare.

uniform vec3 tint : source_color = vec3(1.0, 0.9, 0.72);
uniform float intensity = 3.2;

varying vec2 v_uv;


void vertex() {
	v_uv = UV * 2.0 - 1.0;
	// Billboard: keep the model's translation, replace its rotation with the
	// camera's, reapply the model scale.
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2],
		MODEL_MATRIX[3]);
	float s = length(MODEL_MATRIX[0].xyz);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(
		vec4(s, 0.0, 0.0, 0.0),
		vec4(0.0, s, 0.0, 0.0),
		vec4(0.0, 0.0, s, 0.0),
		vec4(0.0, 0.0, 0.0, 1.0));
	// Toward the camera (+Z in view space) past the sun sphere's front face:
	// the quad spans 4 sun radii (CelestialBody scales it), so 0.3 of its
	// scale is ~1.2 radii of pull.
	MODELVIEW_MATRIX[3].z += s * 0.3;
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}


void fragment() {
	float r = length(v_uv);
	float halo = exp(-r * 6.0);
	float skirt = exp(-r * 2.1) * 0.2;
	// Fade before the quad edge so the additive layer never shows a square.
	float edge = smoothstep(1.0, 0.9, r);
	ALBEDO = tint * (halo + skirt) * intensity * edge;
}
