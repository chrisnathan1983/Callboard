@tool
class_name StepData extends Resource
## Serializable arguments for one verb invocation.

@export var verb: StringName
@export var args := PackedStringArray()
@export var delay := ""
## Parallel groups contain authored child sequences. Each branch is an ordered
## Array[StepData]; Array[Array] keeps this serializable in Godot resources.
@export var parallel_branches: Array[Array] = []
@export var join_parallel := true

static func from_dictionary(source: Dictionary) -> StepData:
	var data := StepData.new()
	data.verb = StringName(source.get("verb", ""))
	data.args = PackedStringArray(source.get("args", []))
	data.delay = String(source.get("delay", ""))
	data.join_parallel = bool(source.get("join_parallel", true))
	for source_branch in source.get("parallel_branches", []):
		var branch: Array = []
		for source_step in source_branch:
			branch.append(source_step if source_step is StepData else StepData.from_dictionary(source_step))
		data.parallel_branches.append(branch)
	return data

func to_dictionary() -> Dictionary:
	var branches: Array[Array] = []
	for branch in parallel_branches:
		var serialized_branch: Array[Dictionary] = []
		for step: StepData in branch:
			serialized_branch.append(step.to_dictionary())
		branches.append(serialized_branch)
	return {
		"verb": String(verb), "args": Array(args), "delay": delay,
		"parallel_branches": branches, "join_parallel": join_parallel,
	}
