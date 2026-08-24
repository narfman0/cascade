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
## Last frame's ideal position. The smoothing follows the *change* in this,
## so steady motion carries the camera along instead of being smoothed away.
var _prev_desired: Vector3


func _ready() -> void:
	if target_path != NodePath():
		_target = get_node(target_path)
	if _target == null:
		var parent := get_parent()
		if parent is Node3D:
			_target = parent
	if _target:
		_current_pos = _target.to_global(third_person_offset)
		_prev_desired = _current_pos
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

	var desired: Vector3 = _target.to_global(third_person_offset)
	if _mode == Mode.COCKPIT:
		global_transform = _target.global_transform.translated_local(cockpit_offset)
		# Keep the third-person state live while inside, so leaving the cockpit
		# eases back out from here rather than snapping.
		_current_pos = global_position
		_prev_desired = desired
		return

	# Smooth in the target's frame, not the world's. Carrying the camera by the
	# target's own displacement first means steady motion costs nothing: what is
	# left to damp is only the *residual* — attitude swings, mode changes, an
	# origin shift. Lerping the world position directly instead leaves a standing
	# error of v * half_life / ln2, which at orbital speeds parks the ship well
	# off centre and never recovers.
	_current_pos += desired - _prev_desired
	_prev_desired = desired
	# Critically-damped exponential decay of the residual, via half-life.
	var decay: float = exp(-delta * log(2.0) / maxf(position_smoothing_half_life, 0.0001))
	_current_pos = desired + (_current_pos - desired) * decay
	global_position = _current_pos
	# Orientation snaps — minimal rotational lag. Aimed at the target rather than
	# copied outright, so the raised offset frames the ship centred instead of
	# 36% down the screen; roll still comes from the target's own up axis, which
	# is what makes attitude readable.
	var to_target: Vector3 = _target.global_position - global_position
	if to_target.length_squared() > 1e-6:
		global_basis = Basis.looking_at(to_target, _target.global_basis.y)
	else:
		global_basis = _target.global_basis
