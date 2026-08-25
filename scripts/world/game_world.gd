extends Node3D
## GameWorld bootstrap — wires the solar system, the ship, and the origin.
##
## Order matters here, and it is the one piece of sequencing worth reading before
## touching anything:
##
## 1. SolarSystem builds and positions its bodies (it does this in its own
##    `_ready`, which runs before this node's because children come first).
## 2. The render origin is *initialised* — not shifted — to the spawn point in low
##    Earth orbit. Nothing has been placed yet, so authored scene positions in
##    this file are read as offsets from that point. This is why the debris field
##    authored around (0,0,0) ends up in orbit rather than inside the Sun.
## 3. The ship is placed, given Earth's orbital velocity so it starts station-
##    keeping instead of immediately falling behind, and registered as the node
##    the floating origin tracks.

@onready var _system: SolarSystem = $SolarSystem
@onready var _ship: RigidBody3D = $Ship
@onready var _debris_anchor: OrbitalAnchor = $DebrisField

## Body the session starts at.
@export var spawn_body_id: StringName = &"earth"

## Direction from the body's centre to the spawn point. Offset toward the Sun-lit
## side so the first thing the player sees is a lit planet, not a black disc.
@export var spawn_direction: Vector3 = Vector3(-1.0, 0.32, 0.1)


func _ready() -> void:
	var spawn_true := _spawn_true_position()

	# Establish render origin BEFORE placing anything (see note above).
	OriginShift.initialize_origin(spawn_true)

	# Now the bodies can be placed: they need the origin to exist first.
	_system.refresh()

	_place_ship(spawn_true)
	_wire_systems()


func _spawn_true_position() -> Array:
	var body := _system.get_body(spawn_body_id)
	if body == null:
		push_error("GameWorld: spawn body '%s' not found." % spawn_body_id)
		return [0.0, 0.0, 0.0]
	# Ask for the analytic position rather than the cached one: nothing has been
	# placed yet, so `true_pos` is not populated at this point in the bootstrap.
	var centre: Array = body.position_at(SimClock.sim_time)
	var dir: Vector3 = spawn_direction.normalized()
	var altitude: float = SolarSystemData.SPAWN_ALTITUDE
	return [
		centre[0] + dir.x * altitude,
		centre[1] + dir.y * altitude,
		centre[2] + dir.z * altitude,
	]


func _place_ship(spawn_true: Array) -> void:
	_ship.global_position = OriginShift.to_render(spawn_true)
	# Match the spawn body's orbital velocity: at this compressed scale Earth moves
	# at ~130 m/s, and a ship that ignored that would drift out of its own orbit.
	_ship.linear_velocity = _system.reference_velocity(spawn_true)
	# Point the nose along the orbit with the planet off to one side, so the first
	# frame shows a lit limb rather than a wall of dirt or empty space.
	var body := _system.get_body(spawn_body_id)
	if body == null:
		return
	var to_body := OriginShift.to_render(body.true_pos) - _ship.global_position
	if to_body.length() < 1.0:
		return
	var to_body_dir := to_body.normalized()
	var along_orbit := to_body_dir.cross(Vector3.UP)
	if along_orbit.length() < 0.01:
		along_orbit = to_body_dir.cross(Vector3.RIGHT)
	# Blend the two: looking straight down at the planet fills the screen with
	# dirt, looking straight along the orbit puts it exactly abeam and off-screen.
	# Roughly 40° off the limb reads as "in orbit, working".
	var facing := (along_orbit.normalized() * 0.78 + to_body_dir * 0.63).normalized()
	_ship.look_at(_ship.global_position + facing, -to_body_dir)


func _wire_systems() -> void:
	OriginShift.tracked = _ship
	_ship.set("system", _system)

	# The suit must leave the physics space before the first physics frame — a
	# RigidBody3D nested under the ship's RigidBody3D corrupts both transforms.
	if _ship.has_method("stow_character"):
		_ship.stow_character()

	var autopilot := _ship.get_node_or_null("Autopilot") as Autopilot
	if autopilot:
		autopilot.setup(_system)

	var landing := _ship.get_node_or_null("LandingComputer") as LandingComputer
	if landing:
		landing.setup(_system)

	var hazard := _ship.get_node_or_null("HazardMonitor") as HazardMonitor
	if hazard:
		hazard.setup(_system)

	var autoland := _ship.get_node_or_null("AutolandComputer") as AutolandComputer
	if autoland:
		autoland.setup(_system)

	# Stations register after the origin exists — registration places them, so
	# doing it from a station's own _ready would race the bootstrap.
	var station := get_node_or_null("MeridianRelay") as OrbitalStation
	if station:
		_system.register_station(station)

	if _debris_anchor:
		# Park the field around the spawn point, not at an arbitrary altitude.
		_debris_anchor.body_id = spawn_body_id
		_debris_anchor.anchor_offset = spawn_direction.normalized() * SolarSystemData.SPAWN_ALTITUDE
		_debris_anchor.setup(_system)

	# The rock field (LD1): free-physics debris a few hundred metres along-track
	# from the authored props, same orbit. Sleeps on rails, wakes on approach.
	var rock_field := RockField.new()
	rock_field.name = "RockField"
	rock_field.body_id = spawn_body_id
	rock_field.anchor_offset = (
		spawn_direction.normalized() * SolarSystemData.SPAWN_ALTITUDE
		+ spawn_direction.normalized().cross(Vector3.UP).normalized() * 600.0)
	add_child(rock_field)
	rock_field.setup(_system)

	var hud := get_node_or_null("HUD")
	if hud and hud.has_method("bind_world"):
		hud.bind_world(_system, autopilot)

	# Touch controls (Track TC): only where fingers exist — or under the
	# desktop override that lets the layer be gated and screenshotted here.
	if OS.has_feature("mobile") or OS.get_environment("CASCADE_TOUCH") == "1":
		var touch := TouchInput.new()
		touch.name = "TouchInput"
		touch.setup(_ship, _system)
		add_child(touch)

	# Hand the environment to the solar system so ambient fill near an
	# atmospheric body derives from its sky instead of the old flat constant
	# (PR4 stretch). The system reads the initial values as the deep-space base.
	var world_env := get_node_or_null("Environment/WorldEnvironment") as WorldEnvironment
	if world_env:
		_system.bind_environment(world_env.environment)
		# The real sky (Track SL6): hand the cooked star panorama to the sky
		# shader. Missing file degrades to the procedural field, same rule as
		# every other cooked asset.
		var sky_mat := world_env.environment.sky.sky_material as ShaderMaterial
		if sky_mat != null and ResourceLoader.exists("res://assets/sky/starmap.png"):
			sky_mat.set_shader_parameter(
				"star_map", load("res://assets/sky/starmap.png"))
			sky_mat.set_shader_parameter("star_map_ok", true)
