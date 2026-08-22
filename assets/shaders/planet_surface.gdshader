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

// Geomorph factor (PR5): 0 = render this patch as its parent's surface
// (CUSTOM0/CUSTOM1 carry the parent-level position and normal per vertex),
// 1 = full own detail. PlanetSurface drives it from the same screen-space
// error metric that decides splits, so LOD transitions never pop.
instance uniform float morph_t : hint_range(0.0, 1.0) = 1.0;

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

// Night-lights gate thresholds on dot(normal, sun). Defaults keep the original
// hardcoded band; a body with an atmosphere overrides them from
// BodyAtmosphere.night_gate(), so the lights fade across the same twilight
// band the sky does (PR4: twilight drives the city lights).
uniform float night_gate_lo = -0.15;
uniform float night_gate_hi = 0.05;

// Linear limb-darkening for gas giants — their visible "surface" is already
// atmosphere, so they get I(mu)/I(1) = 1 - u*(1 - mu) instead of a shell.
uniform float limb_darkening = 0.0;

// Sphere direction in surface-local (terrain) space: spin rotates the whole
// PlanetSurface node, and patches sit under it by pure translation, so
// VERTEX + patch_center normalized is exactly the direction the bake sampled.
varying vec3 v_sdir;

void vertex() {
	VERTEX = mix(CUSTOM0.xyz, VERTEX, morph_t);
	NORMAL = normalize(mix(CUSTOM1.xyz, NORMAL, morph_t));
	// Texture sampling follows the morphed geometry, so albedo and relief
	// shading slide together instead of swimming against each other.
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
			// MODELVIEW_MATRIX is a vertex-stage builtin in Godot 4 and does not
			// exist in fragment(); referencing it fails compilation, which
			// silently falls the whole surface back to the default grey
			// material. VIEW_MATRIX * MODEL_MATRIX is the fragment-stage
			// equivalent.
			mat3 mv = mat3(VIEW_MATRIX * MODEL_MATRIX);
			vec3 east_v = normalize(mv * east_l);
			vec3 south_v = normalize(mv * south_l);
			vec3 nm = texture(normal_tex, uv).rgb * 2.0 - 1.0;
			NORMAL = normalize(
				east_v * nm.x * normal_strength
				+ south_v * nm.y * normal_strength
				+ NORMAL * max(nm.z, 0.25)
			);
		}

		if (limb_darkening > 0.0) {
			float ndv = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
			ALBEDO *= 1.0 - limb_darkening * (1.0 - ndv);
		}

		if (has_emissive) {
			// Night lights fade in across dusk, between the gate thresholds
			// (ascending edges because GLSL leaves descending-edge smoothstep
			// undefined). With an atmosphere the band is derived from its
			// scale height, so lights and sky agree at the terminator.
			vec3 sun_view = normalize(
				(VIEW_MATRIX * vec4(planet_sun_direction, 0.0)).xyz
			);
			float night = 1.0 - smoothstep(night_gate_lo, night_gate_hi, dot(NORMAL, sun_view));
			EMISSION = texture(emissive_tex, uv).rgb * emissive_tint
				* night * emissive_energy;
		}
	}
}
