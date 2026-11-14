@tool
class_name Stage01Verbs extends StagingVerbs
## Stage 01-specific actions. Project-specific Blackboard keys and actor groups stay here.

# Verb methods build Steps when Callboard compiles the graph. Put gameplay
# effects inside the Step so they run only when a matching rule executes.
# Typed parameters and defaults tell Callboard what arguments to offer.
func stun_player(seconds: float) -> Step:
	var host := context.host
	return Step.new(func(_context: Dictionary) -> void:
		# Resolve the player at execution time. It belongs to the game scene,
		# so a Stage opened in Callboard's preview does not need a Player node.
		var player := host.get_tree().get_first_node_in_group(&"Player")
		if player != null and player.has_method("stun"):
			player.call("stun", seconds))
