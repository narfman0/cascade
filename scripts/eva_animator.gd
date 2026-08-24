class_name EvaAnimator extends Node
## Drives the suit's AnimationPlayer from the EVA walk state (Track AN).
##
## Sits on the suit (Character); finds the imported gltf's own AnimationPlayer
## (its track paths are "Root/Skeleton3D:bone", the same paths the baked
## library uses) and adds res://assets/anims/eva_locomotion.res as "loco".
## Pure state-watcher: the walk simulation in eva_controller stays the only
## authority on movement; this maps its state to clips.
##
##   grounded  speed<0.4  → idle
##   grounded  speed<2.6  → walk (playback scaled so feet track the ground)
##   grounded  faster     → run
##   airborne  rising     → jump (one-shot, holds last pose into the fall)
##   airborne  falling    → fall (loop)
##   touchdown            → land_soft/medium/hard by impact speed, then idle
##
## Off the ground (free EVA / clamped to a rock) the suit holds the cook's
## drifting take pose — a dedicated zero-g idle is Track AN stretch.

const LIB := "res://assets/anims/eva_locomotion.res"

## Reference speeds the source cycles were authored at (m/s, eyeballed from
## the pack's stride length after retarget) — playback scales against these.
const WALK_REF := 1.4
const RUN_REF := 4.2

var _suit: RigidBody3D
var _player: AnimationPlayer
var _state: StringName = &""
var _was_airborne: bool = false
var _prev_vrad: float = 0.0


func _ready() -> void:
	_suit = get_parent() as RigidBody3D
	var suit_scene := _suit.get_node_or_null("Suit")
	if suit_scene:
		_player = suit_scene.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if _player == null or not ResourceLoader.exists(LIB):
		set_physics_process(false)
		return
	_player.add_animation_library("loco", load(LIB))


func _physics_process(_delta: float) -> void:
	if _suit.get("clamped_body") == null:
		# Not walking: release to the pose the cook take left. A one-shot
		# land clip that was playing keeps finishing — harmless.
		if _state != &"" and _state.begins_with("loco"):
			_state = &""
		_was_airborne = false
		return

	var vel: Vector3 = _suit.get("_walk_vel")
	var airborne: bool = _suit.get("_walk_airborne")
	var up: Vector3 = (_suit.transform.origin as Vector3).normalized()
	var v_rad: float = vel.dot(up)
	var speed: float = (vel - up * v_rad).length()

	if airborne:
		_play(&"loco/jump" if v_rad > 0.2 else &"loco/fall")
	elif _was_airborne:
		# Touchdown: weight class from how hard we came down last tick.
		var impact: float = absf(minf(_prev_vrad, 0.0))
		if impact > 4.0:
			_play(&"loco/land_hard")
		elif impact > 2.0:
			_play(&"loco/land_medium")
		else:
			_play(&"loco/land_soft")
	elif _state.begins_with("loco/land") and _player.is_playing() and speed < 0.4:
		pass  # let the landing finish before standing up
	elif speed < 0.4:
		_play(&"loco/idle")
	elif speed < 2.6:
		_play(&"loco/walk", speed / WALK_REF)
	else:
		_play(&"loco/run", speed / RUN_REF)

	_was_airborne = airborne
	_prev_vrad = v_rad


func _play(clip: StringName, scale_speed: float = 1.0) -> void:
	if _state != clip:
		_state = clip
		_player.play(clip, 0.15)
	_player.speed_scale = clampf(scale_speed, 0.6, 1.6)


## What the gates assert against.
func current_clip() -> StringName:
	return _state
