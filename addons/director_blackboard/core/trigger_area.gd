@tool
class_name TriggerArea extends Area3D
## Fires a named event on the owning Zone.
## ENTER: the player or a companion walks in. INTERACT: the player presses E nearby.

enum Mode { ENTER, INTERACT }

@export var event: StringName
@export var mode: Mode = Mode.ENTER
@export var ctx: Dictionary = {}

func _ready() -> void:
	if Engine.is_editor_hint():
		return
	if mode == Mode.ENTER:
		body_entered.connect(_on_body_entered)

func _on_body_entered(body: Node3D) -> void:
	if body.is_in_group(&"Player") or body.is_in_group(&"Companion"):
		_fire()

func interact() -> void:
	if mode == Mode.INTERACT:
		_fire()

func _fire() -> void:
	var node := get_parent()
	while node and not node is Zone:
		node = node.get_parent()
	if node:
		(node as Zone).fire(event, ctx.duplicate())
