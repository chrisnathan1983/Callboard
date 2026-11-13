@tool
class_name Stage01Verbs extends StagingVerbs
## Stage 01-specific actions. Project-specific Blackboard keys and actor groups stay here.

func light(n: Node3D, on: bool, duration := 0.0) -> Step:
	return super._light(n, on, duration, &"lamp_on")

func stun_player(seconds: float) -> Step:
	var host := context.host
	return Step.new(func(_context: Dictionary) -> void:
		var player := host.get_tree().get_first_node_in_group(&"Player")
		if player != null and player.has_method("stun"):
			player.call("stun", seconds))
