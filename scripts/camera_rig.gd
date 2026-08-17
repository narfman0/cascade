extends Node3D
## Camera rig — third-person follow with critically-damped smoothing,
## plus a cockpit mode. Orientation snaps to ship basis every frame so
## the player can judge attitude with minimal lag.

enum Mode { THIRD_PERSON, COCKPIT }

@export var target_path: NodePath
@export var third_person_offset: Vector3 = Vector3(0, 3.0, 12.0)  # behind and above
@export var cockpit_offset: Vector3 = Vector3(0, 0.6, -0.4)       # inside hull
@export var position_smoothing_half_life: float = 0.12            # seconds
## Which input mode this rig owns. Its camera becomes current whenever
## GameState.input_mode matches. Leave at -1 to always stay current.
@export var owned_input_mode: int = -1

@onready var _camera: Camera3D = $Camera3D
var _target: Node3D
var _mode: Mode = Mode.THIRD_PERSON
var _current_pos: Vector3


func _ready() -> void:
	if target_path != NodePath():
		_target = get_node(target_path)
	if _target == null:
		var parent := get_parent()
		if parent is Node3D:
			_target = parent
	if _target:
		_current_pos = _target.to_global(third_person_offset)
		global_position = _current_pos
	set_as_top_level(true)
	if owned_input_mode >= 0:
		GameState.input_mode_changed.connect(_on_input_mode_changed)
		_on_input_mode_changed(GameState.input_mode)


func _on_input_mode_changed(mode: int) -> void:
	if _camera:
		_camera.current = (mode == owned_input_mode)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_camera"):
		_mode = Mode.COCKPIT if _mode == Mode.THIRD_PERSON else Mode.THIRD_PERSON


func _process(delta: float) -> void:
	if _target == null:
		return
	if _mode == Mode.COCKPIT:
		global_transform = _target.global_transform.translated_local(cockpit_offset)
		return

	var desired: Vector3 = _target.to_global(third_person_offset)
	# Critically-damped exponential smoothing via half-life.
	var alpha: float = 1.0 - exp(-delta * log(2.0) / maxf(position_smoothing_half_life, 0.0001))
	_current_pos = _current_pos.lerp(desired, alpha)
	global_position = _current_pos
	# Orientation snaps — minimal rotational lag.
	global_basis = _target.global_basis
