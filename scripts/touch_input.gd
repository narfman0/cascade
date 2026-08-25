class_name TouchInput extends CanvasLayer
## Touch controls (Track TC): the phone's hands, as a synthesis layer.
##
## Design rule (docs/mobile.md §6): SYNTHESIZE, NEVER REWRITE. This layer
## parses raw ScreenTouch/ScreenDrag events and feeds the two channels every
## controller already listens to:
##   1. InputEventAction via Input.parse_input_event — which both updates the
##      polled action state (WITH analog strength, so the virtual stick gives
##      analog thrust the keyboard never could) and propagates real events, so
##      `event.is_action_pressed(...)` handlers (interact, FA toggle, the
##      autopilot's any-stick-cancels rule) fire exactly as from a key.
##   2. add_look_delta on the ship / suit — the same accumulator the mouse
##      feeds. Torque, EVA look and the walk's camera boom arrive unchanged.
## Flight, EVA, walking, docking, landing, autoland, hazard code never learn
## a phone exists.
##
## Instantiated by GameWorld only under OS.has_feature("mobile") or the
## CASCADE_TOUCH=1 desktop override (gates + layout screenshots).
##
## Layout: left virtual stick (strafe X / fwd-back Y, spawns under the
## thumb), ▲/▼ vertical-axis buttons that relabel JUMP while walking and
## LIFT OFF while landed (they ARE thrust_up — the relabel is honesty, not a
## mode), the right half as the mouse, roll pair top-right, system row
## (FA/CAM/NAV) and a context bar that reuses the HUD prompts' predicates so
## a dead button can never appear.

const STICK_RADIUS: float = 130.0
const STICK_DEADZONE: float = 0.15
const LOOK_SENS: float = 1.15
const BTN: float = 92.0          # button square size, px in the 1600×900 canvas
const MARGIN: float = 26.0

## Axis action pairs the stick drives.
const AXIS_X: Array = ["thrust_left", "thrust_right"]
const AXIS_Y: Array = ["thrust_forward", "thrust_back"]

var _ship: RigidBody3D
var _system: SolarSystem

var _canvas: Control

# Touch bookkeeping: finger index -> role.
var _stick_finger: int = -1
var _stick_origin: Vector2 = Vector2.ZERO
var _stick_vec: Vector2 = Vector2.ZERO
var _look_finger: int = -1
var _button_fingers: Dictionary = {}   # finger index -> button id

## Buttons: id -> {rect, label, hold(bool), action(String) or tap Callable}.
## Rebuilt each frame from the mode predicates; hit-testing uses last build.
var _buttons: Dictionary = {}


func setup(ship: RigidBody3D, system: SolarSystem) -> void:
	_ship = ship
	_system = system


func _ready() -> void:
	layer = 90
	_canvas = Control.new()
	_canvas.name = "TouchCanvas"
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_draw_widgets)
	add_child(_canvas)


func _process(_dt: float) -> void:
	_rebuild_buttons()
	_canvas.queue_redraw()


func _input(event: InputEvent) -> void:
	# A console owns the screen (FOCUSED): stand down entirely and let the
	# engine's touch→mouse emulation drive the Controls like a pointer.
	if GameState.input_mode == GameState.InputMode.FOCUSED:
		return
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if OS.get_environment("TC_DEBUG") == "1":
			print("      [touch] idx %d pressed %s at %s" % [
				touch.index, touch.pressed, touch.position])
		if touch.pressed:
			_finger_down(touch.index, touch.position)
		else:
			_finger_up(touch.index)
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		_finger_move(drag.index, drag.position, drag.relative)
		get_viewport().set_input_as_handled()


## --- Touch routing -----------------------------------------------------------

func _finger_down(index: int, pos: Vector2) -> void:
	# Buttons first: they sit over both zones.
	for id in _buttons:
		if (_buttons[id]["rect"] as Rect2).has_point(pos):
			_button_fingers[index] = id
			_press_button(id, true)
			return
	var size: Vector2 = _canvas.get_viewport_rect().size
	if pos.x < size.x * 0.42 and _stick_finger < 0 and _stick_allowed():
		_stick_finger = index
		_stick_origin = pos
		_stick_vec = Vector2.ZERO
	elif _look_finger < 0 and _look_allowed():
		_look_finger = index


func _finger_move(index: int, pos: Vector2, relative: Vector2) -> void:
	if index == _stick_finger:
		_stick_vec = (pos - _stick_origin).limit_length(STICK_RADIUS) / STICK_RADIUS
		_apply_stick()
	elif index == _look_finger:
		_route_look(relative * LOOK_SENS)


func _finger_up(index: int) -> void:
	if index == _stick_finger:
		_stick_finger = -1
		_stick_vec = Vector2.ZERO
		_apply_stick()
	elif index == _look_finger:
		_look_finger = -1
	elif _button_fingers.has(index):
		_press_button(_button_fingers[index], false)
		_button_fingers.erase(index)


## --- Synthesis ---------------------------------------------------------------

func _act(action: String, pressed: bool, strength: float = 1.0) -> void:
	# BOTH channels, explicitly. parse_input_event(InputEventAction) reaches
	# event listeners (`event.is_action_pressed` in _unhandled_input — the FA
	# toggle, interact, the autopilot's any-stick-cancels rule) but does NOT
	# update the polled action state; action_press updates what
	# get_action_strength reads (the flight axes) but emits no event.
	# Verified the hard way: with only the event half, torque worked and
	# every polled axis read zero.
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = pressed
	ev.strength = strength if pressed else 0.0
	Input.parse_input_event(ev)
	if pressed:
		Input.action_press(action, strength)
	else:
		Input.action_release(action)


func _apply_stick() -> void:
	var v: Vector2 = _stick_vec
	if v.length() < STICK_DEADZONE:
		v = Vector2.ZERO
	# Screen up = forward. Send per-side strengths; zero releases.
	_axis(AXIS_X[1], maxf(v.x, 0.0))
	_axis(AXIS_X[0], maxf(-v.x, 0.0))
	_axis(AXIS_Y[0], maxf(-v.y, 0.0))
	_axis(AXIS_Y[1], maxf(v.y, 0.0))


var _axis_state: Dictionary = {}

func _axis(action: String, strength: float) -> void:
	if OS.get_environment("TC_DEBUG") == "1":
		print("      [axis] %s -> %.3f (state now %.3f)" % [
			action, strength, Input.get_action_strength(action)])
	var prev: float = _axis_state.get(action, 0.0)
	if strength <= 0.0 and prev > 0.0:
		_act(action, false)
	elif strength > 0.0 and absf(strength - prev) > 0.01:
		_act(action, true, strength)
	_axis_state[action] = strength


func _route_look(delta: Vector2) -> void:
	var target: Node = null
	if GameState.input_mode == GameState.InputMode.EVA and _ship:
		target = _ship.get("character")
	else:
		target = _ship
	if target and target.has_method("add_look_delta"):
		target.call("add_look_delta", delta)


func _press_button(id: String, down: bool) -> void:
	if not _buttons.has(id):
		if not down:
			# Layout changed under the finger; nothing held to release.
			return
		return
	var b: Dictionary = _buttons[id]
	if b["hold"]:
		_act(b["action"], down)
	elif down:
		_act(b["action"], true)
		_act(b["action"], false)


## --- Mode predicates ---------------------------------------------------------

func _walking() -> bool:
	var suit: Node = _ship.get("character") if _ship else null
	return suit != null and suit.get("clamped_body") != null


func _rock_clamped() -> bool:
	var suit: Node = _ship.get("character") if _ship else null
	return suit != null and suit.get("clamped_rock") != null


func _flying_free() -> bool:
	if GameState.input_mode == GameState.InputMode.EVA:
		return not _walking() and not _rock_clamped()
	return not GameState.docked and not GameState.landed \
		and not GameState.autopilot_active


func _stick_allowed() -> bool:
	return _flying_free() or _walking()


func _look_allowed() -> bool:
	return _flying_free() or _walking()


## --- Layout ------------------------------------------------------------------

func _rebuild_buttons() -> void:
	var out: Dictionary = {}
	if _ship == null:
		_buttons = out
		return
	var size: Vector2 = _canvas.get_viewport_rect().size
	var eva: bool = GameState.input_mode == GameState.InputMode.EVA
	var walking := _walking()
	var stick_c := Vector2(MARGIN + STICK_RADIUS + 40.0, size.y - MARGIN - STICK_RADIUS - 30.0)

	# Vertical axis / jump / lift-off — the same action wearing honest labels.
	if _flying_free() or walking or GameState.landed:
		var up_label: String = "▲"
		if walking:
			up_label = "JUMP"
		elif GameState.landed:
			up_label = "LIFT OFF\n(hold)"
		out["up"] = _btn(Vector2(stick_c.x + STICK_RADIUS + 46.0, stick_c.y - BTN - 10.0),
			up_label, true, "thrust_up")
		if not walking and not GameState.landed:
			out["down"] = _btn(Vector2(stick_c.x + STICK_RADIUS + 46.0, stick_c.y + 10.0),
				"▼", true, "thrust_down")

	# Roll pair, flight only — below the APPROACH/SURFACE panels' band.
	if _flying_free():
		out["roll_l"] = _btn(Vector2(size.x - MARGIN - BTN * 2.0 - 12.0, size.y * 0.42),
			"⟲", true, "roll_left")
		out["roll_r"] = _btn(Vector2(size.x - MARGIN - BTN, size.y * 0.42),
			"⟳", true, "roll_right")

	# System row.
	var sysx: float = size.x * 0.40
	var sysy: float = size.y - MARGIN * 3.2 - BTN * 0.7
	out["fa"] = _btn(Vector2(sysx, sysy), "FA", false, "toggle_flight_assist", BTN * 0.7)
	out["cam"] = _btn(Vector2(sysx + BTN * 0.8, sysy), "CAM", false, "toggle_camera", BTN * 0.7)
	out["nav"] = _btn(Vector2(sysx + BTN * 1.6, sysy), "NAV", false, "nav_console", BTN * 0.7)

	# Context bar: only what would actually do something (HUD predicates).
	var cx: float = sysx + BTN * 2.6
	var latch: LatchComputer = _ship.get_node_or_null("LatchComputer")
	var autoland: AutolandComputer = _ship.get_node_or_null("AutolandComputer")
	var autopilot: Autopilot = _ship.get_node_or_null("Autopilot")
	var suit: Node = _ship.get("character")
	if GameState.docked:
		out["undock"] = _ctx(cx, sysy, "UNDOCK", "interact"); cx += BTN * 1.3
	elif eva:
		if suit and suit.has_method("can_board") and suit.call("can_board"):
			out["board"] = _ctx(cx, sysy, "BOARD", "interact"); cx += BTN * 1.3
		if _rock_clamped():
			out["release"] = _ctx(cx, sysy, "RELEASE", "latch"); cx += BTN * 1.3
		elif not walking and suit and (suit.get_parent() != null):
			out["latch"] = _ctx(cx, sysy, "LATCH", "latch"); cx += BTN * 1.3
	else:
		if not GameState.landed and not GameState.autopilot_active:
			out["eva"] = _ctx(cx, sysy, "EVA", "interact"); cx += BTN * 1.3
		if latch and latch.ready_rock != null:
			out["latch"] = _ctx(cx, sysy, "LATCH", "latch"); cx += BTN * 1.3
		elif latch and latch.latched_rock != null:
			out["release"] = _ctx(cx, sysy, "RELEASE", "latch"); cx += BTN * 1.3
		if autoland and autoland.active:
			out["abort_al"] = _ctx(cx, sysy, "ABORT", "engage_autoland"); cx += BTN * 1.3
		elif autoland and autoland.can_engage():
			out["autoland"] = _ctx(cx, sysy, "AUTOLAND", "engage_autoland"); cx += BTN * 1.3
		if GameState.autopilot_active and autopilot:
			out["abort_ap"] = _ctx(cx, sysy, "ABORT", "engage_autopilot"); cx += BTN * 1.3
	_buttons = out


func _btn(pos: Vector2, label: String, hold: bool, action: String, size_px: float = BTN) -> Dictionary:
	return {"rect": Rect2(pos, Vector2(size_px, size_px)), "label": label,
		"hold": hold, "action": action}


func _ctx(x: float, y: float, label: String, action: String) -> Dictionary:
	return {"rect": Rect2(Vector2(x, y), Vector2(BTN * 1.2, BTN * 0.7)),
		"label": label, "hold": false, "action": action}


## --- Drawing (the calm HUD language: thin lines, low alpha) -------------------

func _draw_widgets() -> void:
	var line := Color(0.75, 0.82, 0.85, 0.55)
	var fill := Color(0.75, 0.82, 0.85, 0.08)
	var font := ThemeDB.fallback_font
	# Stick: resting hint ring, live base + knob while held.
	if _stick_allowed():
		var size: Vector2 = _canvas.get_viewport_rect().size
		var rest := Vector2(MARGIN + STICK_RADIUS + 40.0, size.y - MARGIN - STICK_RADIUS + 40.0)
		var centre: Vector2 = _stick_origin if _stick_finger >= 0 else rest
		var alpha: float = 1.0 if _stick_finger >= 0 else 0.55
		_canvas.draw_arc(centre, STICK_RADIUS, 0, TAU, 48, Color(line, line.a * alpha), 1.5)
		_canvas.draw_circle(centre + _stick_vec * STICK_RADIUS, 26.0,
			Color(0.8, 0.87, 0.9, 0.35 * alpha))
	for id in _buttons:
		var b: Dictionary = _buttons[id]
		var r: Rect2 = b["rect"]
		var active: bool = id in _button_fingers.values()
		# FA button reflects the state it toggles.
		var col := line
		if id == "fa":
			col = Color(0.55, 0.95, 0.7, 0.7) if GameState.flight_assist_enabled \
				else Color(0.95, 0.7, 0.45, 0.7)
		_canvas.draw_rect(r, Color(col, 0.25) if active else fill, true)
		_canvas.draw_rect(r, col, false, 1.5)
		var label: String = b["label"]
		var fs: int = 22 if label.length() <= 3 else 17
		_canvas.draw_string(font, r.position + Vector2(0, r.size.y * 0.5 + fs * 0.35),
			label, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, fs, col)
