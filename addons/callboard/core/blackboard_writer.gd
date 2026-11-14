@tool
class_name BlackboardWriter extends Node
## Scene component that declares and publishes external Blackboard values.

@export var callboard_writers: Array[BlackboardWriterData] = []

func publish(key: StringName, value: Variant) -> void:
	var stage := _find_stage()
	if stage == null:
		if OS.is_debug_build():
			push_warning("BlackboardWriter '%s' has no Stage ancestor." % name)
		return
	var source := name
	for writer: BlackboardWriterData in callboard_writers:
		if writer != null and writer.key == key:
			if not writer.source.is_empty():
				source = writer.source
			break
	stage.write_var(key, value, source)

func _find_stage() -> Stage:
	var ancestor := get_parent()
	while ancestor != null:
		if ancestor is Stage:
			return ancestor as Stage
		ancestor = ancestor.get_parent()
	return null
