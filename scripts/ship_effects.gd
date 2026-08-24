class_name ShipEffects extends Node3D
## Engine light and RCS puffs (Track FX): the visible consequence of thrust.
##
## Reads the ship's commanded per-axis thrust and torque (fx_thrust_local /
## fx_torque_local — written by the controller where forces are applied, and
## by the autopilot during a cruise) and drives GPUParticles3D emitters plus
## a stern engine light. Every emitter fires OPPOSITE the thrust it produces,
## from the face the real thruster would sit on; torque lights opposed pairs
## at the nose and tail. Flight-assist counter-burns are real firings and
## show up like any other.
##
## All particles run in LOCAL space: the hull station-keeps at ~131 m/s, so
## world-space exhaust would streak out of frame within a frame. Physically
## the plume IS left behind — readability wins here.
##
## AudioManager hooks: thruster loops belong beside each emitter's activity
## flip (note_event on main-engine ignition/cutoff, puff one-shots for RCS).
## No audio assets yet — the M2 convention.

## Threshold below which a commanded axis is treated as engines-off — the
## flight assist trickles a few newtons holding station, which should not
## strobe the thrusters.
const DEADBAND_N: float = 400.0
const DEADBAND_NM: float = 300.0

var _ship: RigidBody3D
## name -> GPUParticles3D
var _emitters: Dictionary = {}
var _engine_light: OmniLight3D
var _thrust_main: float = 48000.0
var _thrust_rcs: float = 15000.0
var _max_torque: float = 20000.0


func _ready() -> void:
	_ship = get_parent() as RigidBody3D
	if _ship == null:
		return
	_thrust_main = float(_ship.get("thrust_main"))
	_thrust_rcs = float(_ship.get("thrust_rcs"))
	_max_torque = float(_ship.get("max_torque"))

	# Main engine: big plume aft, firing +Z (exhaust back = thrust forward).
	_emitters["main"] = _plume(Vector3(0, 0, 7.2), Vector3(0, 0, 1), 1.1, 22.0, 64, 0.45)
	_engine_light = OmniLight3D.new()
	_engine_light.name = "EngineLight"
	_engine_light.position = Vector3(0, 0, 8.0)
	_engine_light.light_color = Color(0.62, 0.78, 1.0)
	_engine_light.omni_range = 20.0
	_engine_light.light_energy = 0.0
	add_child(_engine_light)

	# Face RCS: one puff emitter per face, expelling outward. Which face fires
	# for which command: gas out of the -X face pushes the hull +X, and so on.
	# The -Y face doubles as the belly landing jets (main budget in shells),
	# so it gets a plume-sized emitter rather than a puff.
	_emitters["nose"] = _plume(Vector3(0, 0, -7.2), Vector3(0, 0, -1), 0.7, 7.0, 16, 0.3)
	_emitters["left"] = _plume(Vector3(-3.6, 0, 0), Vector3(-1, 0, 0), 0.7, 7.0, 16, 0.3)
	_emitters["right"] = _plume(Vector3(3.6, 0, 0), Vector3(1, 0, 0), 0.7, 7.0, 16, 0.3)
	_emitters["top"] = _plume(Vector3(0, 1.8, 0), Vector3(0, 1, 0), 0.7, 7.0, 16, 0.3)
	_emitters["belly"] = _plume(Vector3(0, -1.8, 0), Vector3(0, -1, 0), 0.8, 14.0, 40, 0.35)

	# Torque puffs: opposed pairs. Pitch/yaw at the nose and tail, roll at the
	# wingtips. Named <where>_<expel-direction>.
	_emitters["nose_up"] = _plume(Vector3(0, 0.9, -6.5), Vector3(0, 1, 0), 0.5, 5.0, 12, 0.25)
	_emitters["nose_down"] = _plume(Vector3(0, -0.9, -6.5), Vector3(0, -1, 0), 0.5, 5.0, 12, 0.25)
	_emitters["nose_l"] = _plume(Vector3(-0.9, 0, -6.5), Vector3(-1, 0, 0), 0.5, 5.0, 12, 0.25)
	_emitters["nose_r"] = _plume(Vector3(0.9, 0, -6.5), Vector3(1, 0, 0), 0.5, 5.0, 12, 0.25)
	_emitters["tail_up"] = _plume(Vector3(0, 0.9, 6.5), Vector3(0, 1, 0), 0.5, 5.0, 12, 0.25)
	_emitters["tail_down"] = _plume(Vector3(0, -0.9, 6.5), Vector3(0, -1, 0), 0.5, 5.0, 12, 0.25)
	_emitters["tail_l"] = _plume(Vector3(-0.9, 0, 6.5), Vector3(-1, 0, 0), 0.5, 5.0, 12, 0.25)
	_emitters["tail_r"] = _plume(Vector3(0.9, 0, 6.5), Vector3(1, 0, 0), 0.5, 5.0, 12, 0.25)
	_emitters["wing_l_up"] = _plume(Vector3(-4.0, 0.6, 0), Vector3(0, 1, 0), 0.5, 5.0, 12, 0.25)
	_emitters["wing_l_down"] = _plume(Vector3(-4.0, -0.6, 0), Vector3(0, -1, 0), 0.5, 5.0, 12, 0.25)
	_emitters["wing_r_up"] = _plume(Vector3(4.0, 0.6, 0), Vector3(0, 1, 0), 0.5, 5.0, 12, 0.25)
	_emitters["wing_r_down"] = _plume(Vector3(4.0, -0.6, 0), Vector3(0, -1, 0), 0.5, 5.0, 12, 0.25)


func _process(_delta: float) -> void:
	if _ship == null:
		return
	var t: Vector3 = _ship.get("fx_thrust_local")
	var q: Vector3 = _ship.get("fx_torque_local")
	apply_signals(t, q)


## Pure mapping from commanded thrust/torque to emitter activity — separated
## so the FX gates can drive it directly with authored vectors.
func apply_signals(t: Vector3, q: Vector3) -> void:
	# Main engine: forward burn only (z negative). Light and plume scale with
	# throttle.
	var main_throttle: float = clampf(-t.z / _thrust_main, 0.0, 1.0) if t.z < -DEADBAND_N else 0.0
	_drive(_emitters["main"], main_throttle > 0.0, main_throttle)
	_engine_light.light_energy = main_throttle * 8.0

	# Translation faces: expel opposite the push.
	_drive(_emitters["nose"], t.z > DEADBAND_N, clampf(t.z / _thrust_rcs, 0.0, 1.0))
	_drive(_emitters["left"], t.x > DEADBAND_N, clampf(t.x / _thrust_rcs, 0.0, 1.0))
	_drive(_emitters["right"], t.x < -DEADBAND_N, clampf(-t.x / _thrust_rcs, 0.0, 1.0))
	_drive(_emitters["top"], t.y < -DEADBAND_N, clampf(-t.y / _thrust_rcs, 0.0, 1.0))
	# Belly doubles as the landing jets: normalize against the main budget so
	# a hover burn reads as the serious engine it is.
	_drive(_emitters["belly"], t.y > DEADBAND_N, clampf(t.y / _thrust_main, 0.0, 1.0))

	# Torque: +X pitch up (nose rises: expel down at nose, up at tail);
	# +Y yaw left (nose goes -X: expel +X at nose, -X at tail);
	# +Z roll left (left wing down: expel down on left wingtip, up on right).
	var pitch: float = q.x / _max_torque
	var yaw: float = q.y / _max_torque
	var roll: float = q.z / _max_torque
	_pair("nose_down", "tail_up", pitch)
	_pair("nose_up", "tail_down", -pitch)
	_pair("nose_r", "tail_l", yaw)
	_pair("nose_l", "tail_r", -yaw)
	_pair("wing_l_down", "wing_r_up", roll)
	_pair("wing_l_up", "wing_r_down", -roll)


func _pair(a: String, b: String, strength: float) -> void:
	var on: bool = strength * _max_torque > DEADBAND_NM
	var s: float = clampf(strength, 0.0, 1.0)
	_drive(_emitters[a], on, s)
	_drive(_emitters[b], on, s)


func _drive(p: GPUParticles3D, on: bool, strength: float) -> void:
	p.emitting = on
	p.amount_ratio = clampf(maxf(strength, 0.25), 0.0, 1.0) if on else 1.0


func emitter_on(name: String) -> bool:
	return _emitters.has(name) and (_emitters[name] as GPUParticles3D).emitting


## One exhaust emitter: a cone of additive billboard sparks expelled along
## `dir` from `pos`, hull-local.
func _plume(pos: Vector3, dir: Vector3, size: float, speed: float, amount: int, life: float) -> GPUParticles3D:
	var pm := ParticleProcessMaterial.new()
	pm.direction = dir
	pm.spread = 7.0
	pm.initial_velocity_min = speed * 0.7
	pm.initial_velocity_max = speed
	pm.gravity = Vector3.ZERO
	pm.scale_min = 0.6
	pm.scale_max = 1.0
	var ramp := Gradient.new()
	ramp.set_color(0, Color(0.85, 0.93, 1.0, 0.9))
	ramp.set_color(1, Color(0.45, 0.62, 1.0, 0.0))
	var ramp_tex := GradientTexture1D.new()
	ramp_tex.gradient = ramp
	pm.color_ramp = ramp_tex

	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color(1, 1, 1)
	# A radial falloff so each particle is a soft glow, not a hard quad —
	# untextured additive quads read as literal white squares.
	var spot := GradientTexture2D.new()
	spot.fill = GradientTexture2D.FILL_RADIAL
	spot.fill_from = Vector2(0.5, 0.5)
	spot.fill_to = Vector2(0.5, 0.0)
	var spot_grad := Gradient.new()
	spot_grad.set_color(0, Color(1, 1, 1, 1))
	spot_grad.add_point(0.55, Color(1, 1, 1, 0.35))
	spot_grad.set_color(spot_grad.get_point_count() - 1, Color(1, 1, 1, 0))
	spot.gradient = spot_grad
	spot.width = 64
	spot.height = 64
	mat.albedo_texture = spot
	quad.material = mat

	var p := GPUParticles3D.new()
	p.process_material = pm
	p.draw_pass_1 = quad
	p.local_coords = true
	p.amount = amount
	p.lifetime = life
	p.emitting = false
	p.position = pos
	add_child(p)
	return p
