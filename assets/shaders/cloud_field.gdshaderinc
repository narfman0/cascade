// The cloud FIELD — one definition of where the clouds are, shared by the
// deck shader (which draws them) and the planet surface shader (which darkens
// the ground under them). Both evaluate this on the same surface-local
// direction and the same TIME, so a shadow always sits exactly where its
// cloud is; duplicate the math in two files and the two drift apart the first
// time someone tunes one of them.

float cf_hash(vec3 p) {
	return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453123);
}


float cf_vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = cf_hash(i);
	float n100 = cf_hash(i + vec3(1.0, 0.0, 0.0));
	float n010 = cf_hash(i + vec3(0.0, 1.0, 0.0));
	float n110 = cf_hash(i + vec3(1.0, 1.0, 0.0));
	float n001 = cf_hash(i + vec3(0.0, 0.0, 1.0));
	float n101 = cf_hash(i + vec3(1.0, 0.0, 1.0));
	float n011 = cf_hash(i + vec3(0.0, 1.0, 1.0));
	float n111 = cf_hash(i + vec3(1.0, 1.0, 1.0));
	return mix(
		mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
		mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y),
		f.z);
}


float cf_fbm(vec3 p) {
	float amp = 0.5;
	float sum = 0.0;
	for (int i = 0; i < 4; i++) {
		sum += amp * cf_vnoise(p);
		p *= 2.13;
		amp *= 0.5;
	}
	return sum;
}


// Cloud opacity for a surface-local unit direction. The climatology map
// decides WHERE clouds live (storm tracks cloudy, deserts clear); the fbm
// provides texture and TIME-drifting weather. Without a map, the procedural
// threshold path (bodies with clouds but no data).
// Parameter names are cf_-prefixed: the Godot shading language rejects a
// function parameter that shadows a uniform in the INCLUDING shader, and
// both consumers have uniforms named close to these.
float cloud_field_alpha(
	vec3 cf_dir, sampler2D cf_map, bool cf_has_map, float cf_cov,
	float cf_scale, float cf_drift, float cf_time
) {
	vec3 p = cf_dir * cf_scale
		+ vec3(cf_time * cf_drift, 0.0, cf_time * cf_drift * 0.6);
	float c = cf_fbm(p);
	if (cf_has_map) {
		float lon = atan(cf_dir.z, cf_dir.x);
		float lat = asin(clamp(cf_dir.y, -1.0, 1.0));
		vec2 uv = vec2(0.5 + lon / TAU, 0.5 - lat / PI);
		float base = pow(texture(cf_map, uv).r, 0.7);
		float d = base * (0.5 + 0.62 * c);
		float cut = mix(0.42, 0.22, cf_cov);
		return smoothstep(cut, cut + 0.1, d);
	}
	float cut = mix(0.68, 0.42, cf_cov);
	return smoothstep(cut, cut + 0.11, c);
}
