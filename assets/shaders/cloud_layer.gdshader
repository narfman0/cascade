shader_type spatial;
// diffuse_lambert, NOT lambert_wrap: wrap lights the deck ~30 deg past the
// terminator, which swamps the 7.2-deg twilight band the atmosphere model
// derives — clouds and sky must go dark across the SAME band (PR4's rule for
// the city lights applies to the weather too).
render_mode blend_mix, depth_draw_never, cull_back, diffuse_lambert, specular_disabled, fog_disabled;

// Procedural cloud deck (PR5): one translucent sphere just above the terrain,
// value-noise fbm over the sphere direction so there is no seam and no pole
// pinch, lit by the scene's directional sun so the terminator falls across the
// clouds exactly where it falls across the ground. TIME drifts the noise
// domain — weather crawls relative to the spinning surface underneath.
//
// The deck sits below the atmosphere shell and draws before it
// (render_priority), so limb haze and twilight colour composite over the
// clouds the same way they composite over terrain. Mountains taller than the
// deck height rise through it — depth testing against the opaque terrain is
// what clips the sheet around them.

uniform float coverage : hint_range(0.0, 1.0) = 0.5;
uniform float density : hint_range(0.0, 1.0) = 0.92;
uniform float noise_scale = 5.0;
uniform float drift_speed = 0.004;
uniform vec3 cloud_tint : source_color = vec3(0.97, 0.97, 0.98);

// Real cloud-fraction climatology (equirect, same lon/lat mapping as the
// surface maps). It decides WHERE clouds live — storm tracks, the ITCZ —
// while the fbm below provides texture and drift. Without it the deck is
// uniform noise and clouds sit over the Sahara as happily as the Atlantic.
uniform sampler2D coverage_map : filter_linear_mipmap, repeat_enable;
uniform bool has_coverage_map = false;

#include "res://assets/shaders/cloud_field.gdshaderinc"

varying vec3 v_dir;


void vertex() {
	v_dir = normalize(VERTEX);
}


void fragment() {
	// One field definition, shared with the surface shader's cloud shadows —
	// see cloud_field.gdshaderinc for why it must not be duplicated.
	float a = cloud_field_alpha(
		v_dir, coverage_map, has_coverage_map, coverage,
		noise_scale, drift_speed, TIME);
	// Fade at grazing incidence: a single-layer deck seen nearly edge-on
	// (skimming, or the last pixels of the limb) otherwise saturates into
	// solid overcast, because every ray crosses SOME cloud within a few
	// hundred metres. Overhead views are untouched.
	a *= smoothstep(0.02, 0.3, clamp(dot(NORMAL, VIEW), 0.0, 1.0));
	ALBEDO = cloud_tint;
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
	ALPHA = a * density;
}
