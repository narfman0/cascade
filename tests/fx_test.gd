extends Node
## Headless verification for Track FX: emitter activity tracks commanded
## thrust and torque, per axis, with the right thrusters firing.
##
## Run: godot --headless res://tests/fx_test.tscn

var _failures: int = 0
var _world: Node3D
var _ship: RigidBody3D
var _fx: ShipEffects


func _ready() -> void:
	_world = load("res://scenes/game_world.tscn").instantiate()
	add_child(_world)
	await get_tree().process_frame
	await get_tree().process_frame

	_ship = _world.get_node("Ship")
	_fx = _ship.get_node("ShipEffects")

	_test_mapping()
	await _test_player_burn()
	await _test_autopilot_burn()

	print("")
	if _failures == 0:
		print("PASS — all checks green")
	else:
		print("FAIL — %d check(s) failed" % _failures)
	get_tree().quit(1 if _failures > 0 else 0)


func _check(ok: bool, label: String, detail: String = "") -> void:
	if ok:
		print("  ok    %s %s" % [label, detail])
	else:
		_failures += 1
		print("  FAIL  %s %s" % [label, detail])


## The pure signal→emitter mapping, driven directly.
func _test_mapping() -> void:
	print("\n== signal mapping ==")
	_fx.apply_signals(Vector3(0, 0, -48000), Vector3.ZERO)
	_check(_fx.emitter_on("main") and not _fx.emitter_on("nose"),
		"forward burn lights the main engine")
	var light := _fx.get_node("EngineLight") as OmniLight3D
	_check(light.light_energy > 4.0, "engine light scales with throttle",
		"%.1f" % light.light_energy)

	_fx.apply_signals(Vector3(0, 0, 15000), Vector3.ZERO)
	_check(_fx.emitter_on("nose") and not _fx.emitter_on("main"),
		"braking fires the nose thruster")

	_fx.apply_signals(Vector3(15000, 0, 0), Vector3.ZERO)
	_check(_fx.emitter_on("left") and not _fx.emitter_on("right"),
		"thrust right expels from the left face")

	_fx.apply_signals(Vector3(0, 15000, 0), Vector3.ZERO)
	_check(_fx.emitter_on("belly") and not _fx.emitter_on("top"),
		"thrust up fires the belly jets")

	_fx.apply_signals(Vector3(0, -15000, 0), Vector3.ZERO)
	_check(_fx.emitter_on("top") and not _fx.emitter_on("belly"),
		"thrust down expels from the top face")

	_fx.apply_signals(Vector3.ZERO, Vector3(20000, 0, 0))
	_check(
		_fx.emitter_on("nose_down") and _fx.emitter_on("tail_up")
		and not _fx.emitter_on("nose_up") and not _fx.emitter_on("main"),
		"pitch up fires the opposed nose-down/tail-up pair")

	_fx.apply_signals(Vector3.ZERO, Vector3(0, 20000, 0))
	_check(_fx.emitter_on("nose_r") and _fx.emitter_on("tail_l"),
		"yaw left fires the opposed nose-right/tail-left pair")

	_fx.apply_signals(Vector3.ZERO, Vector3(0, 0, 20000))
	_check(_fx.emitter_on("wing_l_down") and _fx.emitter_on("wing_r_up"),
		"roll fires the opposed wingtip pair")

	_fx.apply_signals(Vector3(0, 0, -100), Vector3(0, 100, 0))
	_check(not _fx.emitter_on("main") and not _fx.emitter_on("nose_r"),
		"flight-assist trickle stays under the deadband")

	_fx.apply_signals(Vector3.ZERO, Vector3.ZERO)
	var any_on := false
	for name in ["main", "nose", "left", "right", "top", "belly", "nose_up", "tail_up"]:
		if _fx.emitter_on(name):
			any_on = true
	_check(not any_on, "engines cold at zero command")


## End to end: player input → controller signal → emitters.
func _test_player_burn() -> void:
	print("\n== player burn ==")
	GameState.flight_assist_enabled = false
	Input.action_press("thrust_forward")
	for i in 4:
		await get_tree().physics_frame
	await get_tree().process_frame
	var t: Vector3 = _ship.get("fx_thrust_local")
	_check(t.z < -40000.0, "controller reports the main burn", "%.0f N" % t.z)
	_check(_fx.emitter_on("main"), "plume follows the input")
	Input.action_release("thrust_forward")
	for i in 4:
		await get_tree().physics_frame
	await get_tree().process_frame
	_check(not _fx.emitter_on("main"), "plume cuts with the input")
	GameState.flight_assist_enabled = true


## The cruise drive is a burn the player should see too.
func _test_autopilot_burn() -> void:
	print("\n== autopilot burn ==")
	var autopilot := _ship.get_node("Autopilot") as Autopilot
	var system := _world.get_node("SolarSystem") as SolarSystem
	var ok: bool = autopilot.engage(system.get_body(&"moon"))
	_check(ok, "autopilot engaged")
	for i in 8:
		await get_tree().physics_frame
	await get_tree().process_frame
	_check(_fx.emitter_on("main"), "cruise burn lights the stern")
	autopilot.cancel("fx test done")
	await get_tree().process_frame
	_check(not _fx.emitter_on("main"), "cutoff on cancel")
