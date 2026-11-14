@tool
class_name StageRestorationBinding extends Resource
## Applies resolved Blackboard state to a scene node without replaying an animation.

enum Kind { VISIBILITY, TRANSFORM, SNAP_TO_MARKER }

@export var key: StringName
@export var kind: Kind = Kind.VISIBILITY
@export var target_path: NodePath
@export var marker_path: NodePath
@export var animation_player_path: NodePath
@export var animation_name: StringName
@export_range(0.0, 3600.0, 0.01) var animation_time := 0.0

func to_dictionary() -> Dictionary:
	return {
		"key": String(key), "kind": kind, "target_path": String(target_path),
		"marker_path": String(marker_path), "animation_player_path": String(animation_player_path),
		"animation_name": String(animation_name), "animation_time": animation_time,
	}

static func from_dictionary(data: Dictionary) -> StageRestorationBinding:
	var binding := StageRestorationBinding.new()
	binding.key = StringName(data.get("key", ""))
	binding.kind = int(data.get("kind", Kind.VISIBILITY))
	binding.target_path = NodePath(data.get("target_path", ""))
	binding.marker_path = NodePath(data.get("marker_path", ""))
	binding.animation_player_path = NodePath(data.get("animation_player_path", ""))
	binding.animation_name = StringName(data.get("animation_name", ""))
	binding.animation_time = float(data.get("animation_time", 0.0))
	return binding

func apply(stage: Stage) -> void:
	if not is_instance_valid(stage) or not stage.bb.has(key):
		return
	var target := stage.get_node_or_null(target_path)
	if target == null:
		return
	var value: Variant = stage.get_var(key)
	match kind:
		Kind.VISIBILITY:
			if target is CanvasItem or target is Node3D:
				target.visible = bool(value)
		Kind.TRANSFORM:
			if target is Node3D and value is Transform3D:
				(target as Node3D).transform = value
		Kind.SNAP_TO_MARKER:
			if not bool(value) or not target is Node3D:
				return
			var marker := stage.get_node_or_null(marker_path) as Marker3D
			if marker == null:
				return
			(target as Node3D).global_transform = marker.global_transform
			_apply_pose(stage)

func validate(stage: Stage) -> Array[String]:
	var problems: Array[String] = []
	if not stage.bb.has(key):
		problems.append("restoration binding refers to undeclared Blackboard key '%s'" % key)
		return problems
	var value_type: int = stage.bb.schema[stage.bb.resolve_key(key)].get("type", TYPE_NIL)
	var scope: StringName = stage.bb.schema[stage.bb.resolve_key(key)].get("scope", &"local")
	if scope == &"local":
		problems.append("restoration binding key '%s' must use saved or shared scope" % key)
	var target := stage.get_node_or_null(target_path)
	if target == null:
		problems.append("restoration binding target '%s' was not found" % target_path)
	else:
		match kind:
			Kind.VISIBILITY:
				if value_type != TYPE_BOOL:
					problems.append("visibility binding key '%s' must be Boolean" % key)
				if not (target is CanvasItem or target is Node3D):
					problems.append("visibility binding target '%s' must support visible" % target_path)
			Kind.TRANSFORM:
				if value_type != TYPE_TRANSFORM3D:
					problems.append("transform binding key '%s' must contain a Transform3D" % key)
				if not target is Node3D:
					problems.append("transform binding target '%s' must be Node3D" % target_path)
			Kind.SNAP_TO_MARKER:
				if value_type != TYPE_BOOL:
					problems.append("marker binding key '%s' must be Boolean" % key)
				if not target is Node3D:
					problems.append("marker binding target '%s' must be Node3D" % target_path)
	if kind == Kind.SNAP_TO_MARKER:
		var marker := stage.get_node_or_null(marker_path)
		if not marker is Marker3D:
			problems.append("restoration marker '%s' was not found or is not Marker3D" % marker_path)
		if animation_player_path.is_empty() != animation_name.is_empty():
			problems.append("marker restoration must set both AnimationPlayer path and animation name, or neither")
		if not animation_player_path.is_empty():
			var player := stage.get_node_or_null(animation_player_path) as AnimationPlayer
			if player == null:
				problems.append("restoration AnimationPlayer '%s' was not found" % animation_player_path)
			elif not player.has_animation(animation_name):
				problems.append("restoration animation '%s' was not found on '%s'" % [animation_name, animation_player_path])
	elif not animation_player_path.is_empty() or not animation_name.is_empty():
		problems.append("AnimationPlayer pose settings are only supported for marker restoration")
	return problems

func _apply_pose(stage: Stage) -> void:
	if animation_player_path.is_empty() or animation_name.is_empty():
		return
	var player := stage.get_node_or_null(animation_player_path) as AnimationPlayer
	if player == null or not player.has_animation(animation_name):
		return
	player.play(animation_name)
	player.seek(animation_time, true)
	player.pause()
