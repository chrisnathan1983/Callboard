@tool
class_name RuleData extends Resource
## Serializable, inspector-editable authored rule.

@export var id: StringName
@export var trigger: StringName
@export var requires := PackedStringArray()
@export var forbids := PackedStringArray()
@export var cancel_if := PackedStringArray()
@export var one_shot := false
@export var reentry := Rule.ReentryPolicy.IGNORE
@export var allow_overlap := false
@export var emit: StringName
@export var state_key: StringName
@export var steps: Array[StepData] = []
@export var group := ""
@export var pos := Vector2.ZERO
@export var has_pos := false

static func from_dictionary(source: Dictionary) -> RuleData:
	var data := RuleData.new()
	data.id = StringName(source.get("id", ""))
	data.trigger = StringName(source.get("trigger", ""))
	data.requires = PackedStringArray(source.get("requires", []))
	data.forbids = PackedStringArray(source.get("forbids", []))
	data.cancel_if = PackedStringArray(source.get("cancel_if", []))
	data.one_shot = bool(source.get("one_shot", source.get("once", false)))
	data.reentry = int(source.get("reentry", Rule.ReentryPolicy.IGNORE))
	data.allow_overlap = bool(source.get("allow_overlap", false))
	data.emit = StringName(source.get("emit", ""))
	data.state_key = StringName(source.get("state_key", source.get("id", "")))
	data.group = String(source.get("group", ""))
	data.pos = source.get("pos", Vector2.ZERO)
	data.has_pos = bool(source.get("has_pos", false))
	for step in source.get("steps", []):
		data.steps.append(step if step is StepData else StepData.from_dictionary(step))
	return data

func to_dictionary() -> Dictionary:
	var step_data: Array[Dictionary] = []
	for step in steps:
		step_data.append(step.to_dictionary())
	return {
		"id": String(id), "trigger": String(trigger), "requires": _strings(requires),
		"forbids": _strings(forbids), "cancel_if": _strings(cancel_if), "one_shot": one_shot,
		"reentry": reentry, "allow_overlap": allow_overlap, "emit": String(emit),
		"state_key": String(state_key), "steps": step_data, "group": group,
		"pos": pos, "has_pos": has_pos,
	}

static func _strings(source: PackedStringArray) -> Array[String]:
	var result: Array[String] = []
	for value in source:
		result.append(String(value))
	return result
