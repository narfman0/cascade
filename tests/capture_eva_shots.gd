extends Node
## EVA screenshot harness — what leaving the ship actually looks like.
##
## Run: xvfb-run -a godot res://tests/capture_eva_shots.tscn
##
## Framing note: the suit is held in place with `freeze` for each shot rather
## than flown. A live RigidBody3D has its transform reverted by the physics
## server, and the ship is station-keeping at Earth's orbital velocity, so
## anything not co-moving falls behind ~2 m per tick.

const OUT_DIR: String = "user://shots"

var _ship: RigidBody3D
var _suit: RigidBody3D
var _sunward: Vector3 = Vector3.RIGHT
## No harness camera: one added here does not reliably win `current` against the
## rigs already in the scene, which is why the first pass of these shots rendered
## from behind the ship instead of the intended framing. The EVA rig camera
## becomes current with the EVA input mode, so pose the *suit* and let it follow
## — the shots then show exactly what the player sees on EVA.


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var world: Node3D = load("res://scenes/game_world.tscn").instantiate()
	add_child(world)
	await _settle(6)

	_ship = world.get_node("Ship")
	_suit = _ship.get("character") as RigidBody3D
	var system: SolarSystem = world.get_node("SolarSystem")
	var earth := system.get_body(&"earth")
	# Shots are framed from the sunward side. Posing the suit anywhere else puts
	# the camera on its shadow side, and with only faint earthshine for fill the
	# result is a near-black frame — physically right, useless for review.
	_sunward = (OriginShift.to_render(system.get_body(&"sun").true_pos)
		- _ship.global_position).normalized()

	# Keep the hull still so the suit can be posed relative to it.
	_ship.freeze = true
	GameState.flight_assist_enabled = false

	_suit.call("request_exit")
	await _settle(8)
	_suit.freeze = true
	print("  exited: suit %.2f m from hull, EVA camera current=%s" % [
		(_suit.global_position - _ship.global_position).length(),
		(_suit.get_node("CameraRig/Camera3D") as Camera3D).current,
	])

	# 1. At the hatch, hull filling the frame behind.
	await _face(_ship.global_position, 9.0)
	await _settle(20)
	await _shot("06_eva_at_hatch")

	# 2. Standing off, ship and Earth together — the "don't lose your ride" view.
	await _pose(_ship.global_position + _hatch_dir() * 22.0 + _sunward * 6.0,
		_ship.global_position)
	await _settle(20)
	await _shot("07_eva_standoff")

	# 3. Working distance on a debris piece.
	var debris := world.get_node_or_null("DebrisField/Debris_001") as Node3D
	if debris:
		await _face(debris.global_position, 10.0)
		await _settle(20)
		await _shot("08_eva_at_debris")

	# 4. Earth as the backdrop — the suit lit, the planet filling the frame behind.
	await _face_body(earth, 2200.0)
	await _settle(20)
	await _shot("09_eva_earthside")

	# 5. Back at the cargo bay, about to board.
	var bay := _ship.get_node("CargoBay") as Area3D
	for _i in 20:
		_suit.global_position = bay.global_position
		await get_tree().physics_frame
		if _suit.call("can_board"):
			break
	print("  at bay: can_board=%s" % _suit.call("can_board"))
	await _shot("10_eva_boarding")

	print("shots written to %s" % ProjectSettings.globalize_path(OUT_DIR))
	get_tree().quit()


## Direction the hatch faces, in render space.
func _hatch_dir() -> Vector3:
	var exit_point := _ship.get_node("ExitPoint") as Marker3D
	return (exit_point.global_position - _ship.global_position).normalized()


## Place the suit and point it at something, holding the pose long enough for the
## physics step to commit it and the camera rig's smoothing to catch up.
func _pose(where: Vector3, look_at_target: Vector3) -> void:
	_suit.freeze = true
	var dir: Vector3 = look_at_target - where
	var up := Vector3.UP
	if dir.length() > 0.5 and absf(dir.normalized().dot(up)) > 0.99:
		up = Vector3.RIGHT
	for _i in 30:
		_suit.global_position = where
		if dir.length() > 0.5:
			_suit.look_at(look_at_target, up)
		await get_tree().physics_frame


## Pose the suit facing `subject`, positioned so the sun is behind the rig
## camera — otherwise the camera looks at the suit's shadow side and, with only
## faint earthshine for fill, the suit is a black silhouette against black space
## and reads as simply absent.
func _face(subject: Vector3, standoff: float) -> void:
	# Sun *side* of the subject, not the far side: the rig camera sits behind the
	# suit, so putting the suit sunward of what it faces is what places the sun
	# behind the camera and lights the surface we actually see. (_face_body has
	# always done this correctly, which is why the planet shots lit and these
	# did not.)
	var from: Vector3 = subject + _sunward * standoff + Vector3.UP * (standoff * 0.15)
	await _pose(from, subject)


## Same, but for a subject too large to stand off from directly (a planet): sit
## `gap` metres off its surface along the sunward line, so the rig camera has the
## sun behind it, the suit is lit, and the body fills the frame behind.
func _face_body(body: CelestialBody, gap: float) -> void:
	var centre: Vector3 = OriginShift.to_render(body.true_pos)
	var from: Vector3 = centre + _sunward * (body.def.radius + gap)
	await _pose(from, centre)


func _settle(frames: int) -> void:
	for _i in frames:
		await get_tree().process_frame


func _shot(label: String) -> void:
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	var path: String = "%s/%s.png" % [OUT_DIR, label]
	image.save_png(path)
	print("  wrote %s" % path)
