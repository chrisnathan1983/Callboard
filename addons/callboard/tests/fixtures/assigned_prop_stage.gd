@tool
class_name AssignedPropStageFixture extends Stage

@onready var target: MeshInstance3D = $Target
@export var assigned_target: Node3D

func can_reuse_analysis_props() -> bool:
	return true

func _build_props() -> void:
	set_meta(&"fixture_build_props_count", int(get_meta(&"fixture_build_props_count", 0)) + 1)
