extends Node

func _ready() -> void:
	_setup_world()

func _setup_world() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.05, 0.07, 0.15)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.45, 0.5, 0.7)
	env.ambient_light_energy = 0.7
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.light_energy = 0.4
	sun.rotation_degrees = Vector3(-55, 30, 0)
	add_child(sun)

	var cam := Camera3D.new()
	add_child(cam)
	cam.look_at_from_position(Vector3(0, 13, 10), Vector3(0, 0, -1.5), Vector3.UP)

	var player := Player.new()
	player.name = "Player"
	player.position = Vector3(0, 0.9, 4)
	add_child(player)
