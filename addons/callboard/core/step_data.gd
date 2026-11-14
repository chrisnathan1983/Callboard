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
## Used by conditional groups. The first matching condition wins; the explicit
## default branch is selected only when none of the conditions match.
@export var branch_conditions := PackedStringArray()
@export var default_branch_index := -1
## Random group identity is stable across branch and step reordering.
@export var group_id: StringName = &""
@export_enum("Uniform", "Weighted") var random_selection := 0
@export var random_seed := 1
@export var branch_weights := PackedFloat32Array()

static func from_dictionary(source: Dictionary) -> StepData:
	var data := StepData.new()
	data.verb = StringName(source.get("verb", ""))
	data.args = PackedStringArray(source.get("args", []))
	data.delay = String(source.get("delay", ""))
	data.join_parallel = bool(source.get("join_parallel", true))
	data.branch_conditions = PackedStringArray(source.get("branch_conditions", []))
	data.default_branch_index = int(source.get("default_branch_index", -1))
	data.group_id = StringName(source.get("group_id", ""))
	data.random_selection = int(source.get("random_selection", 0))
	data.random_seed = int(source.get("random_seed", 1))
	data.branch_weights = PackedFloat32Array(source.get("branch_weights", []))
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
		"branch_conditions": Array(branch_conditions), "default_branch_index": default_branch_index,
		"group_id": String(group_id), "random_selection": random_selection,
		"random_seed": random_seed, "branch_weights": Array(branch_weights),
	}
