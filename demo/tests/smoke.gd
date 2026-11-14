extends SceneTree
## Short runtime smoke test using the real scene and physics overlap checks.

const STAGE_SCENE_PATH := "res://demo/stages/stage_01/stage_01.tscn"
const GAME_SCENE_PATH := "res://demo/game.tscn"

func _initialize() -> void:
	var packed := load(STAGE_SCENE_PATH) as PackedScene
	var stage := packed.instantiate() as Stage01
	var ok := _check("the packed scene owns its set, guard, and pad",
		stage.guard == stage.get_node("Guard") and stage.has_node("Ground")
		and stage.get_node("BumpPad") is BumpProp and not stage.has_node("TreatProp"))
	root.add_child(stage)
	await process_frame

	ok = _check("scene-placed and scripted props resolve when the stage builds",
		stage.window == stage.get_node("Window") and stage.treat == stage.get_node("TreatProp")
		and stage.decoy == stage.get_node("DecoyProp") and not stage.treat.visible
		and stage.graph_errors.is_empty() and stage.check().is_empty()) and ok
	ok = (await _test_staging_verbs(stage)) and ok
	var fired: Array[StringName] = []
	stage.rule_fired.connect(func(id: StringName, _event: StringName) -> void: fired.append(id))
	stage.activate()
	stage.activate()
	ok = _check("activating twice starts only one standoff loop", fired.count(&"z1_standoff") == 1) and ok
	stage.fire(&"give:duck")
	ok = _check("a dark lamp still requires the guard to be off duty",
		fired.has(&"z1_on_duty") and not stage.has_fired(&"z1_delivered")) and ok
	var changes: Array = []
	stage.var_changed.connect(func(key: StringName, value: Variant) -> void:
		changes.append([key, value]))
	stage.write_var(&"guard_calmed", true)
	ok = _check("stage forwards Blackboard writes to gameplay listeners",
		changes == [[&"guard_calmed", true]] and stage.saved_vars[&"guard_calmed"]) and ok
	stage.fire(&"file:permit")
	stage.fire(&"give:duck")
	stage.fire(&"give:duck")
	await process_frame

	var delivered_count := 0
	for id in fired:
		if id == &"z1_delivered":
			delivered_count += 1
	ok = _check("deliver fires the eligible rule once",
		delivered_count == 1 and stage.fired.has(&"z1_delivered")) and ok
	ok = _check("deliver guard prevents the caught rule", not fired.has(&"z1_caught")) and ok

	ok = (await _test_player_and_bump(stage, fired)) and ok
	stage.deactivate()
	# Let the cancelled 3.5-second standoff loop unwind before freeing the Stage.
	await create_timer(3.5).timeout
	stage.queue_free()
	await process_frame
	ok = (await _test_game_scene()) and ok
	print("SMOKE: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)

func _test_player_and_bump(stage: Stage, fired: Array[StringName]) -> bool:
	var ok := true
	var movement := {
		&"move_left": [KEY_A, KEY_LEFT],
		&"move_right": [KEY_D, KEY_RIGHT],
		&"move_forward": [KEY_W, KEY_UP],
		&"move_back": [KEY_S, KEY_DOWN],
	}
	for action in movement:
		var keys: Array[Key] = []
		for binding in InputMap.action_get_events(action):
			if binding is InputEventKey:
				keys.append(binding.physical_keycode)
		ok = _check("%s retains its default keys" % action, keys == movement[action]) and ok

	var player := Player.new()
	player.position = Vector3(0, 1, 4)
	root.add_child(player)
	var nearest := Props.trigger_box(stage, Vector3.ONE, Vector3(0.5, 1, 4), &"near")
	var farther := Props.trigger_box(stage, Vector3.ONE, Vector3(1, 1, 4), &"far")
	var enter_only := Props.trigger_box(stage, Vector3.ONE, Vector3(0, 1, 4), &"enter_only")
	nearest.name = "NearArea"
	farther.name = "FarArea"
	nearest.prompt_text = "Nearby choice"
	farther.prompt_text = "Far choice"
	enter_only.mode = TriggerArea.Mode.ENTER
	var tie := Props.trigger_box(stage, Vector3.ONE, Vector3(0.5, 1, 4), &"tie")
	tie.name = "TieArea"
	tie.prompt_text = "Tie choice"
	var interactions: Array[StringName] = []
	for event in [&"near", &"far"]:
		var rule := Rule.new(event, event)
		rule.steps.append(Step.new(func(_ctx: Dictionary) -> void: interactions.append(event)))
		stage.engine.rules.append(rule)
	var prompt_changes: Array[String] = []
	player.interaction_resolver.prompt_changed.connect(func(text: String, _icon: Texture2D, _priority: int) -> void:
		prompt_changes.append(text))
	for frame in range(3):
		await physics_frame
	ok = _check("all test areas overlap the player",
		player._reach.overlaps_area(nearest) and player._reach.overlaps_area(farther)
		and player._reach.overlaps_area(enter_only)) and ok
	var interact_key := InputEventKey.new()
	interact_key.physical_keycode = KEY_E
	interact_key.pressed = true
	player._unhandled_input(interact_key)
	ok = _check("E interacts only with the nearest eligible area", interactions == [&"near"]) and ok
	interact_key.echo = true
	player._unhandled_input(interact_key)
	ok = _check("interaction ignores held-key repeats", interactions.size() == 1) and ok
	var resolver := player.interaction_resolver
	farther.interaction_priority = 5
	resolver.refresh()
	ok = _check("higher priority selects its trigger and updates the prompt",
		resolver.selected_trigger == farther and resolver._prompt_text == "Far choice") and ok
	var far_available := [true]
	farther.set_eligibility_hook(func(actor: Node) -> bool: return actor == player and far_available[0])
	far_available[0] = false
	resolver.refresh()
	ok = _check("eligibility changes replace the selected prompt while the actor remains in range",
		resolver.selected_trigger == nearest and resolver._prompt_text == "Nearby choice") and ok
	far_available[0] = true
	resolver.refresh()
	ok = _check("an available higher-priority trigger becomes selected again without leaving the range",
		resolver.selected_trigger == farther and prompt_changes[-1] == "Far choice") and ok
	far_available[0] = false
	resolver.refresh()
	var tie_paths: Array[String] = [String(nearest.get_path()), String(tie.get_path())]
	tie_paths.sort()
	ok = _check("equal-priority, equal-distance triggers use a stable node-path tie-break",
		resolver.selected_trigger == (nearest if tie_paths[0] == String(nearest.get_path()) else tie)) and ok
	farther.interaction_priority = 0
	resolver.refresh()
	ok = _check("one prompt is exposed for the selected trigger", resolver.selected_trigger == nearest
		and resolver._prompt_text == "Nearby choice") and ok
	var accepted_result := resolver.interact({"tool": "permit"})
	await process_frame
	ok = _check("accepted interactions dispatch the trigger Call with their context payload",
		accepted_result.get("accepted", false) and accepted_result["event"] == &"near"
		and accepted_result["payload"].get("tool") == "permit" and interactions == [&"near", &"near"]) and ok
	var rejection_payloads: Array[Dictionary] = []
	var rejected_rule := Rule.new(&"near_rejected", &"near_rejected")
	rejected_rule.steps.append(Step.new(func(c: Dictionary) -> void:
		rejection_payloads.append(c["payload"].duplicate(true))))
	stage.engine.rules.append(rejected_rule)
	nearest.rejected_event = &"near_rejected"
	nearest.set_interaction_handler(func(actor: Node, context: Dictionary) -> Dictionary:
		return {"accepted": false, "payload": {"reason": "missing_tool", "tool": context.get("tool", ""), "actor": actor == player}})
	var rejected_result := resolver.interact({"tool": "permit"})
	await process_frame
	ok = _check("interaction handlers can reject and route their context payload to a separate Call",
		not rejected_result.get("accepted", true) and rejected_result["event"] == &"near_rejected"
		and rejection_payloads == [{"reason": "missing_tool", "tool": "permit", "actor": true}]) and ok

	player.stun(1.0)
	var timer := player._stun_timer
	player.stun(5.0)
	player.stun(0.1)
	player.interact()
	ok = _check("overlapping stuns keep the longest remaining duration and block interaction",
		player.stunned and player._stun_timer == timer and timer.time_left == 5.0
		and interactions.size() == 2) and ok
	var stage_wait := stage._wait(0.05)
	var stage_timer := stage_wait.get_object() as SceneTreeTimer
	var stage_timeouts: Array[bool] = []
	stage_wait.connect(func() -> void: stage_timeouts.append(true))
	paused = true
	await create_timer(0.1).timeout
	ok = _check("stage waits and player stuns freeze while the tree is paused",
		is_equal_approx(stage_timer.time_left, 0.05) and is_equal_approx(timer.time_left, 5.0)
		and stage_timeouts.is_empty() and player.stunned) and ok
	paused = false
	await create_timer(0.1).timeout
	ok = _check("stage waits resume when the tree unpauses", stage_timeouts == [true]) and ok
	timer.time_left = 0.0
	await timer.timeout
	ok = _check("the stun ends when its extended timer expires", not player.stunned) and ok

	var pad := stage.get_node("BumpPad") as BumpProp
	pad.bump_area.body_entered.emit(player)
	pad.bump_area.body_entered.emit(player)
	ok = _check("bumping twice latches the key and dispatches the relay once",
		stage.is_set(&"treat_out") and fired.count(&"z1_treat") == 1
		and fired.count(&"bump_prop") == 1) and ok
	player.queue_free()
	return ok

func _test_staging_verbs(stage: Stage) -> bool:
	var mesh := MeshInstance3D.new()
	mesh.name = "EffectTestMesh"
	var source_material := Props.mat(Color(0.2, 0.4, 0.8))
	mesh.material_override = source_material
	stage.add_child(mesh)
	var base := source_material.albedo_color
	var verbs := stage.verbs as StagingVerbs
	var keyless_light := verbs.light(mesh, true)
	keyless_light.fn.call({})
	var keyless_light_works := mesh.visible and keyless_light.sets.is_empty()
	mesh.hide()
	var shared_mesh_resource := BoxMesh.new()
	var shared_surface := Props.mat(Color(0.15, 0.35, 0.65))
	shared_mesh_resource.surface_set_material(0, shared_surface)
	var first_prop := MeshInstance3D.new()
	first_prop.mesh = shared_mesh_resource
	var second_prop := MeshInstance3D.new()
	second_prop.mesh = shared_mesh_resource
	stage.add_child(first_prop)
	stage.add_child(second_prop)
	var surface_flash := verbs.flash(first_prop).fn.call({}) as Signal
	var first_effect_material := first_prop.get_active_material(0) as BaseMaterial3D
	var second_effect_material := second_prop.get_active_material(0) as BaseMaterial3D
	var isolated_surface_materials := (
		first_effect_material != shared_surface and second_effect_material == shared_surface)
	await surface_flash
	var shared_surface_unchanged := shared_surface.albedo_color.is_equal_approx(Color(0.15, 0.35, 0.65))
	first_prop.queue_free()
	second_prop.queue_free()
	var flash_rule := Rule.new(&"test_flash", &"test_flash")
	var completed: Array[bool] = []
	flash_rule.steps.append(verbs.flash(mesh))
	flash_rule.steps.append(Step.new(func(_ctx: Dictionary) -> void: completed.append(true)))
	var jump_rule := Rule.new(&"test_jump", &"test_jump")
	jump_rule.steps.append(verbs.jump(mesh))
	stage.engine.rules.append_array([flash_rule, jump_rule])
	stage.fire(&"test_flash")
	stage.fire(&"test_jump")
	await create_timer(1.0).timeout
	var material := mesh.material_override as BaseMaterial3D
	var ok := _check("jump restores its original material color and height",
		material.albedo_color.is_equal_approx(base) and is_zero_approx(mesh.position.y)
		and material != source_material and source_material.albedo_color.is_equal_approx(base))
	ok = _check("timed-light key is optional for visibility-only actions", keyless_light_works) and ok
	ok = _check("surface tint duplicates shared materials on only the target mesh",
		isolated_surface_materials and shared_surface_unchanged) and ok
	ok = _check("an interrupted flash advances the rule and clears its active state",
		completed == [true] and stage.engine.active_snapshot().is_empty()) and ok
	await verbs.flash(mesh).fn.call({})
	ok = _check("a later flash returns to the original material color",
		material.albedo_color.is_equal_approx(base)) and ok
	mesh.position.y = 2.0
	await verbs.jump(mesh).fn.call({})
	ok = _check("a later jump returns to the mesh's new height", is_equal_approx(mesh.position.y, 2.0)) and ok
	var bare_mesh := MeshInstance3D.new()
	bare_mesh.mesh = BoxMesh.new()
	stage.add_child(bare_mesh)
	await verbs.jump(bare_mesh).fn.call({})
	ok = _check("jump still performs its transform when the mesh has no tintable material",
		is_zero_approx(bare_mesh.position.y)) and ok
	bare_mesh.queue_free()

	var rotation_target := Node3D.new()
	stage.add_child(rotation_target)
	var rotate_step := verbs.rotate_to(rotation_target, Vector3(0, 0.6, 0), 0.05, true)
	await rotate_step.fn.call({})
	ok = _check("rotate_to waits for the requested rotation tween",
		is_equal_approx(rotation_target.rotation.y, 0.6)) and ok

	var animated_root := Node3D.new()
	var animated_target := Node3D.new()
	animated_target.name = "AnimatedTarget"
	animated_root.add_child(animated_target)
	var animation_player := AnimationPlayer.new()
	animated_root.add_child(animation_player)
	stage.add_child(animated_root)
	var animation := Animation.new()
	animation.length = 0.1
	var track := animation.add_track(Animation.TYPE_VALUE)
	animation.track_set_path(track, NodePath("AnimatedTarget:rotation"))
	animation.track_insert_key(track, 0.0, Vector3.ZERO)
	animation.track_insert_key(track, 0.1, Vector3(0, 0.8, 0))
	var animation_library := AnimationLibrary.new()
	animation_library.add_animation(&"turn", animation)
	animation_player.add_animation_library(&"", animation_library)
	var animation_finished := [false]
	var animation_rule := Rule.new(&"test_animation", &"test_animation")
	animation_rule.steps.append(verbs.play_animation(animation_player, &"turn", true))
	animation_rule.steps.append(Step.new(func(_ctx: Dictionary) -> void: animation_finished[0] = true))
	stage.engine.rules.append(animation_rule)
	stage.fire(&"test_animation")
	await create_timer(0.15).timeout
	ok = _check("play_animation waits for the named AnimationPlayer clip",
		animation_finished[0] and is_equal_approx(animated_target.rotation.y, 0.8)) and ok
	var pose := verbs.pose_animation(animation_player, &"turn", 0.05)
	pose.fn.call({})
	await process_frame
	ok = _check("pose_animation seeks and pauses at the requested clip time",
		not animation_player.is_playing() and animated_target.rotation.y > 0.0) and ok
	stage.engine.rules.erase(animation_rule)
	animated_root.queue_free()
	rotation_target.queue_free()

	var emitted_gameplay_events: Array = []
	stage.gameplay_event.connect(func(event_id: StringName, arguments: Dictionary) -> void:
		emitted_gameplay_events.append([event_id, arguments.duplicate(true)]))
	var outbound_step := verbs.gameplay_event(&"door_unlocked", {"door": &"north", "forced": false})
	outbound_step.fn.call({})
	ok = _check("gameplay_event emits a typed ID and copied argument payload",
		emitted_gameplay_events == [[&"door_unlocked", {"door": &"north", "forced": false}]]) and ok

	var audio := AudioStreamPlayer.new()
	var audio_stream := AudioStreamGenerator.new()
	audio_stream.buffer_length = 5.0
	audio.stream = audio_stream
	stage.add_child(audio)
	var audio_completed := [false]
	var audio_rule := Rule.new(&"test_audio", &"test_audio")
	audio_rule.steps.append(verbs.play_audio(audio, true))
	audio_rule.steps.append(Step.new(func(_ctx: Dictionary) -> void: audio_completed[0] = true))
	stage.engine.rules.append(audio_rule)
	stage.fire(&"test_audio")
	await create_timer(0.05).timeout
	var audio_waiting: bool = audio.playing and not audio_completed[0]
	stage.deactivate()
	await process_frame
	ok = _check("play_audio can await completion and releases that wait on Stage deactivation",
		audio_waiting and not audio_completed[0] and stage.engine._awaited_signals.is_empty()) and ok
	audio.stop()
	stage.engine.rules.erase(audio_rule)
	audio.queue_free()
	var destination := Node3D.new()
	stage.add_child(destination)
	destination.position = Vector3(2, 3, 4)
	var move_rule := Rule.new(&"test_move", &"test_move")
	move_rule.steps.append(verbs.move_to(mesh, destination, Vector3.ZERO, 0.5))
	move_rule.steps.append(Step.new(func(_payload: Dictionary) -> void: completed.append(true)))
	stage.engine.rules.append(move_rule)
	stage.fire(&"test_move")
	stage.fire(&"test_jump")
	await create_timer(0.7).timeout
	ok = _check("a jump replaces movement and both rules finish",
		completed.size() == 2 and stage.engine.active_snapshot().is_empty()
		and is_equal_approx(mesh.position.y, destination.position.y)) and ok
	stage.fire(&"test_move")
	stage.deactivate()
	ok = _check("deactivation immediately releases a rule waiting for movement",
		stage.engine.active_snapshot().is_empty() and stage.engine._awaited_signals.is_empty()) and ok
	await create_timer(0.7).timeout
	ok = _check("deactivated movement finishes visually without running later steps",
		mesh.global_position.is_equal_approx(destination.global_position) and completed.size() == 2) and ok
	stage.engine.rules.erase(move_rule)
	destination.queue_free()
	stage.engine.rules.erase(flash_rule)
	stage.engine.rules.erase(jump_rule)
	verbs.say(mesh, "First line", 10.0).fn.call({})
	verbs.say(mesh, "Replacement line", 10.0).fn.call({})
	var speech := mesh.get_node_or_null("CallboardSpeech") as Label3D
	ok = _check("say reuses one speech label for overlapping calls",
		speech != null and speech.text == "Replacement line" and mesh.get_child_count() == 1) and ok
	mesh.queue_free()
	return ok

func _test_game_scene() -> bool:
	var packed := load(GAME_SCENE_PATH) as PackedScene
	if not _check("the main scene loads", packed != null):
		return false
	var game := packed.instantiate() as GameManager
	root.add_child(game)
	await process_frame
	var hud := game.get_node("HUD") as GameHud
	game.stage.scored.emit(25)
	await process_frame
	var ok := _check("the game manager updates the HUD after scoring",
		game.score == 25 and hud._score.text == "Score: 25")
	var has_debug_board := OS.is_debug_build() and ResourceLoader.exists(
		"res://addons/callboard/editor/callboard.gd", "Script")
	ok = _check("the HUD mounts the hidden live panel when available",
		(hud.board_panel != null and not hud.board_panel.visible) if has_debug_board
		else hud.board_panel == null) and ok
	ok = (await _test_touch_controls(game)) and ok
	ok = (await _test_demo_paths(game)) and ok
	game.queue_free()
	await process_frame
	return ok

func _test_touch_controls(game: GameManager) -> bool:
	var hud := game.hud
	var player := game.get_node("WorldManager/Player") as Player
	var stick_center := hud._stick.get_global_rect().get_center()
	var touch_start := game.get_viewport().get_visible_rect().size * Vector2(0.75, 0.5)
	var ok := _check("the first-use hint sits above the bottom-center action button",
		hud._move_hint.visible and is_equal_approx(stick_center.x, hud._interact.get_global_rect().get_center().x)
		and stick_center.y < hud._interact.get_global_rect().position.y)
	var mouse_press := InputEventMouseButton.new()
	mouse_press.button_index = MOUSE_BUTTON_LEFT
	mouse_press.pressed = true
	mouse_press.position = root.get_final_transform() * touch_start
	Input.parse_input_event(mouse_press)
	Input.flush_buffered_events()
	ok = _check("a mouse press away from the hint starts the stick without moving",
		hud._stick._pointer == 0 and player.touch_movement == Vector2.ZERO) and ok
	var mouse_drag := InputEventMouseMotion.new()
	mouse_drag.button_mask = MOUSE_BUTTON_MASK_LEFT
	mouse_drag.position = root.get_final_transform() * (touch_start + Vector2(0, -100))
	Input.parse_input_event(mouse_drag)
	Input.flush_buffered_events()
	var start := player.position
	for frame in range(3):
		await physics_frame
	ok = _check("mouse dragging the stick moves the player",
		player.touch_movement.y < -0.25 and player.position.z < start.z) and ok
	mouse_press = mouse_press.duplicate() as InputEventMouseButton
	mouse_press.position = mouse_drag.position
	mouse_press.pressed = false
	Input.parse_input_event(mouse_press)
	Input.flush_buffered_events()
	ok = _check("releasing the mouse clears movement", player.touch_movement == Vector2.ZERO) and ok
	ok = _check("the first drag dismisses the idle hint",
		hud._stick.has_moved and hud._stick._pointer == -1 and not hud._move_hint.visible) and ok

	player.global_position = (game.stage.get_node("DecoyArea") as TriggerArea).global_position
	for frame in range(3):
		await physics_frame
	var action_center := hud._interact.get_global_rect().get_center()
	_send_touch(1, action_center, true)
	ok = _check("the action button takes priority over starting the stick",
		hud._stick._pointer == -1 and hud._button_pointer == 1) and ok
	_send_touch(1, action_center, false, true)
	_send_touch(0, touch_start, true)
	var drag := InputEventScreenDrag.new()
	drag.index = 0
	drag.position = touch_start + Vector2(104, 0)
	root.push_input(drag, true)
	var knob := hud._stick.get_global_transform_with_canvas() * (hud._stick._origin + hud._stick._offset)
	ok = _check("the floating stick follows a finger at full travel",
		player.touch_movement.is_equal_approx(Vector2.RIGHT)
		and knob.is_equal_approx(drag.position)) and ok
	_send_touch(1, action_center, true)
	# Use the same real resolver while keeping the gameplay smoke test's score intact.
	var selected := player.interaction_resolver.selected_trigger
	var interactions: Array[bool] = []
	selected.set_interaction_handler(func(_actor: Node, _context: Dictionary) -> Dictionary:
		interactions.append(true)
		return {"accepted": false})
	_send_touch(1, action_center, false)
	selected.set_interaction_handler(Callable())
	ok = _check("a second finger taps the selected interaction while holding movement",
		interactions == [true] and player.touch_movement.is_equal_approx(Vector2.RIGHT)) and ok
	_send_touch(0, drag.position, false, true)
	ok = _check("a canceled touch clears movement", player.touch_movement == Vector2.ZERO) and ok
	if hud.board_panel:
		var board_center := hud._board_button.get_global_rect().get_center()
		_send_touch(0, touch_start, true)
		root.push_input(drag, true)
		_send_touch(1, board_center, true)
		_send_touch(1, board_center, false)
		ok = _check("opening Callboard by touch cancels held movement",
			hud.board_panel.visible and player.touch_movement == Vector2.ZERO) and ok
		_send_touch(0, touch_start, false)
		board_center = hud._board_button.get_global_rect().get_center()
		_send_touch(1, board_center, true)
		_send_touch(1, board_center, false)
		ok = _check("the Callboard touch button returns to the demo",
			not hud.board_panel.visible and hud._stick.is_visible_in_tree()) and ok
	return ok

func _send_touch(index: int, position: Vector2, pressed: bool, canceled := false) -> void:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.position = position
	event.pressed = pressed
	event.canceled = canceled
	root.push_input(event, true)

func _test_demo_paths(game: GameManager) -> bool:
	var stage := game.stage as Stage01
	var player := game.get_node("WorldManager/Player") as Player
	var delivery := stage.get_node("DeliveryArea") as TriggerArea
	var shelter := stage.get_node("DecoyArea") as TriggerArea
	var permit_area := stage.get_node("PermitArea") as TriggerArea
	var fired: Array[StringName] = []
	stage.rule_fired.connect(func(id: StringName, _event: StringName) -> void: fired.append(id))
	# Simulate a standoff tick without waiting for the ambient loop's first interval.
	stage.fire(&"relay:standoff_tick")
	await create_timer(0.4).timeout
	player.global_position = delivery.global_position
	for frame in range(3):
		await physics_frame
	player.interact()
	var ok := _check("scene delivery Call uses the lamp guard and the custom stun verb",
		stage.lamp.visible and stage.is_set(&"lamp_on") and player.stunned
		and not stage.has_fired(&"z1_delivered"))
	if player.stunned:
		await player._stun_timer.timeout
	player.global_position = shelter.global_position
	for frame in range(3):
		await physics_frame
	player.interact()
	await create_timer(0.6).timeout
	ok = _check("scene shelter Call reveals the scripted decoy and relays to calm the guard",
		stage.decoy.visible and stage.is_set(&"guard_calmed") and not stage.lamp.visible) and ok
	player.global_position = delivery.global_position
	for frame in range(3):
		await physics_frame
	player.interact()
	ok = _check("delivery without a permit gets a refusal after the guard calms",
		fired.has(&"z1_permit_needed") and not stage.reward.visible and game.score == 125) and ok
	player.global_position = permit_area.global_position
	for frame in range(3):
		await physics_frame
	player.interact()
	player.interact()
	ok = _check("the placed desk stamps once and acknowledges a repeat interaction",
		stage.permit.visible and stage.is_set(&"permit_stamped")
		and fired.count(&"z1_stamp_permit") == 1 and fired.count(&"z1_permit_repeat") == 1) and ok
	player.global_position = delivery.global_position
	for frame in range(3):
		await physics_frame
	player.interact()
	player.interact()
	await create_timer(0.9).timeout
	ok = _check("delivery reveals Deputy Duck, awards points once, and cues both reactions",
		stage.reward.visible and stage.has_fired(&"z1_delivered") and game.score == 325
		and fired.count(&"z1_receipt") == 1 and fired.count(&"z1_audit") == 1) and ok
	game.clear_stage(false)
	stage = game.stage as Stage01
	(stage.get_node("DeliveryArea") as TriggerArea).interact()
	ok = _check("stage reload restores saved props and leaves local props hidden",
		stage.reward.visible and stage.guard.global_position.is_equal_approx(
			stage.shelter.global_position + Stage01.GUARD_REST_OFFSET)
		and stage.permit.visible and stage.is_set(&"permit_stamped")
		and not stage.decoy.visible and not stage.is_set(&"lamp_on") and game.score == 325) and ok
	game.clear_stage(true)
	stage = game.stage as Stage01
	var pad := stage.get_node("BumpPad") as BumpProp
	player.global_position = pad.global_position
	await create_timer(1.4).timeout
	ok = _check("a fresh run can use the placed bump pad to reveal the scripted treat",
		stage.treat.visible and stage.is_set(&"treat_out") and stage.is_set(&"guard_calmed")
		and not stage.reward.visible and not stage.has_fired(&"z1_delivered")
		and not stage.permit.visible and not stage.is_set(&"permit_stamped") and game.score == 0) and ok
	(stage.get_node("PermitArea") as TriggerArea).interact()
	(stage.get_node("DeliveryArea") as TriggerArea).interact()
	ok = _check("the biscuit route can also deliver the duck",
		stage.reward.visible and stage.has_fired(&"z1_delivered") and game.score == 200) and ok
	return ok

func _check(label: String, condition: bool) -> bool:
	print(("  ok   " if condition else "  FAIL ") + label)
	return condition
