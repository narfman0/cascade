extends Node
## Docking screenshot harness — approach, docked, and undock, for owner review.
##
## Run: xvfb-run -a godot res://tests/capture_docking_shots.tscn
##
## Same posing rules as capture_eva_shots.gd: the ship is posed frozen, and a
## frozen kinematic transform only commits through physics steps, so every pose
## is re-applied across physics frames — against the port's CURRENT transform,
## because the station moves ~2.6 m of render space per frame on its rail. The
## review camera is parented under the station for the same reason: a
## world-static camera loses the subject within a dozen frames. The station
## never rotates, so a child camera keeps its aim as the station translates.
##
## The approach shot is taken from the ship's own camera mid-drift at 2 m/s —
## hot on purpose, so the capture gate does not fire while the HUD approach
## readout is being photographed.

const OUT_DIR: String = "user://shots"

var _world: Node3D
var _ship: RigidBody3D
var _dc: DockingComputer
var _station: OrbitalStation
var _port: DockingPort
var _sunward: Vector3 = Vector3.RIGHT
var _review_cam: Camera3D


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	_world = load("res://scenes/game_world.tscn").instantiate()
	add_child(_world)
	await _settle(6)

	_ship = _world.get_node("Ship")
	_dc = _ship.get_node("DockingComputer")
	_station = _world.get_node("MeridianRelay")
	_port = _station.get_node("DockingPort")
	var system: SolarSystem = _world.get_node("SolarSystem")
	_sunward = (OriginShift.to_render(system.get_body(&"sun").true_pos)
		- _station.global_position).normalized()

	_review_cam = Camera3D.new()
	_review_cam.fov = 55.0
	_review_cam.near = 0.1
	_review_cam.far = 100000.0
	_station.add_child(_review_cam)

	GameState.input_mode = GameState.InputMode.SHIP_FLIGHT
	GameState.flight_assist_enabled = false

	# 1. Approach: inside the capture volume, HUD readout live, too hot to dock.
	# Framed from the review camera — the gameplay rig's damped follow is still
	# converging after the 8 km pose teleport and would frame empty space.
	await _pose_at_port(9.0)
	_ship.linear_velocity = _port.station_velocity() - _port.axis_out() * 2.0
	_ship.freeze = false
	await _physics_settle(10)
	_frame_review(
		_port.global_position + _port.axis_out() * 14.0 + _sunward * 18.0 + Vector3.UP * 5.0,
		(_ship.global_position + _port.global_position) * 0.5
	)
	await _settle(4)
	print("  approach: in volume=%s speed=%.2f axis=%.1f°" % [
		_dc.approach_port != null, _dc.approach_speed, _dc.approach_axis_error_deg])
	await _shot("11_dock_approach")

	# 2. Docked: drift in slow and aligned, let the computer capture, wide shot.
	await _pose_at_port(5.0)
	_ship.linear_velocity = _port.station_velocity() - _port.axis_out() * 0.5
	_ship.freeze = false
	for _i in 240:
		await get_tree().physics_frame
		if GameState.docked:
			break
	print("  docked=%s at %s" % [GameState.docked, _dc.docked_station_name()])
	_frame_review(
		_port.global_position + _port.axis_out() * 30.0 + _sunward * 55.0 + Vector3.UP * 18.0,
		_station.global_position + Vector3.UP * 45.0
	)
	await _settle(6)
	await _shot("12_docked_wide")

	# 3. Undock: push-off, assist off so the separation keeps growing on camera.
	_dc.undock()
	GameState.flight_assist_enabled = false
	await _physics_settle(150)
	print("  undocked: %.1f m from port" %
		(_ship.global_position - _port.global_position).length())
	_frame_review(
		_port.global_position + _port.axis_out() * 8.0 + _sunward * 22.0 + Vector3.UP * 6.0,
		(_port.global_position + _ship.global_position) * 0.5
	)
	await _settle(4)
	await _shot("13_undock")

	print("shots written to %s" % ProjectSettings.globalize_path(OUT_DIR))
	get_tree().quit()


## Hold the ship frozen `out_m` along the approach axis, nose on the port,
## re-posed against the moving port every physics frame.
func _pose_at_port(out_m: float) -> void:
	_ship.freeze = true
	for _i in 30:
		var axis: Vector3 = _port.axis_out()
		var pos: Vector3 = _port.global_position + axis * out_m
		var up := Vector3.UP
		if absf(axis.dot(up)) > 0.99:
			up = Vector3.RIGHT
		_ship.global_position = pos
		_ship.look_at(pos - axis, up)
		await get_tree().physics_frame


## Aim the station-riding review camera. Global pose is set once; the station
## translates without rotating, so the framing holds.
func _frame_review(from: Vector3, at: Vector3) -> void:
	_review_cam.global_position = from
	_review_cam.look_at(at, Vector3.UP)
	_review_cam.current = true


func _settle(frames: int) -> void:
	for _i in frames:
		await get_tree().process_frame


func _physics_settle(frames: int) -> void:
	for _i in frames:
		await get_tree().physics_frame


func _shot(label: String) -> void:
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	var path: String = "%s/%s.png" % [OUT_DIR, label]
	image.save_png(path)
	print("  wrote %s" % path)
