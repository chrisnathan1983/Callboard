class_name Player extends CharacterBody3D
## Minimal player: WASD / arrows to move, E to interact with nearby TriggerAreas.

const SPEED := 6.0
const LAYER_PLAYER := StageCollisionLayers.PLAYER
const LAYER_TRIGGER := StageCollisionLayers.TRIGGER

var stunned := false
var _stun_timer: SceneTreeTimer
var _reach: Area3D
var _mat := StandardMaterial3D.new()

func _ready() -> void:
	collision_layer = LAYER_PLAYER
	collision_mask = StageCollisionLayers.WORLD
	add_to_group(&"Player")
	_mat.albedo_color = Color(0.85, 0.1, 0.1)
	var body := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.45
	capsule.height = 1.8
	body.mesh = capsule
	body.material_override = _mat
	add_child(body)
	var shape := CollisionShape3D.new()
	var cs := CapsuleShape3D.new()
	cs.radius = 0.45
	cs.height = 1.8
	shape.shape = cs
	add_child(shape)
	_reach = Area3D.new()
	_reach.collision_layer = LAYER_PLAYER
	_reach.collision_mask = LAYER_TRIGGER
	var reach_shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 1.6
	reach_shape.shape = sphere
	_reach.add_child(reach_shape)
	add_child(_reach)

func _physics_process(_delta: float) -> void:
	var dir := Vector3.ZERO
	if not stunned:
		var input := Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_back")
		dir = Vector3(input.x, 0.0, input.y)
	velocity = dir * SPEED
	move_and_slide()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"interact"):
		interact()

func interact() -> void:
	if stunned or _reach == null:
		return
	var nearest: Area3D
	var nearest_distance := INF
	for area in _reach.get_overlapping_areas():
		if not area.has_method(&"interact"):
			continue
		if area is TriggerArea and area.mode != TriggerArea.Mode.INTERACT:
			continue
		var distance := global_position.distance_squared_to(area.global_position)
		if distance < nearest_distance:
			nearest = area
			nearest_distance = distance
	if nearest:
		nearest.interact()

func stun(seconds: float) -> void:
	if _stun_timer:
		_stun_timer.time_left = maxf(_stun_timer.time_left, seconds)
		return
	stunned = true
	_mat.albedo_color = Color(0.5, 0.5, 0.9)
	_stun_timer = get_tree().create_timer(seconds, false)
	_stun_timer.timeout.connect(_end_stun)

func _end_stun() -> void:
	_stun_timer = null
	stunned = false
	_mat.albedo_color = Color(0.85, 0.1, 0.1)
