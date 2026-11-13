@tool
class_name TriggerArea extends Area3D
## Fires a named event on the owning Stage.
## ENTER fires for a Player or Companion body entering the area.
## INTERACT fires when gameplay calls interact().

enum Mode { ENTER, INTERACT }

const LAYER_TRIGGER := StageCollisionLayers.TRIGGER
const LAYER_PLAYER := StageCollisionLayers.PLAYER
const LAYER_COMPANION := StageCollisionLayers.COMPANION

@export var event: StringName
@export var mode: Mode = Mode.ENTER
@export var ctx: Dictionary = {}
var _stage: Stage

func _ready() -> void:
	if Engine.is_editor_hint():
		return
	collision_layer = LAYER_TRIGGER
	collision_mask = LAYER_PLAYER | LAYER_COMPANION
	_stage = _find_stage()
	if mode == Mode.ENTER:
		body_entered.connect(_on_body_entered)

func _on_body_entered(body: Node3D) -> void:
	if body.is_in_group(&"Player") or body.is_in_group(&"Companion"):
		_fire()

func interact() -> void:
	if mode == Mode.INTERACT:
		_fire()

func _fire() -> void:
	if is_instance_valid(_stage):
		_stage.fire(event, ctx.duplicate())

func _find_stage() -> Stage:
	var node := get_parent()
	while node and not node is Stage:
		node = node.get_parent()
	return node as Stage
