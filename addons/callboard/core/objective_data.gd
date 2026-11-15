@tool
class_name ObjectiveData extends Resource
## A named Blackboard completion condition for Callboard's authoring analysis.

@export var id: StringName
@export var condition := ""

static func from_dictionary(source: Dictionary) -> ObjectiveData:
	var objective := ObjectiveData.new()
	objective.id = StringName(source.get("id", ""))
	objective.condition = String(source.get("condition", ""))
	return objective

func to_dictionary() -> Dictionary:
	return {"id": String(id), "condition": condition}
