// Ground detail (Track TF phase 2b): what the boots see.
//
// The albedo is 3 m/texel — underfoot it is a blur of giant pixels. This adds
// procedural micro-detail in the FRAGMENT stage from body-local position:
// 3D value noise, so there are no UVs, no seams, no tiling repeats and no new
// textures in the package. Two products:
//   gd_albedo_mul — a brightness modulation (patchy regolith / soil / rock)
//   gd_normal     — a micro-normal perturbation for close-range shading
// Both fade to exactly zero past gd_far, so every orbital view is untouched
// bit-for-bit; only the walking/landing range changes.
//
// Naming is gd_-prefixed throughout — include-parameter shadowing of consumer
// uniforms is a compile error (the cf_ lesson from cloud_field).

float gd_hash(vec3 p) {
	p = fract(p * 0.3183099 + vec3(0.1, 0.17, 0.13));
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float gd_vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(mix(gd_hash(i), gd_hash(i + vec3(1, 0, 0)), f.x),
			mix(gd_hash(i + vec3(0, 1, 0)), gd_hash(i + vec3(1, 1, 0)), f.x), f.y),
		mix(mix(gd_hash(i + vec3(0, 0, 1)), gd_hash(i + vec3(1, 0, 1)), f.x),
			mix(gd_hash(i + vec3(0, 1, 1)), gd_hash(i + vec3(1, 1, 1)), f.x), f.y),
		f.z);
}

float gd_fbm(vec3 p) {
	float a = 0.5;
	float v = 0.0;
	for (int i = 0; i < 3; i++) {
		v += a * gd_vnoise(p);
		p = p * 2.17 + vec3(11.3);
		a *= 0.5;
	}
	return v;  // ~[0.05, 0.85], mean ~0.45
}

// p_m: stable body-local position in metres. dist_m: camera distance.
// Returns the albedo multiplier; writes a world-tangent gradient into
// gd_grad for the caller to fold into its normal.
float gd_detail(vec3 p_m, vec3 up, float dist_m, float strength, out vec3 gd_grad) {
	gd_grad = vec3(0.0);
	// Fade band: full inside 60 m, gone by 350 m — landing flare through
	// walking range, invisible from orbit and in every legacy screenshot.
	float fade = 1.0 - smoothstep(60.0, 350.0, dist_m);
	if (fade <= 0.0) {
		return 1.0;
	}
	// Two scales: ~1.6 m patches (soil variation) and ~0.35 m speckle.
	float patches = gd_fbm(p_m * 0.6);
	float speckle = gd_vnoise(p_m * 2.9);
	float n = (patches - 0.45) * 0.8 + (speckle - 0.5) * 0.35;
	// Micro-normal: numerical gradient of the patch noise in the tangent
	// plane, cheap central-difference-lite (two extra taps).
	float e = 0.35;
	vec3 t1 = normalize(cross(up, abs(up.y) < 0.9 ? vec3(0, 1, 0) : vec3(1, 0, 0)));
	vec3 t2 = cross(up, t1);
	float dx = gd_fbm((p_m + t1 * e) * 0.6) - patches;
	float dy = gd_fbm((p_m + t2 * e) * 0.6) - patches;
	gd_grad = (t1 * dx + t2 * dy) * fade;
	return 1.0 + n * strength * fade;
}
