extends Node3D

@onready var _camera: Camera3D = $Camera

func _ready() -> void:
	# The player lives outside the Stage so it survives a Stage reload.
	# Stage01Verbs can reach the actor through its Player group.
	var player := Player.new()
	player.name = "Player"
	player.position = $PlayerSpawn.position
	add_child(player)
	get_window().size_changed.connect(_frame_stage)
	_frame_stage()

func _frame_stage() -> void:
	var window := get_window()
	var portrait := window.size.x < window.size.y
	var ui_size := Vector2i(640, 900) if portrait else Vector2i(1280, 720)
	if window.content_scale_size != ui_size:
		window.content_scale_size = ui_size
	# Fit all four stations across a narrow screen.
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL if portrait else Camera3D.PROJECTION_PERSPECTIVE
	_camera.keep_aspect = Camera3D.KEEP_WIDTH if portrait else Camera3D.KEEP_HEIGHT
	_camera.size = 19.0
