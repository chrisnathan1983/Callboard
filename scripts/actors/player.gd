class_name Player extends CharacterBody3D
## Minimal player: WASD / arrows to move, E to interact with nearby TriggerAreas.

const SPEED := 6.0

var stunned := false
var _reach: Area3D
var _mat := StandardMaterial3D.new()

func _ready() -> void:
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
	var reach_shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 1.6
	reach_shape.shape = sphere
	_reach.add_child(reach_shape)
	add_child(_reach)

func _physics_process(_delta: float) -> void:
	var dir := Vector3.ZERO
	if not stunned:
		if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP): dir.z -= 1
		if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN): dir.z += 1
		if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT): dir.x -= 1
		if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT): dir.x += 1
	velocity = dir.normalized() * SPEED
	move_and_slide()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_E and not stunned:
		interact()

func interact() -> void:
	for area in _reach.get_overlapping_areas():
		if area.has_method(&"interact"):
			area.interact()

func stun(seconds: float) -> void:
	stunned = true
	_mat.albedo_color = Color(0.5, 0.5, 0.9)
	await get_tree().create_timer(seconds).timeout
	stunned = false
	_mat.albedo_color = Color(0.85, 0.1, 0.1)
