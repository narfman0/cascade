shader_type sky;
render_mode use_half_res_pass;

// Procedural starfield.
//
// Written rather than textured because the asset server has no orbital sky: both
// panoramas in its `_skies` pack are terrestrial daylight gradients with a hard
// horizon. A generated field also costs no memory, never seams, and stays sharp
// at any FOV — and it lets the star density be tuned for tone rather than
// inherited from someone else's skybox.
//
// Stars are placed one per cell of a 3D grid over the view direction, so they sit
// at fixed points on the celestial sphere. The 3×3×3 neighbourhood sweep is what
// keeps a star from being clipped at a cell boundary.

uniform vec3 space_color : source_color = vec3(0.0015, 0.0018, 0.0035);
uniform float star_scale = 160.0;
// Fraction of cells that contain no star. Higher is emptier.
uniform float star_sparsity : hint_range(0.9, 0.999) = 0.972;
uniform float star_intensity = 2.2;
// Second, denser layer of fainter stars for depth.
uniform float faint_scale = 430.0;
uniform float faint_sparsity : hint_range(0.9, 0.999) = 0.988;

// The REAL sky (Track SL6): the Yale Bright Star Catalog baked to an equirect
// panorama by tools/cook_planet_maps.py --only stars, Milky Way included,
// oriented so the celestial pole sits over Earth's spin axis — Orion, the
// Dipper and the Southern Cross are findable. When present it replaces the
// invented bright layer; the procedural faint layer stays as the sub-catalog
// floor (the real sky continues below magnitude 6.5, it just has no names).
uniform sampler2D star_map : source_color, filter_linear_mipmap, repeat_enable;
uniform bool star_map_ok = false;
uniform float star_map_gain = 2.4;

float hash1(vec3 p) {
	return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453123);
}

vec3 star_layer(vec3 dir, float scale, float sparsity, float intensity) {
	vec3 sp = dir * scale;
	vec3 cell = floor(sp);
	vec3 frac = sp - cell;
	vec3 acc = vec3(0.0);
	for (int x = -1; x <= 1; x++) {
		for (int y = -1; y <= 1; y++) {
			for (int z = -1; z <= 1; z++) {
				vec3 neighbour = vec3(float(x), float(y), float(z));
				vec3 c = cell + neighbour;
				float h = hash1(c);
				if (h < sparsity) {
					continue;
				}
				// Random position inside the cell, so the grid never reads as one.
				vec3 offset = vec3(hash1(c + 11.0), hash1(c + 23.0), hash1(c + 37.0));
				float d = length(frac - (neighbour + offset));
				// Magnitude: rescale the tail above the sparsity cut so most stars
				// are dim and a few are bright.
				float mag = (h - sparsity) / max(1.0 - sparsity, 0.0001);
				float point = exp(-d * d * 110.0) * pow(mag, 1.6) * intensity;
				// Stellar colour: cool blue-white through warm.
				float warm = hash1(c + 53.0);
				acc += point * mix(vec3(0.78, 0.85, 1.0), vec3(1.0, 0.88, 0.72), warm);
			}
		}
	}
	return acc;
}

void sky() {
	vec3 dir = normalize(EYEDIR);
	vec3 col = space_color;
	if (star_map_ok) {
		float lon = atan(dir.z, dir.x);
		float lat = asin(clamp(dir.y, -1.0, 1.0));
		vec2 uv = vec2(0.5 + lon / TAU, 0.5 - lat / PI);
		col += texture(star_map, uv).rgb * star_map_gain;
	} else {
		col += star_layer(dir, star_scale, star_sparsity, star_intensity);
	}
	col += star_layer(dir, faint_scale, faint_sparsity, star_intensity * 0.45);
	COLOR = col;
}
