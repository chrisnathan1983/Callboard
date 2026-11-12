@tool
class_name BumpProp extends Node3D
## Plays a squash animation when the owning Zone accepts the bump.

@export var relay: StringName = &"treat_out"   # also the Blackboard key it latches
@export var bump_area: Area3D

func _ready() -> void:
	if Engine.is_editor_hint():
		return
	if bump_area:
		bump_area.body_entered.connect(_on_bump)

func _on_bump(body: Node3D) -> void:
	if not body.is_in_group(&"Player"):
		return
	var zone := _find_zone()
	if zone == null or not zone.fire_relay_once(relay, relay, &"bump_prop", &"bump"):
		return
	var t := create_tween()
	t.tween_property(self, "scale", Vector3(1.25, 0.75, 1.25), 0.1)
	t.tween_property(self, "scale", Vector3.ONE, 0.3).set_trans(Tween.TRANS_BOUNCE)

func _find_zone() -> Zone:
	var node := get_parent()
	while node and not node is Zone:
		node = node.get_parent()
	return node as Zone
