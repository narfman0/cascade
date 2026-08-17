shader_type spatial;
// Planet surface: baked equirect albedo/normal lookup plus terminator-gated
// night lights. One material per body; every patch shares it, and the only
// per-patch data is the patch center (an instance uniform), which lets the
// fragment stage rebuild the exact sphere direction — so texture sampling has
// no per-vertex UV seam at the antimeridian and no smearing at the poles.

// Direction from the render origin toward the Sun, set by SolarSystem each
// frame (it already aims the system light from the same numbers).
global uniform vec3 planet_sun_direction;

// Patch-node local position under PlanetSurface — the patch center. Vertices
// are stored relative to it (float32 discipline, docs/planet-renderer.md).
instance uniform vec3 patch_center;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D emissive_tex : filter_linear_mipmap, repeat_enable;
uniform bool textures_ok = false;
uniform bool has_emissive = false;
uniform vec4 base_color : source_color = vec4(0.5, 0.5, 0.5, 1.0);
uniform float roughness_value : hint_range(0.0, 1.0) = 0.9;
uniform float normal_strength = 1.0;
uniform vec3 emissive_tint : source_color = vec3(1.0, 0.86, 0.58);
uniform float emissive_energy = 2.5;

// Sphere direction in surface-local (terrain) space: spin rotates the whole
// PlanetSurface node, and patches sit under it by pure translation, so
// VERTEX + patch_center normalized is exactly the direction the bake sampled.
varying vec3 v_sdir;

void vertex() {
	v_sdir = normalize(VERTEX + patch_center);
}

void fragment() {
	vec3 sdir = normalize(v_sdir);
	ROUGHNESS = roughness_value;
	METALLIC = 0.0;
	if (!textures_ok) {
		// Bake still in flight on a worker: flat colour, exactly the old look.
		ALBEDO = base_color.rgb;
	} else {
		float lon = atan(sdir.z, sdir.x);
		float lat = asin(clamp(sdir.y, -1.0, 1.0));
		vec2 uv = vec2(0.5 + lon / TAU, 0.5 - lat / PI);
		ALBEDO = texture(albedo_tex, uv).rgb;

		// Baked slopes live in an east/south/up frame; rebuild it per pixel and
		// perturb the interpolated geometric normal in view space.
		vec3 east_l = vec3(-sdir.z, 0.0, sdir.x);
		float east_len = length(east_l);
		if (east_len > 1e-4) {
			east_l /= east_len;
			vec3 south_l = normalize(cross(sdir, east_l));
			mat3 mv = mat3(MODELVIEW_MATRIX);
			vec3 east_v = normalize(mv * east_l);
			vec3 south_v = normalize(mv * south_l);
			vec3 nm = texture(normal_tex, uv).rgb * 2.0 - 1.0;
			NORMAL = normalize(
				east_v * nm.x * normal_strength
				+ south_v * nm.y * normal_strength
				+ NORMAL * max(nm.z, 0.25)
			);
		}

		if (has_emissive) {
			// Night lights fade in across dusk: full off at sun elevation
			// dot 0.05, full on by -0.15 (the design doc's
			// smoothstep(0.05, -0.15, d), written with ascending edges because
			// GLSL leaves descending-edge smoothstep undefined).
			vec3 sun_view = normalize(
				(VIEW_MATRIX * vec4(planet_sun_direction, 0.0)).xyz
			);
			float night = 1.0 - smoothstep(-0.15, 0.05, dot(NORMAL, sun_view));
			EMISSION = texture(emissive_tex, uv).rgb * emissive_tint
				* night * emissive_energy;
		}
	}
}
