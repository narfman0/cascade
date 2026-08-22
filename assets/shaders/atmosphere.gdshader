shader_type spatial;
render_mode blend_mix, depth_draw_never, depth_test_disabled, cull_front, unshaded, fog_disabled;

// Atmosphere shell (PR4): per-pixel single-scatter march with precomputed
// multiple scattering (Hillaire 2020). Two LUTs, baked per body on a worker by
// AtmosphereMath and identical to its CPU mirror:
//   transmittance_lut  — optical depth to space over (altitude, zenith angle),
//                        Bruneton's non-linear mapping so the horizon keeps
//                        precision (the limb is the money pixel);
//   ms_lut             — Hillaire's psi_ms over (sun angle, altitude), orders
//                        2..inf with isotropic phase.
//
// The mesh is a unit sphere scaled to radius*(1+height_fraction), back-face
// rendered with depth testing off, so the march runs whether the camera is
// outside the shell (orbit) or inside it (skim) — the same code path, which is
// what the design doc demands ("altitude-correct camera").
//
// ALL march math happens in planet-radius units: world positions are divided
// by the drawn radius, which is recovered from MODEL_MATRIX. That single
// normalization is why the proxy clamp needs no special handling here — when
// CelestialBody scales the body down at range, the shell scales through the
// same path and the optics are unchanged (ratios, not absolutes).
//
// Aerial perspective is the same march, clamped at the scene depth buffer: the
// in-scatter accumulates in front of the terrain and the transmittance
// extinguishes it, which is also what composites city lights correctly —
// they read through thin air and die in thick (composite-order requirement).

global uniform vec3 planet_sun_direction;

uniform sampler2D transmittance_lut : filter_linear, repeat_disable;
uniform sampler2D ms_lut : filter_linear, repeat_disable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform bool luts_ok = false;

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

varying vec3 v_world_pos;


void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}


float rayleigh_phase(float c) {
	return 3.0 / (16.0 * PI) * (1.0 + c * c);
}


// Cornette-Shanks per channel; per-channel g is what lets Mars put blue in a
// tighter forward lobe than red (its blue sunset — see BodyAtmosphere).
vec3 cs_phase(float c, vec3 g) {
	vec3 g2 = g * g;
	vec3 den = (2.0 + g2) * pow(max(vec3(1.0) + g2 - 2.0 * g * c, vec3(1e-6)), vec3(1.5));
	return 3.0 / (8.0 * PI) * ((1.0 - g2) * (1.0 + c * c)) / den;
}


// Transmittance toward space from radius r along zenith cosine mu. Must match
// AtmosphereMath.lut_uv_from_r_mu exactly.
vec3 sample_transmittance(float r, float mu) {
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


void fragment() {
	if (!luts_ok) {
		ALBEDO = vec3(0.0);
		ALPHA = 0.0;
	} else {
		vec3 ro = CAMERA_POSITION_WORLD;
		vec3 rd = normalize(v_world_pos - ro);
		vec3 centre = NODE_POSITION_WORLD;
		// Drawn shell radius from the model matrix — radius * (1+hf) * proxy
		// ratio — so the planet radius normalizer follows the proxy for free.
		float shell_r = length(MODEL_MATRIX[0].xyz);
		float R = shell_r / (1.0 + height_fraction);

		// Everything below runs in planet-radius units.
		vec3 o = (ro - centre) / R;
		float top = 1.0 + height_fraction;
		float b = dot(o, rd);
		float disc = b * b - (dot(o, o) - top * top);
		if (disc <= 0.0) {
			discard;
		}
		float t0 = max(-b - sqrt(disc), 0.0);
		float t1 = -b + sqrt(disc);

		// Clamp at the ground sphere: never march the planet's interior.
		float disc_g = b * b - (dot(o, o) - 1.0);
		if (disc_g > 0.0) {
			float tg = -b - sqrt(disc_g);
			if (tg > 0.0) {
				t1 = min(t1, tg);
			}
		}

		// Clamp at the scene: terrain, ship, anything opaque. This is aerial
		// perspective and correct occlusion in one clamp. Background depth is
		// 0.0 (reversed Z) and reconstructs to "infinitely far".
		float depth_raw = texture(depth_tex, SCREEN_UV).r;
		float scene_t = 1e30;
		if (depth_raw > 1e-7) {
			vec4 ndc = vec4(SCREEN_UV * 2.0 - 1.0, depth_raw, 1.0);
			vec4 vpos = INV_PROJECTION_MATRIX * ndc;
			scene_t = length(vpos.xyz / vpos.w) / R;
		}
		float t_end = min(t1, scene_t);
		if (t_end - t0 <= 1e-7) {
			discard;
		}

		vec3 sun = normalize(planet_sun_direction);
		float cos_theta = dot(rd, sun);
		float pr = rayleigh_phase(cos_theta);
		vec3 pm = cs_phase(cos_theta, mie_g);

		float dt = (t_end - t0) / float(march_steps);
		vec3 tau = vec3(0.0);
		vec3 radiance = vec3(0.0);
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
			vec3 t_view = exp(-min(tau + ext * dt * 0.5, vec3(60.0)));
			tau += ext * dt;

			float mu_s = dot(p, sun) / r;
			// Planetary shadow: below the local horizon the sun is behind the
			// planet and the night side's air must stay dark.
			float mu_horizon = -sqrt(max(r * r - 1.0, 0.0)) / r;
			vec3 t_sun = vec3(0.0);
			if (mu_s >= mu_horizon) {
				t_sun = sample_transmittance(r, mu_s);
			}
			vec2 ms_uv = vec2(
				clamp(mu_s * 0.5 + 0.5, 0.0, 1.0),
				clamp(h / height_fraction, 0.0, 1.0));
			vec3 psi = texture(ms_lut, ms_uv).rgb;
			radiance += t_view * (t_sun * (s_r * pr + s_m * pm) + psi * (s_r + s_m)) * dt;
		}
		radiance *= sun_intensity;

		vec3 t_total = exp(-min(tau, vec3(60.0)));
		// blend_mix gives out = ALBEDO*a + scene*(1-a); with a from the mean
		// transmittance and ALBEDO un-premultiplied, that is Hillaire's
		// composite L_inscatter + L_scene * T with a scalar-alpha compromise.
		float a = clamp(1.0 - dot(t_total, vec3(0.2126, 0.7152, 0.0722)), 0.0, 1.0);
		ALBEDO = radiance / max(a, 1e-4);
		ALPHA = a;
	}
}
