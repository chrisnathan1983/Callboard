@tool
class_name StageRestorationBinding extends Resource
## Applies resolved Blackboard state to a scene node without replaying an animation.

enum Kind { VISIBILITY, TRANSFORM, SNAP_TO_MARKER, POSE_ANIMATION, CHILD_INDEX, PROPERTY, LIGHT_ENERGY, LIGHT_COLOR, AUDIO_PLAYBACK, PARTICLE_EMITTING }

@export var key: StringName
@export var kind: Kind = Kind.VISIBILITY
@export var target_path: NodePath
@export var marker_path: NodePath
@export var animation_player_path: NodePath
@export var animation_name: StringName
@export_range(0.0, 3600.0, 0.01) var animation_time := 0.0
@export var child_choices: Array[NodePath] = []
@export var property_name: StringName
## Audio clips are transient by default. Enable only for stateful/looping audio.
@export var replay_audio_on_restore := false

func to_dictionary() -> Dictionary:
	return {
		"key": String(key), "kind": kind, "target_path": String(target_path),
		"marker_path": String(marker_path), "animation_player_path": String(animation_player_path),
		"animation_name": String(animation_name), "animation_time": animation_time,
		"child_choices": child_choices.map(func(path: NodePath) -> String: return String(path)),
		"property_name": String(property_name),
		"replay_audio_on_restore": replay_audio_on_restore,
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
	for path: Variant in data.get("child_choices", []):
		binding.child_choices.append(NodePath(path))
	binding.property_name = StringName(data.get("property_name", ""))
	binding.replay_audio_on_restore = bool(data.get("replay_audio_on_restore", false))
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
		Kind.POSE_ANIMATION:
			if bool(value) and target is AnimationPlayer:
				_apply_pose_to_player(target as AnimationPlayer)
		Kind.CHILD_INDEX:
			if not target is Node or typeof(value) != TYPE_INT or value < 0 or value >= child_choices.size():
				return
			for index: int in range(child_choices.size()):
				var choice := stage.get_node_or_null(child_choices[index])
				if choice is CanvasItem or choice is Node3D:
					choice.visible = index == value
		Kind.PROPERTY:
			var info := _find_property(target, property_name)
			if info.is_empty() or not _property_value_matches(value, info):
				return
			var set_value: Variant = float(value) if typeof(value) == TYPE_INT and int(info.get("type", TYPE_NIL)) == TYPE_FLOAT else value
			target.set(property_name, set_value)
		Kind.LIGHT_ENERGY:
			if target is Light3D and (typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT):
				(target as Light3D).light_energy = float(value)
		Kind.LIGHT_COLOR:
			if target is Light3D and value is Color:
				(target as Light3D).light_color = value
		Kind.AUDIO_PLAYBACK:
			if target is AudioStreamPlayer or target is AudioStreamPlayer2D or target is AudioStreamPlayer3D:
				var player := target as Node
				player.call("stop")
				if bool(value) and replay_audio_on_restore:
					player.call("play")
		Kind.PARTICLE_EMITTING:
			if target is GPUParticles3D or target is CPUParticles3D:
				var particles := target as Node
				particles.set("emitting", bool(value))
				particles.call("restart")

func validate(stage: Stage) -> Array[String]:
	var problems: Array[String] = []
	if not stage.bb.has(key):
		problems.append("restoration binding refers to undeclared Blackboard key '%s'" % key)
		return problems
	var value_type: int = stage.bb.schema[stage.bb.resolve_key(key)].get("type", TYPE_NIL)
	var scope: StringName = stage.bb.schema[stage.bb.resolve_key(key)].get("scope", &"local")
	if scope not in [&"saved", &"shared", &"session"]:
		problems.append("restoration binding key '%s' must use saved, shared, or session scope" % key)
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
			Kind.POSE_ANIMATION:
				if value_type != TYPE_BOOL:
					problems.append("animation pose binding key '%s' must be Boolean" % key)
				if not target is AnimationPlayer:
					problems.append("animation pose target '%s' must be AnimationPlayer" % target_path)
			Kind.CHILD_INDEX:
				if value_type != TYPE_INT:
					problems.append("child index binding key '%s' must be an integer" % key)
				if not target is Node:
					problems.append("child index binding target '%s' must be a Node" % target_path)
				if child_choices.is_empty():
					problems.append("child index binding requires at least one child choice")
				for choice_path: NodePath in child_choices:
					var choice := stage.get_node_or_null(choice_path)
					if choice == null or not (choice is CanvasItem or choice is Node3D):
						problems.append("child choice '%s' was not found or does not support visibility" % choice_path)
					elif target != null and target is Node and not (target as Node).is_ancestor_of(choice):
						problems.append("child choice '%s' is not beneath binding target '%s'" % [choice_path, target_path])
				if typeof(stage.bb.get_var(key)) == TYPE_INT and (int(stage.bb.get_var(key)) < 0 or int(stage.bb.get_var(key)) >= child_choices.size()):
					problems.append("child index binding key '%s' value is outside its %d choices" % [key, child_choices.size()])
			Kind.PROPERTY:
				if property_name.is_empty():
					problems.append("property binding requires a property name")
				else:
					var property_info := _find_property(target, property_name)
					if property_info.is_empty():
						problems.append("property '%s' was not found or is read-only on '%s'" % [property_name, target_path])
					elif not _types_compatible(value_type, int(property_info.get("type", TYPE_NIL))):
						problems.append("property binding key '%s' type does not match property '%s'" % [key, property_name])
					elif not _property_value_matches(stage.bb.get_var(key), property_info):
						problems.append("property binding value for key '%s' is incompatible with property '%s'" % [key, property_name])
			Kind.LIGHT_ENERGY:
				if value_type != TYPE_FLOAT and value_type != TYPE_INT:
					problems.append("light energy binding key '%s' must be numeric" % key)
				if not target is Light3D:
					problems.append("light energy binding target '%s' must be Light3D" % target_path)
			Kind.LIGHT_COLOR:
				if value_type != TYPE_COLOR:
					problems.append("light color binding key '%s' must be Color" % key)
				if not target is Light3D:
					problems.append("light color binding target '%s' must be Light3D" % target_path)
			Kind.AUDIO_PLAYBACK:
				if value_type != TYPE_BOOL:
					problems.append("audio playback binding key '%s' must be Boolean" % key)
				if not (target is AudioStreamPlayer or target is AudioStreamPlayer2D or target is AudioStreamPlayer3D):
					problems.append("audio playback binding target '%s' must be an AudioStreamPlayer" % target_path)
				elif replay_audio_on_restore and target.get("stream") == null:
					problems.append("audio playback binding target '%s' has no stream to replay" % target_path)
			Kind.PARTICLE_EMITTING:
				if value_type != TYPE_BOOL:
					problems.append("particle emitting binding key '%s' must be Boolean" % key)
				if not (target is GPUParticles3D or target is CPUParticles3D):
					problems.append("particle emitting binding target '%s' must be GPUParticles3D or CPUParticles3D" % target_path)
				elif bool(target.get("one_shot")):
					problems.append("particle emitting binding target '%s' must use continuous emission, not one_shot" % target_path)
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
	elif kind == Kind.POSE_ANIMATION:
		if not animation_player_path.is_empty():
			problems.append("standalone animation pose uses target_path for its AnimationPlayer")
		if animation_name.is_empty():
			problems.append("standalone animation pose requires an animation name")
		var player := stage.get_node_or_null(target_path) as AnimationPlayer
		if player != null and not animation_name.is_empty() and not player.has_animation(animation_name):
			problems.append("restoration animation '%s' was not found on '%s'" % [animation_name, target_path])
	elif not animation_player_path.is_empty() or not animation_name.is_empty():
		problems.append("AnimationPlayer pose settings are only supported for marker or standalone animation pose bindings")
	if kind != Kind.AUDIO_PLAYBACK and replay_audio_on_restore:
		problems.append("replay_audio_on_restore is only supported for audio playback bindings")
	return problems

func _find_property(target: Object, name: StringName) -> Dictionary:
	if target == null or not is_instance_valid(target) or name.is_empty():
		return {}
	for property: Dictionary in target.get_property_list():
		if StringName(property.get("name", "")) != name:
			continue
		if int(property.get("usage", 0)) & PROPERTY_USAGE_READ_ONLY:
			return {}
		return property
	return {}

func _types_compatible(source_type: int, target_type: int) -> bool:
	return source_type == target_type or (source_type == TYPE_INT and target_type == TYPE_FLOAT)

func _value_matches_type(value: Variant, target_type: int) -> bool:
	return typeof(value) == target_type or (typeof(value) == TYPE_INT and target_type == TYPE_FLOAT)

func _property_value_matches(value: Variant, info: Dictionary) -> bool:
	if not _value_matches_type(value, int(info.get("type", TYPE_NIL))):
		return false
	if typeof(value) == TYPE_OBJECT and value != null:
		var expected_class := String(info.get("class_name", ""))
		if not expected_class.is_empty() and value is Object and not (value as Object).is_class(expected_class):
			return false
	return true

func _apply_pose(stage: Stage) -> void:
	if animation_player_path.is_empty() or animation_name.is_empty():
		return
	var player := stage.get_node_or_null(animation_player_path) as AnimationPlayer
	_apply_pose_to_player(player)

func _apply_pose_to_player(player: AnimationPlayer) -> void:
	if player == null or not is_instance_valid(player) or animation_name.is_empty() or not player.has_animation(animation_name):
		return
	player.play(animation_name)
	player.seek(animation_time, true)
	player.pause()
