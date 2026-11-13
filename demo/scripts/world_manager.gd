extends Node3D

func _ready() -> void:
	# The player lives outside the Stage so it survives a Stage reload.
	# Stage01Verbs can reach the actor through its Player group.
	var player := Player.new()
	player.name = "Player"
	player.position = $PlayerSpawn.position
	add_child(player)
