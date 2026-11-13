@tool
class_name StepData extends Resource
## Serializable arguments for one verb invocation.

@export var verb: StringName
@export var args := PackedStringArray()
@export var delay := ""

static func from_dictionary(source: Dictionary) -> StepData:
	var data := StepData.new()
	data.verb = StringName(source.get("verb", ""))
	data.args = PackedStringArray(source.get("args", []))
	data.delay = String(source.get("delay", ""))
	return data

func to_dictionary() -> Dictionary:
	return {"verb": String(verb), "args": Array(args), "delay": delay, "emits": "", "sets": []}
