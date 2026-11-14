@tool
class_name StagingVerbs extends CoreVerbs
## Steps that stage props and actors in the scene.

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
		if not _is_audio_player(player):
			push_warning("Callboard play_audio skipped: target must be an AudioStreamPlayer, AudioStreamPlayer2D, or AudioStreamPlayer3D.")
			return null
		if player.get("stream") == null:
			push_warning("Callboard play_audio skipped: the target has no AudioStream assigned.")
			return null
		if timeout < 0.0:
			push_warning("Callboard play_audio skipped: timeout must be zero or greater.")
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
		wait_for_completion := true) -> Step:
	var host := context.host
	var f := func(payload: Dictionary) -> Variant:
		if duration < 0.0:
			push_warning("Callboard rotate_to skipped: duration must be zero or greater.")
			return null
		if duration == 0.0:
			n.rotation = target_rotation
			return null
		var tween := host.create_tween()
		tween.tween_property(n, "rotation", target_rotation, duration)
		return _animation_completion(payload, tween.finished) if wait_for_completion else null
	return Step.new(f)

## Play an AnimationPlayer clip. A positive timeout cancels a wait that runs too long.
func play_animation(player: AnimationPlayer, animation: StringName,
		wait_for_completion := true, timeout := 0.0) -> Step:
	var f := func(payload: Dictionary) -> Variant:
		if player == null or not is_instance_valid(player) or not player.has_animation(animation):
			push_warning("Callboard play_animation skipped: animation '%s' is missing from its AnimationPlayer." % animation)
			return null
		if timeout < 0.0:
			push_warning("Callboard play_animation skipped: timeout must be zero or greater.")
			return null
		if not wait_for_completion:
			_supersede_animation_playback(player)
			player.play(animation)
			return null
		var ticket := _supersede_animation_playback(player)
		player.play(animation)
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
	var f := func(_c: Dictionary) -> void:
		var label := n.get_node_or_null(NodePath(SPEECH_LABEL_NAME)) as Label3D
		if label == null:
			label = Label3D.new()
			label.name = SPEECH_LABEL_NAME
			n.add_child(label)
		else:
			var previous: Tween = label.get_meta(SPEECH_TWEEN_META) if label.has_meta(SPEECH_TWEEN_META) else null
			if previous and previous.is_running():
				previous.kill()
		label.text = text
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

func move_to(n: Node3D, dest: Node3D, offset := Vector3.ZERO, duration := 0.7) -> Step:
	var host := context.host
	var move := func(payload: Dictionary) -> Signal:
		var target_global := dest.global_position + offset
		var parent := n.get_parent_node_3d()
		var target_local := target_global if parent == null or n.top_level else parent.to_local(target_global)
		n.set_meta(BASE_Y_META, target_local.y)
		var tween := host.create_tween()
		var set_position := _position_setter(n, tween, ^"global_position")
		tween.tween_method(set_position, n.global_position, target_global, duration)
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
		if target == null:
			return
		var current_tween := target.get_meta(POSITION_TWEEN_META, null) as Tween
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
	if step.verb in [&"light", &"show_node", &"pop", &"bounce", &"say", &"move_to"]:
		if not target is Node3D or not is_instance_valid(target):
			problems.append("rule '%s' '%s' step requires a valid Node3D target" % [rule_id, step.verb])
	if step.verb == &"move_to" and step.args.size() > 1:
		if not step.args[1] is Node3D or not is_instance_valid(step.args[1]):
			problems.append("rule '%s' move_to destination must be a valid Node3D" % rule_id)
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
		if step.args.size() > 2 and float(step.args[2]) < 0.0:
			problems.append("rule '%s' play_audio timeout must be zero or greater" % rule_id)
	if step.verb == &"rotate_to":
		if not target is Node3D or not is_instance_valid(target):
			problems.append("rule '%s' rotate_to target must be a valid Node3D" % rule_id)
		if step.args.size() > 2 and float(step.args[2]) < 0.0:
			problems.append("rule '%s' rotate_to duration must be zero or greater" % rule_id)
	if step.verb in [&"play_animation", &"pose_animation"]:
		if not target is AnimationPlayer or not is_instance_valid(target):
			problems.append("rule '%s' '%s' target must be a valid AnimationPlayer" % [rule_id, step.verb])
		elif step.args.size() > 1 and (not step.args[1] is StringName or not target.has_animation(step.args[1])):
			problems.append("rule '%s' '%s' names an animation not found on its AnimationPlayer" % [rule_id, step.verb])
		if step.verb == &"play_animation" and step.args.size() > 3 and float(step.args[3]) < 0.0:
			problems.append("rule '%s' play_animation timeout must be zero or greater" % rule_id)
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
