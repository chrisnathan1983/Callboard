class_name DemoWorld extends Node3D
## Adapts Callboard's typed camera requests to the demo's persistent camera.

var controls := StageControlAdapter.new()
var _gameplay_pose: Transform3D
var _gameplay_size: float
var _shot: StageControlAdapter.CameraRequest
var _shake: StageControlAdapter.CameraRequest
var _shot_tween: Tween
var _shake_time := 0.0
@onready var _camera: Camera3D = $Camera
@onready var _reception_shot: Marker3D = $ReceptionShot

func _ready() -> void:
	# The player lives outside the Stage so it survives a Stage reload.
	# GameManager handles Stage gameplay events for this persistent actor.
	var player := Player.new()
	player.name = "Player"
	player.position = $PlayerSpawn.position
	add_child(player)
	_gameplay_pose = _camera.global_transform
	_gameplay_size = _camera.size
	controls.state_changed.connect(_update_camera)
	set_process(false)
	get_window().size_changed.connect(_frame_stage)
	_frame_stage()

func _update_camera() -> void:
	# Compare the effective requests so changing shake leaves an in-flight
	# shot blend alone. Releasing a request can also reveal a previous owner.
	var shot := controls.camera_request()
	if shot != _shot:
		_shot = shot
		_blend_camera_shot(shot)
	var shake := controls.shake_request()
	if shake != _shake:
		_shake = shake
		_shake_time = 0.0
		_camera.h_offset = 0.0
		_camera.v_offset = 0.0
		set_process(shake != null)

func _blend_camera_shot(shot: StageControlAdapter.CameraRequest) -> void:
	var pose := _gameplay_pose
	var size := _gameplay_size
	var duration := 0.35
	if shot != null:
		duration = shot.blend_seconds
		match shot.kind:
			StageControlAdapter.CameraRequest.Kind.FOCUS:
				# Keep the gameplay pitch and center the shot on the prop.
				var target := shot.target
				if is_instance_valid(target) and target.is_inside_tree():
					pose.origin = target.global_position + _gameplay_pose.basis.z * 5.25
					size = 6.0
			StageControlAdapter.CameraRequest.Kind.FRAME:
				match shot.shot:
					&"reception":
						pose = _reception_shot.global_transform
						size = 11.0
					&"gameplay":
						# The intro asks for a timed return while it still owns the input lock.
						pass

	# A replacement starts from the current view, including when Reload or
	# Switch office interrupts the celebration halfway through a blend.
	if _shot_tween != null:
		_shot_tween.kill()
	if duration <= 0.0:
		_camera.global_transform = pose
		_camera.size = size
		return
	_shot_tween = create_tween().set_parallel().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_shot_tween.tween_property(_camera, ^"global_transform", pose, duration)
	_shot_tween.tween_property(_camera, ^"size", size, duration)

func _process(delta: float) -> void:
	# Camera-local offsets keep the shake independent of the shot tween.
	_shake_time += delta
	var phase := _shake_time * _shake.frequency * TAU
	_camera.h_offset = sin(phase) * _shake.strength
	_camera.v_offset = sin(phase * 0.73) * _shake.strength * 0.6

func _frame_stage() -> void:
	var window := get_window()
	var portrait := window.size.x < window.size.y
	var ui_size := Vector2i(640, 900) if portrait else Vector2i(1280, 720)
	if window.content_scale_size != ui_size:
		window.content_scale_size = ui_size
	# Fit all four stations across a narrow screen.
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL if portrait else Camera3D.PROJECTION_PERSPECTIVE
	_camera.keep_aspect = Camera3D.KEEP_WIDTH if portrait else Camera3D.KEEP_HEIGHT
