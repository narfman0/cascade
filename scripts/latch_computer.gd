class_name LatchComputer extends Node
## Magnetic clamp latching: ship-to-rock anchoring as a physics joint (LD2).
##
## Latching is a locked Generic6DOFJoint3D, never a reparent: both bodies stay
## independent in the physics space, so the never-nest-RigidBody rule is not
## violated, the coupled pair tows under thrust with honest combined-mass
## dynamics, and a jointed body rides a tumbling rock's rotation for free.
##
## Soft-capture conditions mirror docking: contact with a SpaceRock plus
## relative velocity under `latch_speed_limit`. The joint breaks if its anchor
## points are dragged apart past `break_stretch` — an impact jerk or a load
## beyond what the clamps can hold; steady thrust never stretches a locked
## joint that far, so towing is safe and crashing is not.

signal latched(rock: SpaceRock)
signal released(rock: SpaceRock)

@export var latch_speed_limit: float = 0.8
@export var break_stretch: float = 0.6

var latched_rock: SpaceRock = null
## A rock in contact and slow enough to latch — the HUD's "LATCH READY".
var ready_rock: SpaceRock = null

var _ship: RigidBody3D
var _joint: Generic6DOFJoint3D = null
# Anchor points in each body's local space, for the stretch check.
var _local_a: Vector3
var _local_b: Vector3


func _ready() -> void:
	_ship = get_parent() as RigidBody3D


func _unhandled_input(event: InputEvent) -> void:
	if GameState.input_mode != GameState.InputMode.SHIP_FLIGHT:
		return
	if event.is_action_pressed("latch"):
		if latched_rock != null:
			unlatch()
		elif ready_rock != null:
			latch_to(ready_rock)


func _physics_process(_delta: float) -> void:
	if _ship == null:
		return
	if latched_rock != null:
		if not is_instance_valid(latched_rock) or latched_rock.asleep:
			_drop_joint()
			return
		# Break on stretch: the physics solver holds a locked joint tight, so
		# real separation of the anchor points means a load past clamp rating.
		var a: Vector3 = _ship.to_global(_local_a)
		var b: Vector3 = latched_rock.to_global(_local_b)
		if a.distance_to(b) > break_stretch:
			unlatch()
		return

	ready_rock = null
	if GameState.docked or GameState.landed or GameState.autopilot_active:
		return
	for body in _ship.get_colliding_bodies():
		var rock := body as SpaceRock
		if rock == null or rock.asleep:
			continue
		var rel: float = (_ship.linear_velocity - rock.linear_velocity).length()
		if rel <= latch_speed_limit:
			ready_rock = rock
			return


func latch_to(rock: SpaceRock) -> void:
	if latched_rock != null or rock == null or rock.asleep:
		return
	_joint = make_lock_joint(_ship, rock)
	var mid: Vector3 = _joint.global_position
	_local_a = _ship.to_local(mid)
	_local_b = rock.to_local(mid)
	latched_rock = rock
	ready_rock = null
	latched.emit(rock)


func unlatch() -> void:
	if latched_rock == null:
		return
	var rock := latched_rock
	_drop_joint()
	released.emit(rock)


func _drop_joint() -> void:
	if _joint != null:
		_joint.queue_free()
		_joint = null
	latched_rock = null


## A fully locked 6DOF joint between two live bodies, anchored midway between
## them. Default Generic6DOFJoint3D limits (all zero, all enabled) ARE the
## lock — no per-axis configuration needed. Shared with the EVA boot clamps.
static func make_lock_joint(a: PhysicsBody3D, b: PhysicsBody3D) -> Generic6DOFJoint3D:
	var joint := Generic6DOFJoint3D.new()
	# The joint node must be in the tree before node_a/b resolve; parent it to
	# the world so neither body's teardown ordering can strand it.
	a.get_parent().add_child(joint)
	joint.global_position = (a.global_position + b.global_position) * 0.5
	joint.node_a = joint.get_path_to(a)
	joint.node_b = joint.get_path_to(b)
	return joint
