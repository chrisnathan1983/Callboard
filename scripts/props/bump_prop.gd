@tool
class_name BumpProp extends Node3D
## Plays a squash animation when the owning Stage accepts the bump.

@export var relay: StringName = &"treat_out"   # also the Blackboard key it latches
@export var bump_area: Area3D
var _stage: Stage

func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_stage = _find_stage()
	if bump_area:
		bump_area.collision_layer = 1 << 2
		bump_area.collision_mask = (1 << 1) | (1 << 3)
		bump_area.body_entered.connect(_on_bump)

func _on_bump(body: Node3D) -> void:
	if not body.is_in_group(&"Player"):
		return
	if not is_instance_valid(_stage) or not _stage.fire_relay_once(relay, relay, &"bump_prop", &"bump"):
		return
	var t := create_tween()
	t.tween_property(self, "scale", Vector3(1.25, 0.75, 1.25), 0.1)
	t.tween_property(self, "scale", Vector3.ONE, 0.3).set_trans(Tween.TRANS_BOUNCE)

func _find_stage() -> Stage:
	var node := get_parent()
	while node and not node is Stage:
		node = node.get_parent()
	return node as Stage
