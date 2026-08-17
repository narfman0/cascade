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
## A review camera the harness controls directly. The gameplay rig always sits
## behind the suit, which is the right choice in play and useless for a portrait
## — you cannot see the astronaut you are trying to show someone.
var _review_cam: Camera3D


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

	_review_cam = Camera3D.new()
	_review_cam.fov = 60.0
	_review_cam.near = 0.05
	_review_cam.far = 100000.0
	add_child(_review_cam)

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

	# 1. At the hatch, ship filling frame — the moment after stepping out.
	await _pose(_ship.global_position + _hatch_dir() * 5.0 + _sunward * 4.0,
		_ship.global_position)
	await _settle(6)
	await _frame_suit(4.5, _ship.global_position)
	await _settle(6)
	await _shot("06_eva_at_hatch")

	# 2. Standoff, ship and Earth together — the "don't lose your ride" view.
	await _pose(_ship.global_position + _hatch_dir() * 12.0 + _sunward * 20.0
		+ Vector3.UP * 4.0, _ship.global_position)
	await _settle(6)
	await _frame_suit(9.0, _ship.global_position, 1.5)
	await _settle(6)
	await _shot("07_eva_standoff")

	# 3. Working distance on a debris piece, hull behind.
	var debris := world.get_node_or_null("DebrisField/Debris_001") as Node3D
	if debris:
		await _pose(debris.global_position + _sunward * 11.0 + Vector3.UP * 2.0,
			debris.global_position)
		await _settle(6)
		await _frame_suit(6.0, debris.global_position)
		await _settle(6)
		await _shot("08_eva_at_debris")

	# 4. Earth behind the suit — scale reference.
	await _pose(_ship.global_position + _hatch_dir() * 10.0 + _sunward * 8.0,
		OriginShift.to_render(earth.true_pos))
	await _settle(6)
	await _frame_suit(5.0, OriginShift.to_render(earth.true_pos), 1.0)
	await _settle(6)
	await _shot("09_eva_earthside")

	# 5. Back in the cargo bay, about to board.
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


## Look at the suit from `distance` metres, sunlit, with `backdrop` behind it.
func _frame_suit(distance: float, backdrop: Vector3, lift: float = 0.6) -> void:
	var suit_pos: Vector3 = _suit.global_position
	# Put the camera between the sun and the suit so we see its lit side, and
	# offset off the sun-suit axis so the backdrop falls behind the figure.
	var away_from_backdrop: Vector3 = (suit_pos - backdrop).normalized()
	var dir: Vector3 = (_sunward * 0.65 + away_from_backdrop * 0.75).normalized()
	_review_cam.global_position = suit_pos + dir * distance + Vector3.UP * lift
	_review_cam.look_at(suit_pos, Vector3.UP)
	_review_cam.current = true
	await get_tree().process_frame


func _settle(frames: int) -> void:
	for _i in frames:
		await get_tree().process_frame


func _shot(label: String) -> void:
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	var path: String = "%s/%s.png" % [OUT_DIR, label]
	image.save_png(path)
	print("  wrote %s" % path)
