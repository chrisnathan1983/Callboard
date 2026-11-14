@tool
class_name InteractionResolver extends Node
## Chooses one eligible TriggerArea for an actor and exposes a shared prompt/interaction API.

signal selected_trigger_changed
signal prompt_changed(text: String, icon: Texture2D, priority: int)
signal interaction_completed(trigger: Node, result: Dictionary)

var actor: Node3D
var reach_area: Area3D
var selected_trigger: TriggerArea

var _prompt_text := ""
var _prompt_icon: Texture2D
var _prompt_priority := 0
var _context_provider: Callable
var _watched_triggers: Dictionary = {}
var _explicit_context: Dictionary = {}

func _process(_delta: float) -> void:
	if not Engine.is_editor_hint():
		refresh(_explicit_context)

## Bind the actor, overlap Area3D, and optional provider for live host context.
## The provider receives the actor and returns a Dictionary (for example, held_item).
func configure(p_actor: Node3D, p_reach_area: Area3D, p_context_provider: Callable = Callable()) -> void:
	actor = p_actor
	reach_area = p_reach_area
	_context_provider = p_context_provider
	refresh()

## Set live context used when checking eligibility and resolving dynamic prompts.
func set_context_provider(provider: Callable) -> void:
	_context_provider = provider
	refresh()

## Choose the highest-priority eligible trigger, then the nearest one, then its node path.
func refresh(interaction_context: Dictionary = {}) -> void:
	_explicit_context = interaction_context.duplicate(true)
	_refresh_context(_resolve_context(_explicit_context))

func _refresh_context(context: Dictionary) -> void:
	var eligible: Array[TriggerArea] = []
	var overlapping: Array[TriggerArea] = []
	if is_instance_valid(actor) and is_instance_valid(reach_area) and reach_area.is_inside_tree():
		for area in reach_area.get_overlapping_areas():
			if area is TriggerArea:
				var trigger := area as TriggerArea
				overlapping.append(trigger)
				if trigger.can_interact(actor, context):
					eligible.append(trigger)
	_sync_trigger_subscriptions(overlapping)
	eligible.sort_custom(_comes_before)
	var next: TriggerArea = eligible[0] if not eligible.is_empty() else null
	var selection_changed := selected_trigger != next
	if selection_changed:
		selected_trigger = next
		selected_trigger_changed.emit()
	var next_prompt := next.resolve_prompt(actor, context) if next != null else {"text": "", "icon": null}
	var next_text: String = next_prompt["text"]
	var next_icon: Texture2D = next_prompt["icon"]
	var next_priority := next.interaction_priority if next != null else 0
	if selection_changed or next_text != _prompt_text or next_icon != _prompt_icon or next_priority != _prompt_priority:
		_prompt_text = next_text
		_prompt_icon = next_icon
		_prompt_priority = next_priority
		prompt_changed.emit(_prompt_text, _prompt_icon, _prompt_priority)

## Resolve again before dispatch so stale prompts cannot interact with unavailable triggers.
func interact(context: Dictionary = {}) -> Dictionary:
	var interaction_context := _resolve_context(context)
	_refresh_context(interaction_context)
	if selected_trigger == null:
		return {"accepted": false, "event": &"", "payload": {}}
	var trigger := selected_trigger
	var result := trigger.interact(actor, interaction_context)
	interaction_completed.emit(trigger, result)
	return result

func _resolve_context(explicit_context: Dictionary) -> Dictionary:
	var context := {}
	if _context_provider.is_valid():
		var provided: Variant = _context_provider.call(actor)
		if provided is Dictionary:
			context = provided.duplicate(true)
		else:
			push_warning("InteractionResolver context provider must return a Dictionary.")
	context.merge(explicit_context, true)
	return context

func _sync_trigger_subscriptions(overlapping: Array[TriggerArea]) -> void:
	var current: Dictionary = {}
	for trigger: TriggerArea in overlapping:
		var id := trigger.get_instance_id()
		current[id] = weakref(trigger)
		if not _watched_triggers.has(id):
			trigger.interaction_state_changed.connect(_on_trigger_state_changed)
	for id in _watched_triggers.keys():
		if current.has(id):
			continue
		var reference: WeakRef = _watched_triggers[id]
		var trigger := reference.get_ref() as TriggerArea if reference != null else null
		if is_instance_valid(trigger) and trigger.interaction_state_changed.is_connected(_on_trigger_state_changed):
			trigger.interaction_state_changed.disconnect(_on_trigger_state_changed)
	_watched_triggers = current

func _on_trigger_state_changed() -> void:
	refresh(_explicit_context)

func _comes_before(a: TriggerArea, b: TriggerArea) -> bool:
	if a.interaction_priority != b.interaction_priority:
		return a.interaction_priority > b.interaction_priority
	var a_distance := actor.global_position.distance_squared_to(a.global_position)
	var b_distance := actor.global_position.distance_squared_to(b.global_position)
	if a_distance != b_distance:
		return a_distance < b_distance
	return String(a.get_path()) < String(b.get_path())
