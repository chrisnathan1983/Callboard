@tool
class_name TriggerArea extends Area3D
## Presents an optional prompt and dispatches one named event on the owning Stage.
## ENTER fires for a Player or Companion body entering the area.
## INTERACT fires when gameplay calls interact().

enum Mode { ENTER, INTERACT }

const CallboardLocalizationScript := preload("res://addons/callboard/core/callboard_localization.gd")

signal interaction_completed(actor: Node, result: Dictionary)
signal interaction_state_changed

const LAYER_TRIGGER := StageCollisionLayers.TRIGGER
const LAYER_PLAYER := StageCollisionLayers.PLAYER
const LAYER_COMPANION := StageCollisionLayers.COMPANION

## Replaces the scene's collision_mask at runtime. -1 leaves its configured mask intact.
@export var collision_mask_override: int = -1

@export var event: StringName
## Optional Call fired when a body that entered while the Stage accepted Calls exits.
@export var exit_event: StringName
@export var rejected_event: StringName
@export var mode: Mode = Mode.ENTER
## Bodies in any listed group can activate ENTER. An empty list accepts every body.
## The default preserves the original Player/Companion behavior.
@export var trigger_groups: Array[StringName] = [&"Player", &"Companion"]
@export var ctx: Dictionary = {}
@export_multiline var prompt_text := "Interact"
## Optional translation key. When set, this takes precedence over prompt_text.
@export var prompt_translation_key: StringName
## Literal fallback used when the active locale has no translation for the key.
@export_multiline var prompt_fallback_text := ""
@export var prompt_substitutions: Dictionary = {}
@export var prompt_icon: Texture2D
@export var interaction_priority := 0
@export var interaction_enabled := true:
	set(value):
		if interaction_enabled == value:
			return
		interaction_enabled = value
		interaction_state_changed.emit()
var _stage: Stage
var _eligibility_hook: Callable
var _interaction_handler: Callable
var _prompt_provider: Callable
var _active_contact_ids: Dictionary = {}

func _init() -> void:
	# Preserve the original runtime defaults while allowing scene-authored values to override them.
	collision_layer = LAYER_TRIGGER
	collision_mask = LAYER_PLAYER | LAYER_COMPANION

func _ready() -> void:
	if Engine.is_editor_hint():
		return
	if collision_mask_override >= 0:
		collision_mask = collision_mask_override
	_stage = _find_stage()
	if mode == Mode.ENTER:
		body_entered.connect(_on_body_entered)
		if not exit_event.is_empty():
			body_exited.connect(_on_body_exited)

func _on_body_entered(body: Node3D) -> void:
	if not _matches_trigger_groups(body):
		return
	if not exit_event.is_empty() and is_instance_valid(_stage) and _stage.accepts_calls():
		_active_contact_ids[body.get_instance_id()] = true
	_fire(event, _contact_payload(body))

func _on_body_exited(body: Node3D) -> void:
	var body_id := body.get_instance_id()
	if not _active_contact_ids.erase(body_id):
		return
	if _matches_trigger_groups(body):
		_fire(exit_event, _contact_payload(body))

func _contact_payload(body: Node3D) -> Dictionary:
	var groups: Array[StringName] = []
	for group_name in body.get_groups():
		groups.append(group_name)
	var body_info := {
		"name": String(body.name),
		"path": String(body.get_path()) if body.is_inside_tree() else "",
		"instance_id": body.get_instance_id(),
		"groups": groups,
	}
	var payload := ctx.duplicate(true)
	payload["body"] = body_info
	return payload

func _matches_trigger_groups(body: Node) -> bool:
	if trigger_groups.is_empty():
		return true
	for group_name: StringName in trigger_groups:
		if body.is_in_group(group_name):
			return true
	return false

## Set a game-owned predicate; it receives the actor and can inspect inventory or other host state.
func set_eligibility_hook(hook: Callable) -> void:
	_eligibility_hook = hook
	interaction_state_changed.emit()

## Provide a dynamic prompt dictionary: {"text": String, "icon": Texture2D}.
## The callback receives (actor, context); omitted fields use authored defaults.
func set_prompt_provider(provider: Callable) -> void:
	_prompt_provider = provider
	interaction_state_changed.emit()

## Enable or disable this INTERACT target without requiring an overlap transition.
func set_interaction_enabled(enabled: bool) -> void:
	interaction_enabled = enabled

## Set a game-owned handler that returns `{accepted: bool, payload: Dictionary}`.
func set_interaction_handler(handler: Callable) -> void:
	_interaction_handler = handler

func can_interact(actor: Node, interaction_context: Dictionary = {}) -> bool:
	if mode != Mode.INTERACT or not interaction_enabled or not is_inside_tree():
		return false
	if is_instance_valid(_stage) and not _stage.accepts_calls():
		return false
	if _eligibility_hook.is_valid() and not bool(_call_context_hook(_eligibility_hook, actor, interaction_context)):
		return false
	return is_interaction_eligible(actor)

## Resolve dynamic prompt values using host context and current Stage state.
func resolve_prompt(actor: Node, interaction_context: Dictionary = {}) -> Dictionary:
	var default_text := prompt_text
	if not prompt_translation_key.is_empty():
		default_text = CallboardLocalizationScript.resolve(prompt_translation_key, prompt_substitutions, prompt_fallback_text)
	var resolved := {"text": default_text, "icon": prompt_icon}
	if not _prompt_provider.is_valid():
		return resolved
	var supplied: Variant = _prompt_provider.call(actor, interaction_context.duplicate(true))
	if not supplied is Dictionary:
		push_warning("TriggerArea '%s' prompt provider must return a Dictionary." % name)
		return resolved
	if supplied.has("text"):
		if supplied["text"] is String:
			resolved["text"] = supplied["text"]
		else:
			push_warning("TriggerArea '%s' prompt text must be a String." % name)
	elif supplied.has("translation_key"):
		var key: Variant = supplied["translation_key"]
		var substitutions: Variant = supplied.get("substitutions", {})
		var fallback: Variant = supplied.get("fallback", "")
		if key is String or key is StringName:
			if substitutions is Dictionary and fallback is String:
				resolved["text"] = CallboardLocalizationScript.resolve(StringName(key), substitutions, fallback)
			else:
				push_warning("TriggerArea '%s' prompt substitutions and fallback have invalid types." % name)
		else:
			push_warning("TriggerArea '%s' prompt translation_key must be a String or StringName." % name)
	if supplied.has("icon"):
		if supplied["icon"] == null or supplied["icon"] is Texture2D:
			resolved["icon"] = supplied["icon"]
		else:
			push_warning("TriggerArea '%s' prompt icon must be a Texture2D or null." % name)
	return resolved

func _call_context_hook(hook: Callable, actor: Node, interaction_context: Dictionary) -> Variant:
	return hook.call(actor, interaction_context.duplicate(true)) if hook.get_argument_count() >= 2 else hook.call(actor)

## Override in a TriggerArea subclass for scene-specific eligibility.
func is_interaction_eligible(_actor: Node) -> bool:
	return true

## Handle an attempt. Projects own item checks, consumption, and policy in this hook.
func handle_interaction(_actor: Node, interaction_context: Dictionary) -> Dictionary:
	return {"accepted": true, "payload": interaction_context.duplicate(true)}

## Dispatch through the same accepted/rejected outcome path used by InteractionResolver.
func interact(actor: Node = null, interaction_context: Dictionary = {}) -> Dictionary:
	var context := ctx.duplicate(true)
	context.merge(interaction_context, true)
	if not can_interact(actor, context):
		return {"accepted": false, "event": &"", "payload": {}}
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

func _fire(call_event: StringName, payload: Dictionary) -> void:
	if not call_event.is_empty() and is_instance_valid(_stage):
		_stage.fire(call_event, payload)

func _find_stage() -> Stage:
	var node := get_parent()
	while node and not node is Stage:
		node = node.get_parent()
	return node as Stage
