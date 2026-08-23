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

varying vec3 v_dir;


void vertex() {
	v_dir = normalize(VERTEX);
}


float hash3(vec3 p) {
	return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453123);
}


float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = hash3(i);
	float n100 = hash3(i + vec3(1.0, 0.0, 0.0));
	float n010 = hash3(i + vec3(0.0, 1.0, 0.0));
	float n110 = hash3(i + vec3(1.0, 1.0, 0.0));
	float n001 = hash3(i + vec3(0.0, 0.0, 1.0));
	float n101 = hash3(i + vec3(1.0, 0.0, 1.0));
	float n011 = hash3(i + vec3(0.0, 1.0, 1.0));
	float n111 = hash3(i + vec3(1.0, 1.0, 1.0));
	return mix(
		mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
		mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y),
		f.z);
}


float fbm(vec3 p) {
	float amp = 0.5;
	float sum = 0.0;
	for (int i = 0; i < 4; i++) {
		sum += amp * vnoise(p);
		p *= 2.13;
		amp *= 0.5;
	}
	return sum;
}


void fragment() {
	vec3 p = v_dir * noise_scale
		+ vec3(TIME * drift_speed, 0.0, TIME * drift_speed * 0.6);
	float c = fbm(p);
	float a;
	if (has_coverage_map) {
		float lon = atan(v_dir.z, v_dir.x);
		float lat = asin(clamp(v_dir.y, -1.0, 1.0));
		vec2 uv = vec2(0.5 + lon / TAU, 0.5 - lat / PI);
		// Lift the composite's mid tones a touch, then let the noise break
		// the fields up. Deserts (fraction ~0) can never reach the cut.
		float base = pow(texture(coverage_map, uv).r, 0.7);
		float d = base * (0.5 + 0.62 * c);
		float cut = mix(0.42, 0.22, coverage);
		a = smoothstep(cut, cut + 0.1, d);
	} else {
		// Purely procedural deck (bodies without climatology data). A
		// hard-ish threshold gives distinct fields with clear gaps — a wide
		// soft window reads as a milky veil that washes out the ocean.
		float cut = mix(0.68, 0.42, coverage);
		a = smoothstep(cut, cut + 0.11, c);
	}
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
