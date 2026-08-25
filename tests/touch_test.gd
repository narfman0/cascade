extends Node
## Headless verification for Track TC: the touch synthesis layer.
##
## Run: CASCADE_TOUCH=1 godot --headless res://tests/touch_test.tscn
##
## The physics is already covered by thirteen suites — these gates prove only
## the synthesis: touches become the right actions at the right strengths,
## drags become look deltas on the right controller, the context bar never
## shows a dead button, and the discoverable rules (stick cancels autopilot)
## survive the translation.

var _failures: int = 0
var _world: Node3D
var _ship: RigidBody3D
var _system: SolarSystem
var _touch: TouchInput


func _ready() -> void:
	if OS.get_environment("CASCADE_TOUCH") != "1":
		print("FAIL — run with CASCADE_TOUCH=1")
		get_tree().quit(1)
		return
	_world = load("res://scenes/game_world.tscn").instantiate()
	add_child(_world)
	await get_tree().process_frame
	await get_tree().process_frame

	_ship = _world.get_node("Ship")
	_system = _world.get_node("SolarSystem")
	_touch = _world.get_node_or_null("TouchInput")

	_check(_touch != null, "touch layer instantiated under the override")
	await _test_stick()
	await _test_look()
	await _test_buttons()
	await _test_context_bar()
	await _test_autopilot_cancel()

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


## --- Synthetic fingers --------------------------------------------------------
## parse_input_event takes WINDOW coordinates and the canvas_items stretch
## transforms them into canvas space — in headless the window is 64×36 against
## the 1600×900 canvas, so an unconverted position lands ×25 off-screen. The
## tests think in canvas space (the layer's own space, where real device
## touches arrive after the same transform); convert on the way in.

func _win(pos: Vector2) -> Vector2:
	var w := get_window()
	return pos * (Vector2(w.size) / w.get_visible_rect().size)


func _down(index: int, pos: Vector2) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = index
	ev.position = _win(pos)
	ev.pressed = true
	Input.parse_input_event(ev)


func _up(index: int, pos: Vector2) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = index
	ev.position = _win(pos)
	ev.pressed = false
	Input.parse_input_event(ev)


func _drag(index: int, pos: Vector2, rel: Vector2) -> void:
	var ev := InputEventScreenDrag.new()
	ev.index = index
	ev.position = _win(pos)
	ev.relative = _win(rel)
	Input.parse_input_event(ev)


func _btn_rect(id: String) -> Rect2:
	var buttons: Dictionary = _touch.get("_buttons")
	if not buttons.has(id):
		return Rect2()
	return buttons[id]["rect"]


## --- Gates -------------------------------------------------------------------

func _test_stick() -> void:
	print("\n== stick ==")
	var origin := Vector2(300, 700)
	_down(0, origin)
	# Half-forward, full-right: analog strengths, correct axes.
	_drag(0, origin + Vector2(130, -65), Vector2(130, -65))
	await get_tree().process_frame
	# (130,-65) is length 145 — the ring clamps it to radius, leaving
	# x = 130/145 * ... = 0.894. The clamp is correct; assert against it.
	_check(Input.get_action_strength("thrust_right") > 0.85,
		"full right deflection (ring-clamped)", "%.2f" % Input.get_action_strength("thrust_right"))
	_check(absf(Input.get_action_strength("thrust_forward") - 0.5) < 0.12,
		"half forward is ANALOG", "%.2f" % Input.get_action_strength("thrust_forward"))
	_check(Input.get_action_strength("thrust_left") == 0.0
		and Input.get_action_strength("thrust_back") == 0.0,
		"opposite axes quiet")
	# Inside the deadzone: everything quiet.
	_drag(0, origin + Vector2(10, 5), Vector2(-120, 70))
	await get_tree().process_frame
	_check(Input.get_action_strength("thrust_right") == 0.0
		and Input.get_action_strength("thrust_forward") == 0.0,
		"deadzone honored")
	_up(0, origin)
	await get_tree().process_frame
	_check(Input.get_action_strength("thrust_right") == 0.0
		and Input.get_action_strength("thrust_left") == 0.0
		and Input.get_action_strength("thrust_forward") == 0.0
		and Input.get_action_strength("thrust_back") == 0.0,
		"release zeroes every axis")


func _test_look() -> void:
	print("\n== look ==")
	GameState.flight_assist_enabled = false
	var start := Vector2(1200, 450)
	_down(1, start)
	# A steady rightward drag = yaw command; read it off the FX torque signal
	# next physics tick (the fx_test trick).
	_drag(1, start + Vector2(60, 0), Vector2(60, 0))
	await get_tree().physics_frame
	await get_tree().physics_frame
	var q: Vector3 = _ship.get("fx_torque_local")
	_check(absf(q.y) > 100.0, "drag becomes torque", "yaw %.0f N·m" % q.y)
	_up(1, start + Vector2(60, 0))
	GameState.flight_assist_enabled = true
	for i in 30:
		await get_tree().physics_frame


func _test_buttons() -> void:
	print("\n== buttons ==")
	await get_tree().process_frame
	var r: Rect2 = _btn_rect("up")
	_check(r.size.x > 0.0, "▲ button laid out")
	_down(2, r.get_center())
	await get_tree().process_frame
	_check(Input.get_action_strength("thrust_up") > 0.9, "▲ held = thrust_up held")
	_up(2, r.get_center())
	await get_tree().process_frame
	_check(Input.get_action_strength("thrust_up") == 0.0, "▲ release")

	# FA is a tap toggle routed through the same event path as the X key.
	var fa_before: bool = GameState.flight_assist_enabled
	r = _btn_rect("fa")
	_down(3, r.get_center())
	_up(3, r.get_center())
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check(GameState.flight_assist_enabled != fa_before, "FA tap toggles")
	_down(3, r.get_center())
	_up(3, r.get_center())
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check(GameState.flight_assist_enabled == fa_before, "…and toggles back")


func _test_context_bar() -> void:
	print("\n== context bar ==")
	var buttons: Dictionary = _touch.get("_buttons")
	_check(buttons.has("eva") and not buttons.has("undock") and not buttons.has("board"),
		"free flight offers EVA, not UNDOCK/BOARD")
	_check(not buttons.has("autoland"), "no AUTOLAND outside a shell")
	# Park inside the Moon's shell: AUTOLAND appears.
	var moon := _system.get_body(&"moon")
	_ship.freeze = true
	for i in 4:
		_ship.global_position = OriginShift.to_render(moon.true_pos) \
			+ Vector3(0, 1, 0.2).normalized() * (moon.def.radius * 1.3)
		await get_tree().physics_frame
	_ship.freeze = false
	var mv: Array = moon.velocity_at(SimClock.sim_time)
	_ship.linear_velocity = Vector3(float(mv[0]), float(mv[1]), float(mv[2]))
	await get_tree().process_frame
	await get_tree().process_frame
	buttons = _touch.get("_buttons")
	_check(buttons.has("autoland"), "AUTOLAND appears inside the shell")
	# Tap it: autoland engages, the bar swaps to ABORT.
	var r: Rect2 = _btn_rect("autoland")
	_down(4, r.get_center())
	_up(4, r.get_center())
	await get_tree().physics_frame
	await get_tree().physics_frame
	var autoland := _ship.get_node("AutolandComputer") as AutolandComputer
	_check(autoland.active, "tap engages autoland")
	buttons = _touch.get("_buttons")
	_check(buttons.has("abort_al") and not buttons.has("autoland"),
		"bar swaps to ABORT while active")
	autoland.abort("test done")
	await get_tree().process_frame


func _test_autopilot_cancel() -> void:
	print("\n== the discoverable rule ==")
	# Climb out of the shell first — the autopilot refuses inside.
	var earth := _system.get_body(&"earth")
	_ship.freeze = true
	for i in 4:
		_ship.global_position = OriginShift.to_render(earth.true_pos) \
			+ Vector3(-1, 0.32, 0.1).normalized() * (earth.def.radius * 2.0)
		await get_tree().physics_frame
	_ship.freeze = false
	var ev2: Array = earth.velocity_at(SimClock.sim_time)
	_ship.linear_velocity = Vector3(float(ev2[0]), float(ev2[1]), float(ev2[2]))
	var autopilot := _ship.get_node("Autopilot") as Autopilot
	_check(autopilot.engage(_system.get_body(&"moon")), "autopilot engaged")
	for i in 4:
		await get_tree().physics_frame
	# Stick input must cancel it — through the touch layer.
	var origin := Vector2(300, 700)
	_down(5, origin)
	_drag(5, origin + Vector2(0, -120), Vector2(0, -120))
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check(not GameState.autopilot_active, "stick input cancels the autopilot")
	_up(5, origin)
	await get_tree().process_frame
