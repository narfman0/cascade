shader_type spatial;
render_mode unshaded, fog_disabled;

// The Sun's disc. The old flat emissive StandardMaterial tonemapped to a
// featureless cream circle; a real solar disc is limb-darkened — brightest at
// centre, falling toward the edge — and pushing the centre well past the
// tonemap white point is what lets the environment glow bloom it into a star
// instead of a sticker.

uniform vec3 tint : source_color = vec3(1.0, 0.93, 0.75);
uniform float core_energy = 26.0;
uniform float edge_energy = 6.0;
uniform float limb_power = 0.55;


void fragment() {
	float mu = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float limb = pow(mu, limb_power);
	// Unshaded mode outputs ALBEDO as the final HDR colour and IGNORES
	// EMISSION — writing the energy there rendered the disc black, which hid
	// behind the glare until the disc shrank to true scale (Track SL2).
	ALBEDO = tint * mix(edge_energy, core_energy, limb);
}
