@tool
class_name TriggerArea extends Area3D
## Presents an optional prompt and dispatches one named event on the owning Stage.
## ENTER fires for a Player or Companion body entering the area.
## INTERACT fires when gameplay calls interact().

enum Mode { ENTER, INTERACT }

signal interaction_completed(actor: Node, result: Dictionary)

const LAYER_TRIGGER := StageCollisionLayers.TRIGGER
const LAYER_PLAYER := StageCollisionLayers.PLAYER
const LAYER_COMPANION := StageCollisionLayers.COMPANION

@export var event: StringName
@export var rejected_event: StringName
@export var mode: Mode = Mode.ENTER
@export var ctx: Dictionary = {}
@export_multiline var prompt_text := "Interact"
@export var prompt_icon: Texture2D
@export var interaction_priority := 0
var _stage: Stage
var _eligibility_hook: Callable
var _interaction_handler: Callable

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

## Set a game-owned predicate; it receives the actor and can inspect inventory or other host state.
func set_eligibility_hook(hook: Callable) -> void:
	_eligibility_hook = hook

## Set a game-owned handler that returns `{accepted: bool, payload: Dictionary}`.
func set_interaction_handler(handler: Callable) -> void:
	_interaction_handler = handler

func can_interact(actor: Node) -> bool:
	if mode != Mode.INTERACT or not is_inside_tree():
		return false
	if _eligibility_hook.is_valid() and not bool(_eligibility_hook.call(actor)):
		return false
	return is_interaction_eligible(actor)

## Override in a TriggerArea subclass for scene-specific eligibility.
func is_interaction_eligible(_actor: Node) -> bool:
	return true

## Handle an attempt. Projects own item checks, consumption, and policy in this hook.
func handle_interaction(_actor: Node, interaction_context: Dictionary) -> Dictionary:
	return {"accepted": true, "payload": interaction_context.duplicate(true)}

## Dispatch through the same accepted/rejected outcome path used by InteractionResolver.
func interact(actor: Node = null, interaction_context: Dictionary = {}) -> Dictionary:
	if not can_interact(actor):
		return {"accepted": false, "event": &"", "payload": {}}
	var context := ctx.duplicate(true)
	context.merge(interaction_context, true)
	var outcome: Variant = _interaction_handler.call(actor, context) if _interaction_handler.is_valid() else handle_interaction(actor, context)
	if not outcome is Dictionary:
		push_warning("TriggerArea '%s' handler must return a Dictionary." % name)
		outcome = {"accepted": false, "payload": {}}
	var payload: Variant = outcome.get("payload", {})
	if not payload is Dictionary:
		push_warning("TriggerArea '%s' handler payload must be a Dictionary." % name)
		payload = {}
	var accepted := bool(outcome.get("accepted", false))
	var dispatched_event := event if accepted else rejected_event
	if not dispatched_event.is_empty() and is_instance_valid(_stage):
		_stage.fire(dispatched_event, payload)
	var result := {"accepted": accepted, "event": dispatched_event, "payload": payload.duplicate(true)}
	interaction_completed.emit(actor, result)
	return result

func _fire() -> void:
	if is_instance_valid(_stage):
		_stage.fire(event, ctx.duplicate())

func _find_stage() -> Stage:
	var node := get_parent()
	while node and not node is Stage:
		node = node.get_parent()
	return node as Stage
