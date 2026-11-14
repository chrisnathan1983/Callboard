class_name Player extends CharacterBody3D
## Moves with the keyboard or HUD stick and uses the shared interaction resolver.

const SPEED := 6.0
const LAYER_PLAYER := StageCollisionLayers.PLAYER
const LAYER_TRIGGER := StageCollisionLayers.TRIGGER

var stunned := false
var touch_movement := Vector2.ZERO
var _stun_timer: SceneTreeTimer
var _reach: Area3D
var interaction_resolver: InteractionResolver
var _mat := StandardMaterial3D.new()

func _ready() -> void:
	collision_layer = LAYER_PLAYER
	collision_mask = StageCollisionLayers.WORLD
	add_to_group(&"Player")
	_mat.albedo_color = Color("147d7d")
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
	interaction_resolver = InteractionResolver.new()
	interaction_resolver.name = "InteractionResolver"
	add_child(interaction_resolver)
	interaction_resolver.configure(self, _reach)

func _physics_process(_delta: float) -> void:
	var dir := Vector3.ZERO
	if not stunned:
		var keyboard := Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_back")
		var movement := keyboard if not keyboard.is_zero_approx() else touch_movement
		dir = Vector3(movement.x, 0.0, movement.y)
	velocity = dir * SPEED
	move_and_slide()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"interact"):
		interact()

func interact(context: Dictionary = {}) -> Dictionary:
	if stunned or interaction_resolver == null:
		return {"accepted": false, "event": &"", "payload": {}}
	return interaction_resolver.interact(context)

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
	_mat.albedo_color = Color("147d7d")
