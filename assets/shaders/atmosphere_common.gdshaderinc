// Shared core of the atmosphere shell (PR4, split two-pass at Track SL4).
//
// Two passes render the same back-face shell mesh: an extinction pass
// (blend_mul — multiplies the scene by per-channel transmittance) and an
// in-scatter pass (blend_add). Splitting removes the old scalar-alpha
// compromise outright: the sun setting through the limb now reddens and dims
// per channel, and city lights keep their colour through thin air. Both
// passes march the identical ray — this include is that ray, so the two can
// never disagree.
//
// Everything below matches AtmosphereMath (the CPU mirror the gate tests
// assert against) — see atmosphere.gdshader's original header for the
// LUT/geometry story. All march math runs in planet-radius units.

uniform sampler2D transmittance_lut : filter_linear, repeat_disable;
uniform sampler2D ms_lut : filter_linear, repeat_disable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform bool luts_ok = false;

// Sun direction as seen from THIS body (Track SL5), world space.
uniform vec3 body_sun_dir = vec3(0.0, 0.0, 1.0);

uniform float height_fraction = 0.025;
uniform vec3 rayleigh_scatter = vec3(37.0, 86.4, 210.9);
uniform float rayleigh_h = 0.00133;
uniform vec3 mie_scatter = vec3(25.4);
uniform vec3 mie_absorb = vec3(2.8);
uniform float mie_h = 0.00019;
uniform vec3 mie_g = vec3(0.76);
uniform vec3 ozone_absorb = vec3(4.14, 11.98, 0.54);
uniform float ozone_center = 0.0039;
uniform float ozone_width = 0.0024;
uniform float sun_intensity = 25.0;
uniform int march_steps = 32;


float atmo_rayleigh_phase(float c) {
	return 3.0 / (16.0 * PI) * (1.0 + c * c);
}


vec3 atmo_cs_phase(float c, vec3 g) {
	vec3 g2 = g * g;
	vec3 den = (2.0 + g2) * pow(max(vec3(1.0) + g2 - 2.0 * g * c, vec3(1e-6)), vec3(1.5));
	return 3.0 / (8.0 * PI) * ((1.0 - g2) * (1.0 + c * c)) / den;
}


// Transmittance toward space from radius r along zenith cosine mu. Must match
// AtmosphereMath.lut_uv_from_r_mu exactly.
vec3 atmo_sample_transmittance(float r, float mu) {
	float top = 1.0 + height_fraction;
	float big_h = sqrt(max(top * top - 1.0, 1e-12));
	float rho = sqrt(max(r * r - 1.0, 0.0));
	float d = max(-r * mu + sqrt(max(r * r * (mu * mu - 1.0) + top * top, 0.0)), 0.0);
	float d_min = top - r;
	float d_max = rho + big_h;
	float u = clamp((d - d_min) / max(d_max - d_min, 1e-12), 0.0, 1.0);
	float v = clamp(rho / big_h, 0.0, 1.0);
	return texture(transmittance_lut, vec2(u, v)).rgb;
}


// The shared ray: camera -> scene depth, clamped at the ground sphere, in
// planet-radius units. Returns false when the ray misses the shell entirely
// (caller discards — a no-op for both blend modes). `want_l` false skips the
// in-scatter work for the cheaper extinction pass.
bool atmo_trace(
	vec3 ro, vec3 rd, vec3 centre, float shell_scale, float depth_raw,
	vec2 screen_uv, mat4 inv_proj, bool want_l,
	out vec3 out_tau, out vec3 out_l
) {
	out_tau = vec3(0.0);
	out_l = vec3(0.0);
	float radius = shell_scale / (1.0 + height_fraction);
	vec3 o = (ro - centre) / radius;
	float top = 1.0 + height_fraction;
	float b = dot(o, rd);
	float disc = b * b - (dot(o, o) - top * top);
	if (disc <= 0.0) {
		return false;
	}
	float t0 = max(-b - sqrt(disc), 0.0);
	float t1 = -b + sqrt(disc);

	float disc_g = b * b - (dot(o, o) - 1.0);
	if (disc_g > 0.0) {
		float tg = -b - sqrt(disc_g);
		if (tg > 0.0) {
			t1 = min(t1, tg);
		}
	}

	// Scene clamp: aerial perspective and correct occlusion in one. Reversed-Z
	// background reconstructs to "infinitely far".
	float scene_t = 1e30;
	if (depth_raw > 1e-7) {
		vec4 ndc = vec4(screen_uv * 2.0 - 1.0, depth_raw, 1.0);
		vec4 vpos = inv_proj * ndc;
		scene_t = length(vpos.xyz / vpos.w) / radius;
	}
	float t_end = min(t1, scene_t);
	if (t_end - t0 <= 1e-7) {
		return false;
	}

	vec3 sun = normalize(body_sun_dir);
	float cos_theta = dot(rd, sun);
	float pr = atmo_rayleigh_phase(cos_theta);
	vec3 pm = atmo_cs_phase(cos_theta, mie_g);

	float dt = (t_end - t0) / float(march_steps);
	for (int i = 0; i < march_steps; i++) {
		float t = t0 + (float(i) + 0.5) * dt;
		vec3 p = o + rd * t;
		float r = length(p);
		float h = max(r - 1.0, 0.0);
		float dr_ = exp(-h / rayleigh_h);
		float dm_ = exp(-h / mie_h);
		float dz_ = max(0.0, 1.0 - abs(h - ozone_center) / ozone_width);
		vec3 s_r = rayleigh_scatter * dr_;
		vec3 s_m = mie_scatter * dm_;
		vec3 ext = s_r + s_m + mie_absorb * dm_ + ozone_absorb * dz_;
		if (want_l) {
			vec3 t_view = exp(-min(out_tau + ext * dt * 0.5, vec3(60.0)));
			float mu_s = dot(p, sun) / r;
			float mu_horizon = -sqrt(max(r * r - 1.0, 0.0)) / r;
			vec3 t_sun = vec3(0.0);
			if (mu_s >= mu_horizon) {
				t_sun = atmo_sample_transmittance(r, mu_s);
			}
			vec2 ms_uv = vec2(
				clamp(mu_s * 0.5 + 0.5, 0.0, 1.0),
				clamp(h / height_fraction, 0.0, 1.0));
			vec3 psi = texture(ms_lut, ms_uv).rgb;
			out_l += t_view * (t_sun * (s_r * pr + s_m * pm) + psi * (s_r + s_m)) * dt;
		}
		out_tau += ext * dt;
	}
	out_l *= sun_intensity;
	return true;
}
