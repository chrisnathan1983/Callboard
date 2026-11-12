@tool
class_name BumpProp extends Node3D
## A self-contained prefab. It handles its own reaction (squash, Blackboard write),
## then hands off to the Zone with a relay event. It carries no Zone rules.

@export var relay: StringName = &"treat_out"   # also the local Blackboard key it latches

func _ready() -> void:
	if Engine.is_editor_hint():
		return
	(get_node("BumpArea") as Area3D).body_entered.connect(_on_bump)

func _on_bump(body: Node3D) -> void:
	if not body.is_in_group(&"Player"):
		return
	var zone := _find_zone()
	if zone == null or zone.is_set(relay):
		return
	zone.write_var(relay, true)
	zone.rule_fired.emit(&"bump_prop", &"bump")
	var t := create_tween()
	t.tween_property(self, "scale", Vector3(1.25, 0.75, 1.25), 0.1)
	t.tween_property(self, "scale", Vector3.ONE, 0.3).set_trans(Tween.TRANS_BOUNCE)
	zone.fire("relay:" + relay)

func _find_zone() -> Zone:
	var node := get_parent()
	while node and not node is Zone:
		node = node.get_parent()
	return node as Zone
