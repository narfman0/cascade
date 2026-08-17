extends CanvasLayer
## HUD — calm, thin-line readouts. Swaps between ship and EVA variants
## by watching GameState.input_mode.

@export var ship_path: NodePath

@onready var _velocity_label: Label = $Root/Panel/VelocityLabel
@onready var _orientation_label: Label = $Root/Panel/OrientationLabel
@onready var _fuel_label: Label = $Root/Panel/FuelLabel
@onready var _fa_label: Label = $Root/Panel/FALabel
@onready var _eva_fuel_label: Label = $Root/Panel/EVAFuelLabel
@onready var _ship_marker_label: Label = $Root/Panel/ShipMarkerLabel
@onready var _reference_label: Label = $Root/Panel/ReferenceLabel
@onready var _autopilot_label: Label = $Root/AutopilotLabel
@onready var _nav_hint: Label = $Root/NavHint
@onready var _interact_prompt: Label = $Root/InteractPrompt
@onready var _prograde_marker: Control = $Root/PrograteMarker
@onready var _prograde_dot: ColorRect = $Root/PrograteMarker/Dot

var _ship: RigidBody3D
var _character: RigidBody3D
var _system: SolarSystem
var _autopilot: Autopilot
var _nav_console: NavConsole


func _ready() -> void:
	if ship_path != NodePath():
		_ship = get_node(ship_path)
	else:
		_ship = get_tree().get_root().find_child("Ship", true, false)
	if _ship:
		# The suit is out of the tree while aboard, so ask the ship for it.
		_character = _ship.get("character") as RigidBody3D
		if _character == null:
			_character = _ship.get_node_or_null("Character") as RigidBody3D
	GameState.flight_assist_changed.connect(_on_flight_assist_changed)
	GameState.input_mode_changed.connect(_on_input_mode_changed)
	_on_flight_assist_changed(GameState.flight_assist_enabled)
	if _ship and _ship.has_signal("fuel_changed"):
		_ship.fuel_changed.connect(_on_fuel_changed)
	_on_input_mode_changed(GameState.input_mode)


## Called by GameWorld once the solar system exists. Builds the nav console here
## rather than in the scene so it can be populated from the system's body list.
func bind_world(system: SolarSystem, autopilot: Autopilot) -> void:
	_system = system
	_autopilot = autopilot
	if autopilot:
		autopilot.engaged.connect(_on_autopilot_engaged)
		autopilot.arrived.connect(_on_autopilot_arrived)
		autopilot.cancelled.connect(_on_autopilot_cancelled)
	_nav_console = NavConsole.new()
	_nav_console.name = "NavConsole"
	_nav_console.set_anchors_preset(Control.PRESET_FULL_RECT)
	$Root.add_child(_nav_console)
	_nav_console.setup(system, autopilot)


func _process(_delta: float) -> void:
	var active := _active_body()
	if active == null:
		return
	# Speed is shown relative to the local reference frame — an absolute figure
	# would read 131 m/s while sitting still next to Earth.
	var speed: float = active.linear_velocity.length()
	if active.has_method("relative_velocity"):
		speed = active.relative_velocity().length()
	if GameState.autopilot_active and _autopilot:
		# The hull is frozen while the autopilot integrates the transfer, so its
		# linear_velocity is stale. Take the real cruise speed from the autopilot.
		speed = _autopilot.current_speed()
	_velocity_label.text = "VEL  %6.1f m/s" % speed
	var e: Vector3 = active.global_basis.get_euler()
	_orientation_label.text = "ATT  P %+6.1f°  Y %+6.1f°  R %+6.1f°" % [
		rad_to_deg(e.x), rad_to_deg(e.y), rad_to_deg(e.z)
	]
	if GameState.autopilot_active:
		_prograde_marker.visible = false
	else:
		_update_prograde_marker(active, active.linear_velocity)

	_update_reference_readout()
	_update_autopilot_readout()

	if GameState.input_mode == GameState.InputMode.EVA:
		_update_eva_readouts()
	else:
		_update_interact_prompt_ship()


func _active_body() -> RigidBody3D:
	if GameState.input_mode == GameState.InputMode.EVA and _character:
		return _character
	return _ship


func _update_reference_readout() -> void:
	if _system == null or _ship == null:
		return
	var body := _system.reference_body(OriginShift.to_true(_ship.global_position))
	_reference_label.text = "REF   %s" % (body.def.display_name if body else "open space")


func _update_autopilot_readout() -> void:
	if _autopilot == null:
		return
	var line: String = _autopilot.status_line()
	_autopilot_label.visible = line != ""
	_autopilot_label.text = line
	# The nav hint is noise while a transfer is running or a console is open.
	_nav_hint.visible = line == "" and GameState.input_mode == GameState.InputMode.SHIP_FLIGHT


func _on_autopilot_engaged(target_name: String, _eta_real: float) -> void:
	_interact_prompt.visible = false
	AudioManager.note_event(&"autopilot_engaged")
	print("Autopilot engaged → %s" % target_name)


func _on_autopilot_arrived(target_name: String) -> void:
	print("Arrived at %s" % target_name)


func _on_autopilot_cancelled(reason: String) -> void:
	print("Autopilot disengaged (%s)" % reason)


func _update_eva_readouts() -> void:
	if _character == null:
		return
	var fuel = _character.get("fuel")
	if fuel:
		_eva_fuel_label.text = "EVA  %5.1f%%" % fuel.percent()
	if _ship:
		var to_ship: Vector3 = _ship.global_position - _character.global_position
		_ship_marker_label.text = "SHIP  %6.1f m" % to_ship.length()
	# Interact prompt: show "F — Board" only inside cargo bay.
	var can_board: bool = _character.has_method("can_board") and _character.can_board()
	_interact_prompt.text = "F — Board"
	_interact_prompt.visible = can_board


func _update_interact_prompt_ship() -> void:
	# Available from the cockpit whenever the pilot is actually flying.
	var flying: bool = (
		GameState.input_mode == GameState.InputMode.SHIP_FLIGHT
		and not GameState.autopilot_active
	)
	_interact_prompt.text = "F — EVA"
	_interact_prompt.visible = flying


func _update_prograde_marker(body: RigidBody3D, v: Vector3) -> void:
	var speed := v.length()
	if speed < 0.5:
		_prograde_marker.visible = false
		return
	var v_local: Vector3 = body.global_basis.transposed() * v.normalized()
	_prograde_marker.visible = true
	var viewport := get_viewport().get_visible_rect().size
	var center := viewport * 0.5
	var radius: Vector2 = viewport * 0.35
	var offset := Vector2(v_local.x, -v_local.y) * radius
	if v_local.z > 0.0:
		_prograde_dot.color = Color(0.55, 0.55, 0.55, 0.8)
	else:
		_prograde_dot.color = Color(0.85, 0.85, 0.85, 0.9)
	_prograde_marker.position = center + offset - _prograde_marker.size * 0.5


func _on_flight_assist_changed(enabled: bool) -> void:
	_fa_label.text = "FA   %s" % ("ON" if enabled else "OFF")
	_fa_label.modulate = Color(0.85, 0.85, 0.85) if enabled else Color(0.6, 0.6, 0.6)


func _on_fuel_changed(remaining: float, capacity: float) -> void:
	var pct: float = 100.0 * remaining / maxf(capacity, 1.0)
	_fuel_label.text = "FUEL %5.1f%%" % pct


func _on_input_mode_changed(mode: int) -> void:
	var eva := mode == GameState.InputMode.EVA
	_eva_fuel_label.visible = eva
	_ship_marker_label.visible = eva
	_fuel_label.visible = not eva
