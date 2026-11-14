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

func _process(_delta: float) -> void:
	if not Engine.is_editor_hint():
		refresh()

## Bind the actor and its overlap Area3D. Call refresh() after changing actor state when needed;
## normal runtime polling also notices eligibility or prompt changes while the actor stays in range.
func configure(p_actor: Node3D, p_reach_area: Area3D) -> void:
	actor = p_actor
	reach_area = p_reach_area
	refresh()

## Choose the highest-priority eligible trigger, then the nearest one, then its node path.
func refresh() -> void:
	var eligible: Array[TriggerArea] = []
	if is_instance_valid(actor) and is_instance_valid(reach_area) and reach_area.is_inside_tree():
		for area in reach_area.get_overlapping_areas():
			if area is TriggerArea and (area as TriggerArea).can_interact(actor):
				eligible.append(area as TriggerArea)
	eligible.sort_custom(_comes_before)
	var next: TriggerArea = eligible[0] if not eligible.is_empty() else null
	var selection_changed := selected_trigger != next
	if selection_changed:
		selected_trigger = next
		selected_trigger_changed.emit()
	var next_text := next.prompt_text if next != null else ""
	var next_icon: Texture2D = next.prompt_icon if next != null else null
	var next_priority := next.interaction_priority if next != null else 0
	if selection_changed or next_text != _prompt_text or next_icon != _prompt_icon or next_priority != _prompt_priority:
		_prompt_text = next_text
		_prompt_icon = next_icon
		_prompt_priority = next_priority
		prompt_changed.emit(_prompt_text, _prompt_icon, _prompt_priority)

## Resolve again before dispatch so stale prompts cannot interact with unavailable triggers.
func interact(context: Dictionary = {}) -> Dictionary:
	refresh()
	if selected_trigger == null:
		return {"accepted": false, "event": &"", "payload": {}}
	var trigger := selected_trigger
	var result := trigger.interact(actor, context)
	interaction_completed.emit(trigger, result)
	return result

func _comes_before(a: TriggerArea, b: TriggerArea) -> bool:
	if a.interaction_priority != b.interaction_priority:
		return a.interaction_priority > b.interaction_priority
	var a_distance := actor.global_position.distance_squared_to(a.global_position)
	var b_distance := actor.global_position.distance_squared_to(b.global_position)
	if a_distance != b_distance:
		return a_distance < b_distance
	return String(a.get_path()) < String(b.get_path())
