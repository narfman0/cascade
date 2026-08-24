extends Node
## Frame arbitrary (lat, lon) places on Earth and screenshot them — the
## owner's "show me <place>" tool. Reuses the site-harness discipline: warp
## SimClock until the place is sunlit, JUMP THE SHIP WITH THE BODY (the warp
## moves Earth hundreds of km; a ship left behind chases a proxy — the
## _frame_site bug), then hold the pose per frame while the quadtree and the
## L2 tiles settle, and re-centre before the shot.
##
## Run: xvfb-run -a godot res://tests/capture_places.tscn
## Edit PLACES for different framings; altitude picks the field of view
## (span on the ground is roughly 1.5x the altitude at the default FOV).

const OUT_DIR: String = "user://shots"

## name, lat, lon, altitude above the datum (metres), target sun elevation
## (dot of surface normal with the sun direction), aim yaw off nadir (deg).
const PLACES: Array = [
	["australia", -25.0, 134.0, 1250.0, 0.75, 20.0],
	["france", 46.5, 2.5, 420.0, 0.65, 20.0],
	["norfolk_virginia", 36.85, -76.29, 160.0, 0.6, 18.0],
]

var _system: SolarSystem
var _ship: RigidBody3D
var _earth: CelestialBody


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var world: Node3D = load("res://scenes/game_world.tscn").instantiate()
	add_child(world)
	for _i in 8:
		await get_tree().process_frame
	_system = world.get_node("SolarSystem")
	_ship = world.get_node("Ship")
	_earth = _system.get_body(&"earth")
	_ship.freeze = true
	GameState.flight_assist_enabled = false

	# Textures first, or the first place renders on the flat-colour fallback.
	var surface := _earth.planet_surface()
	var deadline: int = Time.get_ticks_msec() + 60000
	while not surface.textures_ready and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame

	for place in PLACES:
		await _frame_place(place[1], place[2], place[3], place[4], place[5])
		await _shot("place_%s" % place[0])

	print("shots written to %s" % ProjectSettings.globalize_path(OUT_DIR))
	get_tree().quit()


## Surface-local unit direction of (lat, lon) — DetailSite.direction's math.
func _local_dir(lat_deg: float, lon_deg: float) -> Vector3:
	var lat := deg_to_rad(lat_deg)
	var lon := deg_to_rad(lon_deg)
	return Vector3(cos(lat) * cos(lon), sin(lat), cos(lat) * sin(lon))


func _frame_place(
	lat: float, lon: float, altitude: float, sun_elev: float, yaw_deg: float
) -> void:
	var surface := _earth.planet_surface()
	var base := _local_dir(lat, lon)

	# Find the sim time that puts the place at the wanted sun elevation.
	var period: float = _earth.def.spin_period
	var axis := Vector3(
		0.0, cos(_earth.def.spin_axis_tilt), sin(_earth.def.spin_axis_tilt)).normalized()
	var best_t: float = SimClock.sim_time
	var best_err: float = 1e9
	for step in 720:
		var t: float = SimClock.sim_time + period * float(step) / 720.0
		var spun: Vector3 = Basis(axis, fposmod(TAU * (t / period), TAU)) * base
		var err: float = absf(spun.dot(_sun_dir_at(t)) - sun_elev)
		if err < best_err:
			best_err = err
			best_t = t
	SimClock.sim_time = best_t
	for _i in 4:
		await get_tree().physics_frame

	# Jump with the body (see header), then hold, settle, re-centre.
	var jump_dir: Vector3 = (surface.global_transform.basis * base).normalized()
	_ship.global_position = OriginShift.to_render(_earth.true_pos) \
		+ jump_dir * (_earth.def.radius + altitude)
	await get_tree().physics_frame

	var resolve := func() -> Array:
		var centre: Vector3 = OriginShift.to_render(_earth.true_pos)
		var b: Basis = surface.global_transform.basis
		var up: Vector3 = (b * base).normalized()
		var north: Vector3 = (b * _local_dir(lat + 5.0, lon)).normalized()
		north = (north - up * up.dot(north)).normalized()
		var where: Vector3 = centre + up * (_earth.def.radius + altitude)
		# Yaw the nadir aim about local north so the place is not hidden
		# behind the hull (the rig centres the ship in frame).
		var aim: Vector3 = (-up).rotated(north, deg_to_rad(yaw_deg))
		return [where, where + aim * altitude, north]
	await _hold_pose(resolve)
	await _settle(surface)
	await _hold_pose(resolve)


func _sun_dir_at(t: float) -> Vector3:
	var ep: Array = _earth.position_at(t)
	var sp: Array = _system.get_body(&"sun").position_at(t)
	return Vector3(
		float(sp[0] - ep[0]), float(sp[1] - ep[1]), float(sp[2] - ep[2])).normalized()


## Hold the ship at a pose until the camera rig converges (capture_planet_shots'
## loop): resolve is re-called every frame because the planet spins and Earth
## co-moves under the frozen ship the whole time.
func _hold_pose(resolve: Callable) -> void:
	var cam := get_viewport().get_camera_3d()
	var deadline: int = Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline:
		var pose: Array = resolve.call()
		var where: Vector3 = pose[0]
		var up: Vector3 = pose[2]
		var dir: Vector3 = (pose[1] as Vector3) - where
		if dir.length() < 1.0:
			return
		if absf(dir.normalized().dot(up)) > 0.99:
			up = Vector3.RIGHT
		_ship.global_position = where
		_ship.look_at(pose[1], up)
		await get_tree().physics_frame
		if cam == null:
			break
		if cam.global_position.distance_to(_ship.to_global(_ship.get_node("CameraRig").third_person_offset)) < 1.0:
			break
	for _i in 20:
		await get_tree().process_frame


## Settle until refinement stops changing (capture_planet_shots' rule).
func _settle(surface: PlanetSurface) -> void:
	var previous := {}
	var stable: int = 0
	var deadline: int = Time.get_ticks_msec() + 30000
	while stable < 3 and Time.get_ticks_msec() < deadline:
		surface.force_evaluate()
		await get_tree().process_frame
		if not surface.is_quiescent():
			stable = 0
			continue
		var now: Dictionary = surface.stats()
		if previous.size() > 0 and now["leaves"] == previous["leaves"] \
				and now["max_depth"] == previous["max_depth"]:
			stable += 1
		else:
			stable = 0
		previous = now


func _shot(label: String) -> void:
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	image.save_png("%s/%s.png" % [OUT_DIR, label])
	print("  wrote %s" % label)
