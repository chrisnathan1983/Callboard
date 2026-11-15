@tool
class_name StagingVerbs extends CoreVerbs
## Steps that stage props and actors in the scene.

const CallboardLocalizationScript := preload("res://addons/callboard/core/callboard_localization.gd")
const COLOR_TWEEN_META := &"_callboard_color_tween"
const BASE_COLOR_META := &"_callboard_base_color"
const ISOLATED_MATERIAL_META := &"_callboard_isolated_effect_material"
const ANIMATION_PLAYBACK_META := &"_callboard_animation_playback_ticket"
const AUDIO_PLAYBACK_META := &"_callboard_audio_playback_ticket"
const LIGHT_ACTIVATION_META := &"_callboard_light_activation"
const SPEECH_LABEL_NAME := &"CallboardSpeech"
const SPEECH_TWEEN_META := &"_callboard_speech_tween"
const POSITION_TWEEN_META := &"_callboard_position_tween"
const BASE_Y_META := &"_callboard_base_y"

class PlaybackTicket extends RefCounted:
	signal superseded
	signal interrupted(reason: StringName)
	var completed := false
	var cancelled := false

	func cancel(reason: StringName) -> void:
		if completed or cancelled:
			return
		cancelled = true
		interrupted.emit(reason)
		if reason == &"replaced":
			superseded.emit()

func show_node(n: Node3D, should_be_visible := true) -> Step:
	return Step.new(func(_c: Dictionary) -> void: n.visible = should_be_visible)

## Switch a light or prop on. A positive duration turns it off on timeout or
## cancellation; an optional Boolean Blackboard key mirrors that state.
func light(n: Node3D, on: bool, duration := 0.0, key: StringName = &"") -> Step:
	return _light(n, on, duration, key)

## Ask the host game to perform an action identified by an authored event ID.
func gameplay_event(event_id: StringName, arguments: Dictionary = {}) -> Step:
	var stage := context.host as Stage
	return Step.new(func(_c: Dictionary) -> void:
		if is_instance_valid(stage):
			stage.publish_gameplay_event(event_id, arguments))

## Lock a host input channel for this rule run.
func lock_input(channel: StringName = &"gameplay") -> Step:
	return _control_step(func(adapter: StageControlAdapter, owner: RuleEngine.RunLifetime) -> void:
		adapter._claim_input(owner, channel))

## Release only the running rule's lock on this channel.
func release_input(channel: StringName = &"gameplay") -> Step:
	return _control_step(func(adapter: StageControlAdapter, owner: RuleEngine.RunLifetime) -> void:
		adapter._release_input(owner, channel))

## Ask the host's camera rig to focus on a Stage prop.
func camera_focus(target: Node3D, blend_seconds: float = 0.0, channel: StringName = &"main") -> Step:
	return _control_step(func(adapter: StageControlAdapter, owner: RuleEngine.RunLifetime) -> void:
		if not is_instance_valid(target) or not is_finite(blend_seconds) or blend_seconds < 0.0:
			push_warning("Callboard camera_focus requires a live target and a finite, nonnegative blend time.")
			return
		var request := StageControlAdapter.CameraRequest.new()
		request.kind = StageControlAdapter.CameraRequest.Kind.FOCUS
		request._target = weakref(target)
		request.blend_seconds = blend_seconds
		adapter._claim_camera(owner, channel, request))

## Select a named shot defined by the host's camera rig.
func camera_frame(shot: StringName, blend_seconds: float = 0.0, channel: StringName = &"main") -> Step:
	return _control_step(func(adapter: StageControlAdapter, owner: RuleEngine.RunLifetime) -> void:
		if shot.is_empty() or not is_finite(blend_seconds) or blend_seconds < 0.0:
			push_warning("Callboard camera_frame requires a shot name and a finite, nonnegative blend time.")
			return
		var request := StageControlAdapter.CameraRequest.new()
		request.kind = StageControlAdapter.CameraRequest.Kind.FRAME
		request.shot = shot
		request.blend_seconds = blend_seconds
		adapter._claim_camera(owner, channel, request))

## Add a shake layer for this rule run. Use a subsequent wait to hold the effect.
func camera_shake(strength: float, frequency: float = 12.0, channel: StringName = &"main") -> Step:
	return _control_step(func(adapter: StageControlAdapter, owner: RuleEngine.RunLifetime) -> void:
		if not is_finite(strength) or not is_finite(frequency) or strength < 0.0 or frequency <= 0.0:
			push_warning("Callboard camera_shake requires finite strength >= 0 and frequency > 0.")
			return
		var request := StageControlAdapter.CameraRequest.new()
		request.kind = StageControlAdapter.CameraRequest.Kind.SHAKE
		request.strength = strength
		request.frequency = frequency
		adapter._claim_camera(owner, channel, request))

## Release this rule run's shot and shake on the given camera channel.
func release_camera(channel: StringName = &"main") -> Step:
	return _control_step(func(adapter: StageControlAdapter, owner: RuleEngine.RunLifetime) -> void:
		adapter._release_camera(owner, channel))

func _control_step(apply: Callable) -> Step:
	var stage := context.host as Stage
	return Step.new(func(c: Dictionary) -> void:
		if not is_instance_valid(stage) or stage.control_adapter == null:
			push_warning("Callboard input and camera verbs require a StageControlAdapter installed by the host.")
			return
		var callboard: Dictionary = c.get("_callboard", {})
		var run: Dictionary = callboard.get("run", {})
		var owner := run.get("cancel_signal") as RuleEngine.RunLifetime
		if owner != null and not owner.is_ended:
			apply.call(stage.control_adapter, owner))

## Publish a correlated host request and hold this rule until response, timeout, or cancellation.
func gameplay_request(event_id: StringName, arguments: Dictionary = {}, timeout := 0.0,
		response_schema: Dictionary = {}, timeout_relay: StringName = &"",
		request_id := 0) -> Step:
	var stage := context.host as Stage
	var engine_ref := context.engine_ref
	var request_arguments := arguments.duplicate(true)
	var response_types := response_schema.duplicate(true)
	var step := Step.new(func(c: Dictionary) -> void:
		var engine := engine_ref.get_ref() as RuleEngine
		if not is_instance_valid(stage) or engine == null:
			return
		if event_id.is_empty() or timeout < 0.0:
			push_warning("Callboard gameplay_request requires an event ID and a nonnegative timeout.")
			return
		var callboard: Dictionary = c.get("_callboard", {})
		var rule: Rule = callboard.get("rule") as Rule
		var run: Dictionary = callboard.get("run", {})
		if rule == null or run.is_empty():
			return
		var request := stage.reserve_gameplay_request(event_id, request_arguments,
			response_types, request_id)
		if request == null:
			return
		var matches := func(received_id: int, _accepted: bool, _data: Dictionary) -> bool:
			return received_id == request.request_id
		var on_outcome := func(outcome: String) -> void:
			if outcome != "matched":
				var reason: StringName = &"timed_out" if outcome == "timed_out" else &"cancelled"
				stage.cancel_gameplay_request(request.request_id, reason)
		var completion := engine.wait_for_signal(request.responded, matches, timeout,
			rule.id, "host request " + String(event_id), run, on_outcome)
		if completion.is_null():
			stage.cancel_gameplay_request(request.request_id, &"cancelled")
			return
		if not stage.publish_gameplay_request(request):
			stage.cancel_gameplay_request(request.request_id, &"dispatch_blocked")
		await completion)
	step.emits = timeout_relay
	step.emit_arg = 4
	return step

## Play a stream. A positive timeout cancels a wait that runs too long.
func play_audio(player: Node, wait_for_completion := false, timeout := 0.0) -> Step:
	var f := func(payload: Dictionary) -> Variant:
		if not is_instance_valid(player) or not _is_audio_player(player):
			push_warning("Callboard play_audio skipped: target must be an AudioStreamPlayer, AudioStreamPlayer2D, or AudioStreamPlayer3D.")
			return null
		if player.get("stream") == null:
			push_warning("Callboard play_audio skipped: the target has no AudioStream assigned.")
			return null
		if not is_finite(timeout) or timeout < 0.0:
			push_warning("Callboard play_audio skipped: timeout must be finite and zero or greater.")
			return null
		var previous_ticket: PlaybackTicket = player.get_meta(AUDIO_PLAYBACK_META) as PlaybackTicket if player.has_meta(AUDIO_PLAYBACK_META) else null
		if previous_ticket != null:
			previous_ticket.cancel(&"replaced")
		var ticket := PlaybackTicket.new()
		player.set_meta(AUDIO_PLAYBACK_META, ticket)
		var playback_tree := player.get_tree() if player.is_inside_tree() else null
		var completion: RuleEngine.AwaitedSignal
		var wait_signal: Signal
		if wait_for_completion:
			if playback_tree == null:
				return null
			completion = RuleEngine.AwaitedSignal.new()
			wait_signal = _animation_completion(payload, completion.completed,
				Callable(), [ticket.interrupted])
		player.call("play")
		if wait_for_completion:
			_watch_audio_playback(player.get_instance_id(), ticket, completion,
				playback_tree, _audio_finished_signal(player), timeout)
			return wait_signal
		return null
	return Step.new(f)

## Stop playback and release any rule waiting for this audio instance.
func stop_audio(player: Node) -> Step:
	return Step.new(func(_payload: Dictionary) -> void:
		if not is_instance_valid(player) or not _is_audio_player(player):
			push_warning("Callboard stop_audio requires a live AudioStreamPlayer target.")
			return
		var ticket := player.get_meta(AUDIO_PLAYBACK_META, null) as PlaybackTicket
		if ticket != null:
			ticket.cancel(&"stopped")
		player.call("stop"))

## Set an audio player's pitch scale; values must be finite and greater than zero.
func set_audio_pitch(player: Node, pitch_scale: float) -> Step:
	return Step.new(func(_payload: Dictionary) -> void:
		if not is_instance_valid(player) or not _is_audio_player(player):
			push_warning("Callboard set_audio_pitch requires a live AudioStreamPlayer target.")
			return
		if not is_finite(pitch_scale) or pitch_scale <= 0.0:
			push_warning("Callboard set_audio_pitch requires a finite pitch scale greater than zero.")
			return
		player.set("pitch_scale", pitch_scale))

## Route an audio player's output to an existing AudioServer bus.
func set_audio_bus(player: Node, bus: StringName) -> Step:
	return Step.new(func(_payload: Dictionary) -> void:
		if not is_instance_valid(player) or not _is_audio_player(player):
			push_warning("Callboard set_audio_bus requires a live AudioStreamPlayer target.")
			return
		if bus.is_empty() or AudioServer.get_bus_index(bus) < 0:
			push_warning("Callboard set_audio_bus requires a bus present on the AudioServer.")
			return
		player.set("bus", bus))

## Set the color of a Light3D, including OmniLight3D, SpotLight3D, and DirectionalLight3D.
func set_light_color(light_node: Light3D, color: Color) -> Step:
	return Step.new(func(_payload: Dictionary) -> void:
		if not is_instance_valid(light_node):
			push_warning("Callboard set_light_color requires a live Light3D target.")
			return
		if not _is_finite_color(color):
			push_warning("Callboard set_light_color requires finite color components.")
			return
		light_node.light_color = color)

## Set a Light3D's nonnegative energy.
func set_light_energy(light_node: Light3D, energy: float) -> Step:
	return Step.new(func(_payload: Dictionary) -> void:
		if not is_instance_valid(light_node):
			push_warning("Callboard set_light_energy requires a live Light3D target.")
			return
		if not is_finite(energy) or energy < 0.0:
			push_warning("Callboard set_light_energy requires finite energy >= 0.")
			return
		light_node.light_energy = energy)

## Flicker a light between low and high energy, then restore its original energy.
## Cancellation releases the rule wait while the short visual effect finishes.
func flicker_light(light_node: Light3D, low_energy: float, high_energy: float,
		interval := 0.06, duration := 0.6) -> Step:
	var host := context.host
	return Step.new(func(payload: Dictionary) -> Variant:
		if not is_instance_valid(light_node):
			push_warning("Callboard flicker_light requires a live Light3D target.")
			return null
		if not is_finite(low_energy) or not is_finite(high_energy) or low_energy < 0.0 or high_energy < low_energy:
			push_warning("Callboard flicker_light requires finite energies with 0 <= low <= high.")
			return null
		if not is_finite(interval) or interval <= 0.0 or not is_finite(duration) or duration <= 0.0:
			push_warning("Callboard flicker_light requires finite interval and duration values greater than zero.")
			return null
		if not is_instance_valid(host) or not host is Node or not host.is_inside_tree():
			push_warning("Callboard flicker_light requires an in-tree Stage host.")
			return null
		var initial_energy := light_node.light_energy
		var tween := host.create_tween()
		var flicker := func(elapsed: float) -> void:
			if is_instance_valid(light_node):
				var phase := fposmod(elapsed, interval * 2.0)
				light_node.light_energy = low_energy if phase < interval else high_energy
		tween.tween_method(flicker, 0.0, duration, duration).set_trans(Tween.TRANS_LINEAR)
		tween.tween_callback(func() -> void:
			if is_instance_valid(light_node):
				light_node.light_energy = initial_energy)
		return _animation_completion(payload, tween.finished))

## Restart CPU or GPU particles in 2D or 3D.
func restart_particles(particles: Node) -> Step:
	return Step.new(func(_payload: Dictionary) -> void:
		if not is_instance_valid(particles) or not _is_particle_node(particles):
			push_warning("Callboard restart_particles requires a CPU or GPU particles node in 2D or 3D.")
			return
		particles.call("restart"))

## Change an existing ShaderMaterial uniform after checking its declared name and type.
func set_shader_parameter(material: ShaderMaterial, parameter: StringName, value: Variant) -> Step:
	return Step.new(func(_payload: Dictionary) -> void:
		var problem := _shader_parameter_problem(material, parameter, value)
		if not problem.is_empty():
			push_warning("Callboard set_shader_parameter skipped: %s" % problem)
			return
		material.set_shader_parameter(parameter, value))

## Instantiate a PackedScene under parent. A non-null owner marks the instance
## as part of that ancestor's edited scene; an optional transform is local.
func spawn(scene: PackedScene, parent: Node, owner: Node = null,
		initial_transform: Variant = null) -> Step:
	return Step.new(func(_payload: Dictionary) -> void:
		if not is_instance_valid(scene) or not is_instance_valid(parent):
			push_warning("Callboard spawn requires a live PackedScene and parent Node.")
			return
		if owner != null and (not is_instance_valid(owner) or not _is_valid_scene_owner(owner, parent)):
			push_warning("Callboard spawn owner must be the parent or one of its ancestors.")
			return
		if initial_transform != null and not initial_transform is Transform2D and not initial_transform is Transform3D:
			push_warning("Callboard spawn transform must be Transform2D, Transform3D, or null.")
			return
		var instance := scene.instantiate()
		if instance == null:
			push_warning("Callboard spawn could not instantiate its PackedScene.")
			return
		if initial_transform is Transform3D and not instance is Node3D \
				or initial_transform is Transform2D and not instance is Node2D:
			instance.free()
			push_warning("Callboard spawn transform type does not match the PackedScene root.")
			return
		parent.add_child(instance)
		if initial_transform is Transform3D:
			(instance as Node3D).transform = initial_transform
		elif initial_transform is Transform2D:
			(instance as Node2D).transform = initial_transform
		instance.owner = owner)

## Remove an owned node. Pass expected_owner explicitly (null for an unowned
## runtime node); detach it instead of freeing it when destroy is false.
func despawn(n: Node, expected_owner: Node, destroy := true,
		keep_global_transform := true) -> Step:
	return Step.new(func(_payload: Dictionary) -> void:
		if not is_instance_valid(n) or n.owner != expected_owner:
			push_warning("Callboard despawn requires a live node with the expected owner.")
			return
		var parent := n.get_parent()
		if parent == null:
			push_warning("Callboard despawn requires a node attached to a parent.")
			return
		if destroy:
			n.queue_free()
			return
		var transform_3d: Transform3D
		var transform_2d: Transform2D
		if keep_global_transform and n is Node3D:
			transform_3d = (n as Node3D).global_transform
		elif keep_global_transform and n is Node2D:
			transform_2d = (n as Node2D).global_transform
		parent.remove_child(n)
		if keep_global_transform and n is Node3D:
			(n as Node3D).transform = transform_3d
		elif keep_global_transform and n is Node2D:
			(n as Node2D).transform = transform_2d
		_clear_invalid_scene_owners(n))

## Reparent a node only when its current owner matches expected_owner. Set
## new_owner explicitly (null clears scene ownership) and optionally preserve
## its world transform for Node2D/Node3D nodes.
func reparent(n: Node, new_parent: Node, expected_owner: Node, new_owner: Node,
		keep_global_transform := true) -> Step:
	return Step.new(func(_payload: Dictionary) -> void:
		if not is_instance_valid(n) or not is_instance_valid(new_parent) or n.owner != expected_owner:
			push_warning("Callboard reparent requires a live node, parent, and matching expected owner.")
			return
		if n == new_parent or n.is_ancestor_of(new_parent):
			push_warning("Callboard reparent cannot create a node cycle.")
			return
		if new_owner != null and (not is_instance_valid(new_owner) or not _is_valid_scene_owner(new_owner, new_parent)):
			push_warning("Callboard reparent new owner must be the parent or one of its ancestors.")
			return
		n.reparent(new_parent, keep_global_transform)
		n.owner = new_owner
		_clear_invalid_scene_owners(n))

func _watch_audio_playback(player_id: int, ticket: PlaybackTicket,
		completion: RuleEngine.AwaitedSignal, tree: SceneTree, finished: Signal,
		timeout: float) -> void:
	var playback_id := [0]
	var finished_early := [false]
	var on_finished := func() -> void:
		var player := instance_from_id(player_id) as Node
		if not is_instance_valid(player) or ticket.cancelled \
				or player.get_meta(AUDIO_PLAYBACK_META, null) != ticket:
			return
		if playback_id[0] == 0:
			finished_early[0] = true
			return
		ticket.completed = true
		completion.is_complete = true
		completion.completed.emit()
	finished.connect(on_finished, CONNECT_ONE_SHOT)
	await tree.process_frame
	if ticket.cancelled or completion.is_complete:
		return
	var player := instance_from_id(player_id) as Node
	if not is_instance_valid(player) or not player.is_inside_tree() \
			or player.get_meta(AUDIO_PLAYBACK_META, null) != ticket:
		ticket.cancel(&"target_removed")
		return
	if not bool(player.get("playing")):
		if finished_early[0]:
			ticket.completed = true
			completion.is_complete = true
			completion.completed.emit()
		else:
			ticket.cancel(&"stopped")
		return
	# AudioStreamPlayer creates the underlying playback only after play() has
	# advanced through an audio frame. Never query it before this point.
	var playback := player.call("get_stream_playback") as AudioStreamPlayback
	playback_id[0] = playback.get_instance_id() if playback != null else 0
	if finished_early[0] and playback_id[0] == 0 and not bool(player.get("playing")):
		ticket.completed = true
		completion.is_complete = true
		completion.completed.emit()
		return
	_start_playback_monitor(player, ticket, func() -> bool:
		return bool(player.get("playing")) and not bool(player.get("stream_paused")), timeout)

## Rotate a Node3D to an Euler rotation in radians. Waiting is explicit.
func rotate_to(n: Node3D, target_rotation: Vector3, duration := 0.25,
		wait_for_completion := true, transition := Tween.TRANS_LINEAR,
		ease := Tween.EASE_IN_OUT) -> Step:
	var host := context.host
	var f := func(payload: Dictionary) -> Variant:
		if not _valid_tween_options(duration, transition, ease, "rotate_to"):
			return null
		if not is_instance_valid(n):
			push_warning("Callboard rotate_to requires a live Node3D target.")
			return null
		if not _is_finite_vector3(target_rotation):
			push_warning("Callboard rotate_to skipped: target rotation must be finite.")
			return null
		if duration == 0.0:
			n.rotation = target_rotation
			return null
		if not is_instance_valid(host) or not host is Node:
			push_warning("Callboard rotate_to requires a live Node3D and an in-tree Stage host.")
			return null
		var tween := host.create_tween()
		tween.tween_property(n, ^"rotation", target_rotation, duration).set_trans(transition).set_ease(ease)
		return _animation_completion(payload, tween.finished) if wait_for_completion else null
	return Step.new(f)

## Follow a Path3D curve by distance. The optional orientation follows the path's baked rotation.
func follow_path(n: Node3D, path: Path3D, duration := 1.0, orient_to_path := false,
		wait_for_completion := true, transition := Tween.TRANS_LINEAR,
		ease := Tween.EASE_IN_OUT) -> Step:
	var host := context.host
	return Step.new(func(payload: Dictionary) -> Variant:
		if not is_instance_valid(n) or not is_instance_valid(path) or path.curve == null:
			push_warning("Callboard follow_path requires a live Node3D target and Path3D with a Curve3D.")
			return null
		if not _valid_tween_options(duration, transition, ease, "follow_path"):
			return null
		var curve_length := path.curve.get_baked_length()
		if curve_length <= 0.0:
			push_warning("Callboard follow_path skipped: the Curve3D has no baked length.")
			return null
		if duration == 0.0:
			n.set_meta(POSITION_TWEEN_META, null)
			_apply_path_pose(n, path, curve_length, orient_to_path)
			return null
		if not is_instance_valid(host) or not host is Node:
			push_warning("Callboard follow_path requires a live Stage host.")
			return null
		var tween := host.create_tween()
		var set_position := _position_setter(n, tween, ^"global_position")
		var update := func(progress: float) -> void:
			if is_instance_valid(n) and is_instance_valid(path) and path.curve != null:
				_apply_path_pose(n, path, curve_length * progress, orient_to_path, set_position)
		tween.tween_method(update, 0.0, 1.0, duration).set_trans(transition).set_ease(ease)
		return _animation_completion(payload, tween.finished) if wait_for_completion else null)

## Tween an interpolatable property when its current and destination values have compatible types.
func tween_property(target: Object, property: NodePath, value: Variant, duration := 0.25,
		wait_for_completion := true, transition := Tween.TRANS_LINEAR,
		ease := Tween.EASE_IN_OUT) -> Step:
	var host := context.host
	return Step.new(func(payload: Dictionary) -> Variant:
		if not _valid_tween_options(duration, transition, ease, "tween_property"):
			return null
		if not is_instance_valid(target) or property.is_empty():
			push_warning("Callboard tween_property requires a live target and nonempty property path.")
			return null
		if not _is_tween_property_writable(target, property):
			push_warning("Callboard tween_property requires a writable property path.")
			return null
		var current: Variant = target.get_indexed(property)
		if not _tween_values_compatible(current, value):
			push_warning("Callboard tween_property requires compatible interpolatable property values.")
			return null
		if duration == 0.0:
			target.set_indexed(property, value)
			return null
		if not is_instance_valid(host) or not host is Node:
			push_warning("Callboard tween_property requires a live Stage host.")
			return null
		var tween := host.create_tween()
		tween.tween_property(target, property, value, duration).set_trans(transition).set_ease(ease)
		return _animation_completion(payload, tween.finished) if wait_for_completion else null)

func _valid_tween_options(duration: float, transition: int, ease: int, verb: String) -> bool:
	if not is_finite(duration) or duration < 0.0:
		push_warning("Callboard %s skipped: duration must be finite and zero or greater." % verb)
		return false
	if transition < Tween.TRANS_LINEAR or transition > Tween.TRANS_SPRING:
		push_warning("Callboard %s skipped: transition is not a valid Tween transition." % verb)
		return false
	if ease < Tween.EASE_IN or ease > Tween.EASE_OUT_IN:
		push_warning("Callboard %s skipped: ease is not a valid Tween ease." % verb)
		return false
	return true

func _is_finite_vector3(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)

func _is_nonnegative_finite_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) >= 0.0

func _is_positive_finite_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) > 0.0

func _apply_path_pose(n: Node3D, path: Path3D, distance: float, orient_to_path: bool,
		set_position := Callable()) -> void:
	var sample := path.curve.sample_baked_with_rotation(distance, true, false)
	var world_position := path.to_global(sample.origin)
	if set_position.is_valid():
		set_position.call(world_position)
	else:
		n.global_position = world_position
	if orient_to_path:
		n.global_rotation = (path.global_transform.basis * sample.basis).get_euler()

func _tween_values_compatible(from_value: Variant, to_value: Variant) -> bool:
	if typeof(from_value) == TYPE_INT or typeof(from_value) == TYPE_FLOAT:
		return typeof(to_value) == TYPE_INT or typeof(to_value) == TYPE_FLOAT
	if typeof(from_value) != typeof(to_value):
		return false
	return typeof(from_value) in [TYPE_VECTOR2, TYPE_VECTOR2I, TYPE_RECT2, TYPE_RECT2I,
		TYPE_VECTOR3, TYPE_VECTOR3I, TYPE_TRANSFORM2D, TYPE_VECTOR4, TYPE_VECTOR4I,
		TYPE_PLANE, TYPE_QUATERNION, TYPE_AABB, TYPE_BASIS, TYPE_TRANSFORM3D,
		TYPE_PROJECTION, TYPE_COLOR]

func _is_tween_property_writable(target: Object, property: NodePath) -> bool:
	if property.get_name_count() == 0:
		return false
	for descriptor in target.get_property_list():
		if StringName(descriptor.name) == property.get_name(0):
			return (int(descriptor.usage) & PROPERTY_USAGE_READ_ONLY) == 0
	return false

func _validate_tween_options(rule_id: StringName, args: Array, duration_index: int,
		transition_index: int, ease_index: int, verb: String) -> Array[String]:
	var problems: Array[String] = []
	if args.size() > duration_index:
		var duration: Variant = args[duration_index]
		if not (duration is int or duration is float) or not is_finite(float(duration)) or float(duration) < 0.0:
			problems.append("rule '%s' %s duration must be finite and zero or greater" % [rule_id, verb])
	if args.size() > transition_index:
		var transition: Variant = args[transition_index]
		if not transition is int or transition < Tween.TRANS_LINEAR or transition > Tween.TRANS_SPRING:
			problems.append("rule '%s' %s transition must be a valid Tween transition enum" % [rule_id, verb])
	if args.size() > ease_index:
		var ease: Variant = args[ease_index]
		if not ease is int or ease < Tween.EASE_IN or ease > Tween.EASE_OUT_IN:
			problems.append("rule '%s' %s ease must be a valid Tween ease enum" % [rule_id, verb])
	return problems

## Instantly copy a Marker3D's world transform onto a Node3D. Optionally leave
## an AnimationPlayer paused at a resolved pose after moving the target.
func snap_to_marker(n: Node3D, marker: Marker3D,
		animation_player: AnimationPlayer = null, animation_name: StringName = &"",
		animation_time := 0.0) -> Step:
	return Step.new(func(_payload: Dictionary) -> void:
		if not is_instance_valid(n) or not is_instance_valid(marker):
			push_warning("Callboard snap_to_marker requires a live Node3D target and Marker3D marker.")
			return
		if not is_finite(animation_time) or animation_time < 0.0:
			push_warning("Callboard snap_to_marker animation time must be finite and nonnegative.")
			return
		if animation_player == null:
			if not animation_name.is_empty():
				push_warning("Callboard snap_to_marker animation name requires an AnimationPlayer.")
				return
		elif not is_instance_valid(animation_player) or animation_name.is_empty() \
				or not animation_player.has_animation(animation_name):
			push_warning("Callboard snap_to_marker animation must name a clip on its AnimationPlayer.")
			return
		n.global_transform = marker.global_transform
		if animation_player != null:
			animation_player.play(animation_name)
			animation_player.seek(animation_time, true)
			animation_player.pause())

## Play an AnimationPlayer clip. A positive timeout cancels a wait that runs too long.
func play_animation(player: AnimationPlayer, animation: StringName,
		wait_for_completion := true, timeout := 0.0, custom_blend := -1.0,
		custom_speed := 1.0) -> Step:
	var f := func(payload: Dictionary) -> Variant:
		if player == null or not is_instance_valid(player) or not player.has_animation(animation):
			push_warning("Callboard play_animation skipped: animation '%s' is missing from its AnimationPlayer." % animation)
			return null
		if not is_finite(timeout) or timeout < 0.0:
			push_warning("Callboard play_animation skipped: timeout must be finite and zero or greater.")
			return null
		if not is_finite(custom_blend) or custom_blend < -1.0:
			push_warning("Callboard play_animation skipped: custom blend must be finite and at least -1.")
			return null
		if not is_finite(custom_speed) or custom_speed <= 0.0:
			push_warning("Callboard play_animation skipped: custom speed must be finite and greater than zero.")
			return null
		if not wait_for_completion:
			_supersede_animation_playback(player)
			player.play(animation, custom_blend, custom_speed)
			return null
		var ticket := _supersede_animation_playback(player)
		player.play(animation, custom_blend, custom_speed)
		var playback_matches := func(finished_animation: StringName) -> bool:
			var matches: bool = (finished_animation == animation and is_instance_valid(player)
				and player.get_meta(ANIMATION_PLAYBACK_META, null) == ticket)
			if matches:
				ticket.completed = true
			return matches
		_start_playback_monitor(player, ticket, func() -> bool: return player.is_playing(), timeout)
		return _animation_completion(payload, player.animation_finished, playback_matches,
			[ticket.interrupted])
	return Step.new(f)

## Change the AnimationPlayer speed scale without changing its current clip.
func set_animation_speed(player: AnimationPlayer, speed_scale: float) -> Step:
	return Step.new(func(_payload: Dictionary) -> void:
		if not is_instance_valid(player):
			push_warning("Callboard set_animation_speed requires a live AnimationPlayer.")
			return
		if not is_finite(speed_scale) or speed_scale <= 0.0:
			push_warning("Callboard set_animation_speed requires a finite value greater than zero.")
			return
		player.speed_scale = speed_scale)

## Pose an AnimationPlayer at a time without starting a playback wait.
func pose_animation(player: AnimationPlayer, animation: StringName, time := 0.0) -> Step:
	return Step.new(func(_payload: Dictionary) -> void:
		if player == null or not is_instance_valid(player) or not player.has_animation(animation):
			push_warning("Callboard pose_animation skipped: animation '%s' is missing from its AnimationPlayer." % animation)
			return
		player.play(animation)
		player.seek(time, true)
		player.pause())

## Scale and position animations finish their visual effect after rule cancellation.
## Stage deactivation releases the rule's wait immediately.
func pop(n: Node3D) -> Step:
	var host := context.host
	var f := func(payload: Dictionary) -> Signal:
		n.scale = Vector3.ZERO
		var t := host.create_tween()
		t.tween_property(n, "scale", Vector3.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		return _animation_completion(payload, t.finished)
	return Step.new(f)

func bounce(n: Node3D) -> Step:
	var host := context.host
	var f := func(payload: Dictionary) -> Signal:
		var t := host.create_tween()
		t.tween_property(n, "scale", Vector3(1.25, 0.75, 1.25), 0.1)
		t.tween_property(n, "scale", Vector3.ONE, 0.3).set_trans(Tween.TRANS_BOUNCE)
		return _animation_completion(payload, t.finished)
	return Step.new(f)

## Switches a light and mirrors it into a local Blackboard key. duration > 0 switches it
## off again on timeout or cancellation (non-blocking).
func _light(n: Node3D, on: bool, duration: float, key: StringName) -> Step:
	var ctx := context
	var f := func(c: Dictionary) -> void:
		if not is_instance_valid(n):
			push_warning("Callboard light skipped: target is no longer valid.")
			return
		if duration < 0.0:
			push_warning("Callboard light skipped: duration must be zero or greater.")
			return
		if not key.is_empty() and (not ctx.bb.has(key)
				or ctx.bb.schema[ctx.bb.resolve_key(key)].get("type", TYPE_NIL) != TYPE_BOOL):
			push_warning("Callboard light skipped: key '%s' must be a declared Boolean Blackboard value." % key)
			return
		var engine := ctx.engine_ref.get_ref() as RuleEngine
		var callboard: Dictionary = c.get("_callboard", {})
		var rule := callboard.get("rule") as Rule
		var gen := engine.token()
		var rule_id := StringName(rule.id) if rule != null else &"<anonymous>"
		var node_id := n.get_instance_id()
		var activation := int(n.get_meta(LIGHT_ACTIVATION_META, 0)) + 1
		n.set_meta(LIGHT_ACTIVATION_META, activation)
		n.visible = on
		if not key.is_empty():
			ctx.bb.write(key, on)
		if on and duration > 0.0:
			if engine.token() != gen or (rule != null and not engine.alive(rule, gen)):
				if is_instance_valid(n) and n.get_meta(LIGHT_ACTIVATION_META, 0) == activation:
					n.hide()
					if not key.is_empty():
						ctx.bb.write(key, false)
				return
			var on_run_cancelled := Callable()
			var turn_off := Callable()
			turn_off = func() -> void:
				var current := ctx.engine_ref.get_ref() as RuleEngine
				if current != null:
					if on_run_cancelled.is_valid() and current.run_cancelled.is_connected(on_run_cancelled):
						current.run_cancelled.disconnect(on_run_cancelled)
					if turn_off.is_valid() and current.all_cancelled.is_connected(turn_off):
						current.all_cancelled.disconnect(turn_off)
				var light_node := instance_from_id(node_id) as Node3D
				if light_node != null and light_node.get_meta(LIGHT_ACTIVATION_META, 0) == activation:
					light_node.set_meta(LIGHT_ACTIVATION_META, activation + 1)
					light_node.hide()
					if not key.is_empty():
						ctx.bb.write(key, false)
			var run: Dictionary = callboard.get("run", {})
			on_run_cancelled = func(cancelled_rule_id: StringName) -> void:
				if cancelled_rule_id == rule_id and run.get("cancelled", false):
					turn_off.call()
			if rule != null:
				engine.run_cancelled.connect(on_run_cancelled)
			engine.all_cancelled.connect(turn_off, CONNECT_ONE_SHOT)
			var timeout: Signal = engine.wait_tracked(duration, rule_id, "light off")
			timeout.connect(func() -> void:
				turn_off.call(), CONNECT_ONE_SHOT)
	var s := Step.new(f)
	if not key.is_empty():
		s.sets = [key]
	return s

## Floating text over a prop. Non-blocking.
func say(n: Node3D, text: String, seconds := 1.0) -> Step:
	return _say_text(n, func() -> String: return text, seconds)

## Floating text resolved through TranslationServer when the rule runs.
## Substitutions use named String.format placeholders such as {item}.
func say_key(n: Node3D, key: StringName, substitutions: Dictionary = {}, seconds := 1.0, fallback := "") -> Step:
	return _say_text(n, func() -> String:
		return CallboardLocalizationScript.resolve(key, substitutions, fallback), seconds)

func _say_text(n: Node3D, resolve_text: Callable, seconds: float) -> Step:
	var f := func(_c: Dictionary) -> void:
		if not is_instance_valid(n) or not resolve_text.is_valid():
			return
		var label := n.get_node_or_null(NodePath(SPEECH_LABEL_NAME)) as Label3D
		if label == null:
			label = Label3D.new()
			label.name = SPEECH_LABEL_NAME
			n.add_child(label)
		else:
			var previous: Tween = label.get_meta(SPEECH_TWEEN_META) if label.has_meta(SPEECH_TWEEN_META) else null
			if previous and previous.is_running():
				previous.kill()
		label.text = str(resolve_text.call())
		label.font_size = 96
		label.pixel_size = 0.01
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		label.position = Vector3(0, 1.6, 0)
		var t := label.create_tween()
		t.tween_interval(seconds)
		t.tween_callback(label.queue_free)
		label.set_meta(SPEECH_TWEEN_META, t)
	return Step.new(f)

func move_to(n: Node3D, dest: Node3D, offset := Vector3.ZERO, duration := 0.7,
		transition := Tween.TRANS_LINEAR, ease := Tween.EASE_IN_OUT) -> Step:
	var host := context.host
	var move := func(payload: Dictionary) -> Variant:
		if not is_instance_valid(n) or not is_instance_valid(dest):
			push_warning("Callboard move_to requires live Node3D target and destination.")
			return null
		if not _is_finite_vector3(offset):
			push_warning("Callboard move_to skipped: offset must be finite.")
			return null
		if not _valid_tween_options(duration, transition, ease, "move_to"):
			return null
		var target_global := dest.global_position + offset
		var parent := n.get_parent_node_3d()
		var target_local := target_global if parent == null or n.top_level else parent.to_local(target_global)
		n.set_meta(BASE_Y_META, target_local.y)
		if duration == 0.0:
			n.set_meta(POSITION_TWEEN_META, null)
			n.global_position = target_global
			return null
		if not is_instance_valid(host) or not host is Node:
			push_warning("Callboard move_to requires a live Stage host.")
			return null
		var tween := host.create_tween()
		var set_position := _position_setter(n, tween, ^"global_position")
		tween.tween_method(set_position, n.global_position, target_global, duration).set_trans(transition).set_ease(ease)
		return _animation_completion(payload, tween.finished)
	return Step.new(move)

## Tints the mesh's material_override.
func flash(m: MeshInstance3D) -> Step:
	var host := context.host
	var f := func(payload: Dictionary) -> Signal:
		var materials := _effect_materials(m, "flash")
		if materials.is_empty():
			return _animation_completion(payload, host.get_tree().process_frame)
		var tint := Color(1, 0.15, 0.15)
		var t := host.create_tween()
		for i in materials.size():
			var material := materials[i]
			var base := _base_color(material)
			material.albedo_color = tint
			if i > 0:
				t.parallel()
			t.tween_method(_color_setter(m, material, t), tint, base, 0.8)
		return _animation_completion(payload, t.finished)
	return Step.new(f)

func jump(m: MeshInstance3D) -> Step:
	var host := context.host
	var f := func(payload: Dictionary) -> Signal:
		var materials := _effect_materials(m, "jump")
		if not materials.is_empty():
			var tint := Color(1, 0.9, 0.3)
			var color_tween := host.create_tween()
			for i in materials.size():
				var material := materials[i]
				var base := _base_color(material)
				var set_color := _color_setter(m, material, color_tween)
				if i > 0:
					color_tween.parallel()
				color_tween.tween_method(set_color, base, tint, 0.08)
				color_tween.tween_method(set_color, tint, base, 0.32)
		var previous: Tween = m.get_meta(POSITION_TWEEN_META) if m.has_meta(POSITION_TWEEN_META) else null
		var base_y := m.position.y
		if previous and previous.is_running() and m.has_meta(BASE_Y_META):
			base_y = float(m.get_meta(BASE_Y_META))
		m.set_meta(BASE_Y_META, base_y)
		var hop := host.create_tween()
		var set_height := _position_setter(m, hop, ^"position:y")
		hop.tween_method(set_height, m.position.y, base_y + 0.6, 0.15)
		hop.tween_method(set_height, base_y + 0.6, base_y, 0.25).set_trans(Tween.TRANS_BOUNCE)
		return _animation_completion(payload, hop.finished)
	return Step.new(f)

func _animation_completion(payload: Dictionary, finished: Signal,
		completion_if := Callable(), cancel_on: Array[Signal] = []) -> Signal:
	if payload.has("_callboard"):
		var engine := context.engine_ref.get_ref() as RuleEngine
		if engine != null:
			var run: Dictionary = payload["_callboard"].get("run", {})
			var cancellation: RuleEngine.AwaitedSignal = run.get("cancel_signal") as RuleEngine.AwaitedSignal
			if cancellation != null:
				cancel_on.append(cancellation.cancelled)
				return engine.interruptible(finished, completion_if, cancel_on, run, true)
			return engine.interruptible(finished, completion_if)
	return finished

func _start_playback_monitor(target: Node, ticket: PlaybackTicket,
		is_playing: Callable, timeout: float) -> void:
	var target_id := target.get_instance_id()
	var was_inside_tree := target.is_inside_tree()
	_monitor_playback(target_id, ticket, is_playing, timeout, was_inside_tree)

func _monitor_playback(target_id: int, ticket: PlaybackTicket, is_playing: Callable,
		timeout: float, was_inside_tree: bool) -> void:
	var tree: SceneTree
	var target := instance_from_id(target_id) as Node
	if is_instance_valid(target):
		tree = target.get_tree()
	if tree == null and is_instance_valid(context.host) and context.host is Node:
		tree = (context.host as Node).get_tree()
	if tree == null:
		return
	var started_ms := Time.get_ticks_msec()
	while not ticket.completed and not ticket.cancelled:
		await tree.process_frame
		if ticket.completed or ticket.cancelled:
			return
		target = instance_from_id(target_id) as Node
		if not is_instance_valid(target) or (was_inside_tree and not target.is_inside_tree()):
			ticket.cancel(&"target_removed")
			return
		if timeout > 0.0 and (Time.get_ticks_msec() - started_ms) / 1000.0 >= timeout:
			ticket.cancel(&"timeout")
			return
		if not bool(is_playing.call()):
			ticket.cancel(&"stopped")
			return

func _supersede_animation_playback(player: AnimationPlayer) -> PlaybackTicket:
	var previous: PlaybackTicket = player.get_meta(ANIMATION_PLAYBACK_META) as PlaybackTicket if player.has_meta(ANIMATION_PLAYBACK_META) else null
	if previous != null:
		previous.cancel(&"replaced")
	var ticket := PlaybackTicket.new()
	player.set_meta(ANIMATION_PLAYBACK_META, ticket)
	return ticket

## The newest tween controls position. Earlier tweens still finish so their rules resume.
func _position_setter(node: Node3D, tween: Tween, property: NodePath) -> Callable:
	var node_id := node.get_instance_id()
	var tween_id := tween.get_instance_id()
	node.set_meta(POSITION_TWEEN_META, tween)
	return func(value: Variant) -> void:
		var target := instance_from_id(node_id) as Node3D
		if target == null or not target.has_meta(POSITION_TWEEN_META):
			return
		var current_tween := target.get_meta(POSITION_TWEEN_META) as Tween
		if current_tween != null and current_tween.get_instance_id() == tween_id:
			target.set_indexed(property, value)

## Duplicate compatible materials before tinting so shared source resources stay untouched.
func _effect_materials(m: MeshInstance3D, verb: String) -> Array[BaseMaterial3D]:
	var result: Array[BaseMaterial3D] = []
	if not is_instance_valid(m):
		push_warning("Callboard %s skipped: mesh is no longer valid." % verb)
		return result
	if m.material_override != null:
		var override := m.material_override as BaseMaterial3D
		if override != null:
			var isolated := _isolated_effect_material(override)
			m.material_override = isolated
			result.append(isolated)
			return result
		push_warning("Callboard %s has a non-BaseMaterial3D material override on '%s'." % [verb, m.name])
		return result
	if m.mesh == null:
		push_warning("Callboard %s skipped: '%s' has no mesh." % [verb, m.name])
		return result
	for surface in m.mesh.get_surface_count():
		var material := m.get_active_material(surface) as BaseMaterial3D
		if material == null:
			continue
		var isolated := _isolated_effect_material(material)
		m.set_surface_override_material(surface, isolated)
		result.append(isolated)
	if result.is_empty() and verb != "jump":
		push_warning("Callboard %s skipped: '%s' has no compatible BaseMaterial3D material." % [verb, m.name])
	return result

func _isolated_effect_material(material: BaseMaterial3D) -> BaseMaterial3D:
	if material.has_meta(ISOLATED_MATERIAL_META):
		return material
	var isolated := material.duplicate(true) as BaseMaterial3D
	isolated.set_meta(ISOLATED_MATERIAL_META, true)
	return isolated

func _base_color(material: BaseMaterial3D) -> Color:
	if not material.has_meta(BASE_COLOR_META):
		material.set_meta(BASE_COLOR_META, material.albedo_color)
	var base_color: Color = material.get_meta(BASE_COLOR_META)
	return base_color

## Replacing the tint leaves earlier tweens free to finish and resume waiting rules.
func _color_setter(mesh: MeshInstance3D, material: BaseMaterial3D, tween: Tween) -> Callable:
	var mesh_id := mesh.get_instance_id()
	var tween_id := tween.get_instance_id()
	mesh.set_meta(COLOR_TWEEN_META, tween_id)
	return func(color: Color) -> void:
		var current_mesh := instance_from_id(mesh_id) as MeshInstance3D
		if current_mesh != null and current_mesh.get_meta(COLOR_TWEEN_META, 0) == tween_id:
			material.albedo_color = color

func _is_audio_player(node: Node) -> bool:
	return node is AudioStreamPlayer or node is AudioStreamPlayer2D or node is AudioStreamPlayer3D

func _is_valid_scene_owner(owner: Node, parent: Node) -> bool:
	return is_instance_valid(owner) and is_instance_valid(parent) \
		and (owner == parent or owner.is_ancestor_of(parent))

func _clear_invalid_scene_owners(node: Node) -> void:
	if node.owner != null and (not is_instance_valid(node.owner) or not node.owner.is_ancestor_of(node)):
		node.owner = null
	for child in node.get_children():
		_clear_invalid_scene_owners(child)

func _is_particle_node(node: Variant) -> bool:
	return node is CPUParticles2D or node is GPUParticles2D \
		or node is CPUParticles3D or node is GPUParticles3D

func _is_finite_color(color: Color) -> bool:
	return is_finite(color.r) and is_finite(color.g) and is_finite(color.b) and is_finite(color.a)

func _shader_parameter_problem(material: ShaderMaterial, parameter: StringName,
		value: Variant) -> String:
	if not is_instance_valid(material):
		return "target must be a live ShaderMaterial"
	if material.shader == null:
		return "ShaderMaterial has no Shader assigned"
	if parameter.is_empty():
		return "parameter name must not be empty"
	for uniform in material.shader.get_shader_uniform_list():
		if StringName(uniform.get("name", &"")) != parameter:
			continue
		var expected_type := int(uniform.get("type", TYPE_NIL))
		if expected_type == TYPE_OBJECT:
			if not value is Resource:
				return "value must be a Resource for shader parameter '%s'" % parameter
			var expected_class := StringName(uniform.get("class_name", &""))
			if not expected_class.is_empty() and not value.is_class(expected_class):
				return "value must be a %s for shader parameter '%s'" % [expected_class, parameter]
			return ""
		if typeof(value) == expected_type \
				or expected_type in [TYPE_INT, TYPE_FLOAT] and typeof(value) in [TYPE_INT, TYPE_FLOAT]:
			return ""
		return "value type does not match shader parameter '%s'" % parameter
	return "shader parameter '%s' was not found" % parameter

func _audio_finished_signal(node: Node) -> Signal:
	if node is AudioStreamPlayer:
		return (node as AudioStreamPlayer).finished
	if node is AudioStreamPlayer2D:
		return (node as AudioStreamPlayer2D).finished
	if node is AudioStreamPlayer3D:
		return (node as AudioStreamPlayer3D).finished
	return Signal()

## Editor/runtime checks for host references and typed resources used by built-in StagingVerbs.
func validate_step(rule_id: StringName, step: Step, bb: Blackboard) -> Array[String]:
	var problems: Array[String] = []
	if step.args.is_empty():
		return problems
	var target: Variant = step.args[0]
	if step.verb in [&"light", &"show_node", &"pop", &"bounce", &"say", &"say_key", &"move_to", &"snap_to_marker"]:
		if not target is Node3D or not is_instance_valid(target):
			problems.append("rule '%s' '%s' step requires a valid Node3D target" % [rule_id, step.verb])
	if step.verb == &"move_to" and step.args.size() > 1:
		if not step.args[1] is Node3D or not is_instance_valid(step.args[1]):
			problems.append("rule '%s' move_to destination must be a valid Node3D" % rule_id)
	if step.verb == &"snap_to_marker":
		if step.args.size() < 2 or not step.args[1] is Marker3D or not is_instance_valid(step.args[1]):
			problems.append("rule '%s' snap_to_marker marker must be a valid Marker3D" % rule_id)
		var player: Variant = step.args[2] if step.args.size() > 2 else null
		var animation: Variant = step.args[3] if step.args.size() > 3 else &""
		var animation_time: Variant = step.args[4] if step.args.size() > 4 else 0.0
		if player != null and (not player is AnimationPlayer or not is_instance_valid(player)):
			problems.append("rule '%s' snap_to_marker pose target must be an AnimationPlayer" % rule_id)
		if (player == null) != (animation is StringName and animation.is_empty()):
			problems.append("rule '%s' snap_to_marker pose must specify both AnimationPlayer and animation name, or neither" % rule_id)
		elif player != null and animation is StringName and not (player as AnimationPlayer).has_animation(animation):
			problems.append("rule '%s' snap_to_marker animation was not found on its AnimationPlayer" % rule_id)
		if not (animation_time is int or animation_time is float) or not is_finite(float(animation_time)) or float(animation_time) < 0.0:
			problems.append("rule '%s' snap_to_marker animation time must be finite and nonnegative" % rule_id)
	if step.verb == &"light":
		if step.args.size() > 2 and float(step.args[2]) < 0.0:
			problems.append("rule '%s' light duration must be zero or greater" % rule_id)
		if step.args.size() > 3:
			var key: Variant = step.args[3]
			if not key is StringName:
				problems.append("rule '%s' light key must be a Blackboard StringName or empty" % rule_id)
			elif not key.is_empty():
				if not bb.has(key):
					problems.append("rule '%s' light key '%s' is not declared on the Blackboard" % [rule_id, key])
				elif bb.schema[bb.resolve_key(key)].get("type", TYPE_NIL) != TYPE_BOOL:
					problems.append("rule '%s' light key '%s' must be Boolean" % [rule_id, key])
	if step.verb == &"play_audio":
		if not target is Node or not is_instance_valid(target) or not _is_audio_player(target):
			problems.append("rule '%s' play_audio target must be an AudioStreamPlayer, AudioStreamPlayer2D, or AudioStreamPlayer3D" % rule_id)
		elif target.get("stream") == null:
			problems.append("rule '%s' play_audio target has no AudioStream assigned" % rule_id)
		if step.args.size() > 2 and not _is_nonnegative_finite_number(step.args[2]):
			problems.append("rule '%s' play_audio timeout must be finite and zero or greater" % rule_id)
	if step.verb == &"stop_audio":
		if not _is_audio_player(target) or not is_instance_valid(target):
			problems.append("rule '%s' stop_audio target must be a valid AudioStreamPlayer" % rule_id)
	if step.verb == &"set_audio_pitch":
		if not _is_audio_player(target) or not is_instance_valid(target):
			problems.append("rule '%s' set_audio_pitch target must be a valid AudioStreamPlayer" % rule_id)
		if step.args.size() < 2 or not _is_positive_finite_number(step.args[1]):
			problems.append("rule '%s' set_audio_pitch pitch must be finite and greater than zero" % rule_id)
	if step.verb == &"set_audio_bus":
		if not _is_audio_player(target) or not is_instance_valid(target):
			problems.append("rule '%s' set_audio_bus target must be a valid AudioStreamPlayer" % rule_id)
		if step.args.size() < 2 or not step.args[1] is StringName or step.args[1].is_empty():
			problems.append("rule '%s' set_audio_bus requires a nonempty StringName bus" % rule_id)
		elif AudioServer.get_bus_index(step.args[1]) < 0:
			problems.append("rule '%s' set_audio_bus bus '%s' does not exist" % [rule_id, step.args[1]])
	if step.verb in [&"set_light_color", &"set_light_energy", &"flicker_light"]:
		if not target is Light3D or not is_instance_valid(target):
			problems.append("rule '%s' '%s' target must be a valid Light3D" % [rule_id, step.verb])
	if step.verb == &"set_light_color" and (step.args.size() < 2 or not step.args[1] is Color
			or not _is_finite_color(step.args[1])):
		problems.append("rule '%s' set_light_color requires a Color value" % rule_id)
	if step.verb == &"set_light_energy" and (step.args.size() < 2
			or not _is_nonnegative_finite_number(step.args[1])):
		problems.append("rule '%s' set_light_energy requires finite energy >= 0" % rule_id)
	if step.verb == &"flicker_light":
		if step.args.size() < 3 or not _is_nonnegative_finite_number(step.args[1]) \
				or not _is_nonnegative_finite_number(step.args[2]) or float(step.args[2]) < float(step.args[1]):
			problems.append("rule '%s' flicker_light requires finite 0 <= low_energy <= high_energy" % rule_id)
		if step.args.size() > 3 and not _is_positive_finite_number(step.args[3]):
			problems.append("rule '%s' flicker_light interval must be finite and greater than zero" % rule_id)
		if step.args.size() > 4 and not _is_positive_finite_number(step.args[4]):
			problems.append("rule '%s' flicker_light duration must be finite and greater than zero" % rule_id)
	if step.verb == &"restart_particles" and not _is_particle_node(target):
		problems.append("rule '%s' restart_particles target must be a CPU or GPU particles node" % rule_id)
	if step.verb == &"set_shader_parameter":
		if not target is ShaderMaterial or not is_instance_valid(target):
			problems.append("rule '%s' set_shader_parameter target must be a live ShaderMaterial" % rule_id)
		elif step.args.size() < 3:
			problems.append("rule '%s' set_shader_parameter requires a parameter name and value" % rule_id)
		elif not step.args[1] is StringName or step.args[1].is_empty():
			problems.append("rule '%s' set_shader_parameter name must be a nonempty StringName" % rule_id)
		else:
			var shader_problem := _shader_parameter_problem(target, step.args[1], step.args[2])
			if not shader_problem.is_empty():
				problems.append("rule '%s' set_shader_parameter: %s" % [rule_id, shader_problem])
	if step.verb == &"spawn":
		if not target is PackedScene or not is_instance_valid(target):
			problems.append("rule '%s' spawn requires a live PackedScene" % rule_id)
		if step.args.size() < 2 or not step.args[1] is Node or not is_instance_valid(step.args[1]):
			problems.append("rule '%s' spawn requires a live parent Node" % rule_id)
		else:
			var owner: Variant = step.args[2] if step.args.size() > 2 else null
			if owner != null and (not owner is Node or not is_instance_valid(owner)
					or not _is_valid_scene_owner(owner, step.args[1])):
				problems.append("rule '%s' spawn owner must be the parent or one of its ancestors" % rule_id)
			if step.args.size() > 3 and step.args[3] != null \
					and not step.args[3] is Transform2D and not step.args[3] is Transform3D:
				problems.append("rule '%s' spawn transform must be Transform2D, Transform3D, or null" % rule_id)
	if step.verb == &"despawn":
		if not target is Node or not is_instance_valid(target):
			problems.append("rule '%s' despawn target must be a live Node" % rule_id)
		if step.args.size() < 2:
			problems.append("rule '%s' despawn requires an expected owner (null for an unowned node)" % rule_id)
		elif step.args[1] != null and (not step.args[1] is Node or not is_instance_valid(step.args[1])):
			problems.append("rule '%s' despawn expected owner must be a live Node or null" % rule_id)
		elif is_instance_valid(target) and target.owner != step.args[1]:
			problems.append("rule '%s' despawn expected owner does not match the target" % rule_id)
		if step.args.size() > 2 and not step.args[2] is bool:
			problems.append("rule '%s' despawn destroy flag must be Boolean" % rule_id)
		if step.args.size() > 3 and not step.args[3] is bool:
			problems.append("rule '%s' despawn transform preservation flag must be Boolean" % rule_id)
	if step.verb == &"reparent":
		if not target is Node or not is_instance_valid(target):
			problems.append("rule '%s' reparent target must be a live Node" % rule_id)
		if step.args.size() < 4 or not step.args[1] is Node or not is_instance_valid(step.args[1]):
			problems.append("rule '%s' reparent requires a live new parent and explicit old/new owners" % rule_id)
		else:
			var expected_owner: Variant = step.args[2]
			var new_owner: Variant = step.args[3]
			if expected_owner != null and (not expected_owner is Node or not is_instance_valid(expected_owner)):
				problems.append("rule '%s' reparent expected owner must be a live Node or null" % rule_id)
			elif is_instance_valid(target) and target.owner != expected_owner:
				problems.append("rule '%s' reparent expected owner does not match the target" % rule_id)
			if new_owner != null and (not new_owner is Node or not is_instance_valid(new_owner)
					or not _is_valid_scene_owner(new_owner, step.args[1])):
				problems.append("rule '%s' reparent new owner must be the parent or one of its ancestors" % rule_id)
			if is_instance_valid(target) and (target == step.args[1] or target.is_ancestor_of(step.args[1])):
				problems.append("rule '%s' reparent would create a node cycle" % rule_id)
		if step.args.size() > 4 and not step.args[4] is bool:
			problems.append("rule '%s' reparent transform preservation flag must be Boolean" % rule_id)
	if step.verb == &"rotate_to":
		if not target is Node3D or not is_instance_valid(target):
			problems.append("rule '%s' rotate_to target must be a valid Node3D" % rule_id)
		problems.append_array(_validate_tween_options(rule_id, step.args, 2, 4, 5, "rotate_to"))
	if step.verb == &"move_to":
		problems.append_array(_validate_tween_options(rule_id, step.args, 3, 4, 5, "move_to"))
	if step.verb == &"follow_path":
		if step.args.size() < 2 or not step.args[1] is Path3D or not is_instance_valid(step.args[1]):
			problems.append("rule '%s' follow_path path must be a valid Path3D" % rule_id)
		elif step.args[1].curve == null or step.args[1].curve.get_baked_length() <= 0.0:
			problems.append("rule '%s' follow_path requires a Path3D with a nonempty Curve3D" % rule_id)
		problems.append_array(_validate_tween_options(rule_id, step.args, 2, 5, 6, "follow_path"))
	if step.verb == &"tween_property":
		if step.args.size() < 3 or not step.args[0] is Object or not is_instance_valid(step.args[0]):
			problems.append("rule '%s' tween_property target must be a live Object" % rule_id)
		elif not step.args[1] is NodePath or not _is_tween_property_writable(step.args[0], step.args[1]):
			problems.append("rule '%s' tween_property path must identify a writable property" % rule_id)
		else:
			var current_value: Variant = step.args[0].get_indexed(step.args[1])
			if not _tween_values_compatible(current_value, step.args[2]):
				problems.append("rule '%s' tween_property value type is incompatible with its property" % rule_id)
		problems.append_array(_validate_tween_options(rule_id, step.args, 3, 5, 6, "tween_property"))
	if step.verb in [&"play_animation", &"pose_animation"]:
		if not target is AnimationPlayer or not is_instance_valid(target):
			problems.append("rule '%s' '%s' target must be a valid AnimationPlayer" % [rule_id, step.verb])
		elif step.args.size() > 1 and (not step.args[1] is StringName or not target.has_animation(step.args[1])):
			problems.append("rule '%s' '%s' names an animation not found on its AnimationPlayer" % [rule_id, step.verb])
		if step.verb == &"play_animation":
			if step.args.size() > 3 and not _is_nonnegative_finite_number(step.args[3]):
				problems.append("rule '%s' play_animation timeout must be finite and zero or greater" % rule_id)
			if step.args.size() > 4 and (not (step.args[4] is int or step.args[4] is float)
					or not is_finite(float(step.args[4])) or float(step.args[4]) < -1.0):
				problems.append("rule '%s' play_animation blend must be finite and at least -1" % rule_id)
			if step.args.size() > 5 and not _is_positive_finite_number(step.args[5]):
				problems.append("rule '%s' play_animation speed must be finite and greater than zero" % rule_id)
	if step.verb == &"set_animation_speed":
		if not target is AnimationPlayer or not is_instance_valid(target):
			problems.append("rule '%s' set_animation_speed target must be a valid AnimationPlayer" % rule_id)
		if step.args.size() < 2 or not _is_positive_finite_number(step.args[1]):
			problems.append("rule '%s' set_animation_speed value must be finite and greater than zero" % rule_id)
	if step.verb == &"flash" or step.verb == &"jump":
		if not target is MeshInstance3D or not is_instance_valid(target):
			problems.append("rule '%s' '%s' target must be a valid MeshInstance3D" % [rule_id, step.verb])
		elif step.verb == &"flash" and not _has_effect_material(target):
			problems.append("rule '%s' flash target '%s' has no compatible BaseMaterial3D surface or override" % [rule_id, target.name])
	if step.verb == &"gameplay_event":
		if not step.args[0] is StringName or step.args[0].is_empty():
			problems.append("rule '%s' gameplay_event requires a non-empty StringName event ID" % rule_id)
	if step.verb == &"gameplay_request":
		if not step.args[0] is StringName or step.args[0].is_empty():
			problems.append("rule '%s' gameplay_request requires a non-empty StringName event ID" % rule_id)
		if step.args.size() > 2 and (not step.args[2] is float and not step.args[2] is int
				or float(step.args[2]) < 0.0):
			problems.append("rule '%s' gameplay_request timeout must be a nonnegative number" % rule_id)
		if step.args.size() > 3:
			if not step.args[3] is Dictionary:
				problems.append("rule '%s' gameplay_request response schema must be a Dictionary" % rule_id)
			elif is_instance_valid(context.host) and context.host is Stage:
				problems.append_array((context.host as Stage).validate_gameplay_response_schema(step.args[3]))
		if step.args.size() > 5 and (not step.args[5] is int or step.args[5] < 0):
			problems.append("rule '%s' gameplay_request correlation ID must be a nonnegative integer" % rule_id)
	return problems

func _has_effect_material(mesh: MeshInstance3D) -> bool:
	if mesh.material_override is BaseMaterial3D:
		return true
	if mesh.material_override != null or mesh.mesh == null:
		return false
	for surface in mesh.mesh.get_surface_count():
		if mesh.get_active_material(surface) is BaseMaterial3D:
			return true
	return false
