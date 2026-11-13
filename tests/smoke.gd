extends SceneTree
## Short runtime smoke test using the real scene and physics overlap checks.

const STAGE_SCENE_PATH := "res://stages/stage_01/stage_01.tscn"
const GAME_SCENE_PATH := "res://game.tscn"

func _initialize() -> void:
	var packed := load(STAGE_SCENE_PATH) as PackedScene
	var stage := packed.instantiate() as Stage
	root.add_child(stage)
	await process_frame

	var ok := _check("stage loads and validates", stage.check().is_empty())
	ok = (await _test_staging_verbs(stage)) and ok
	var fired: Array[StringName] = []
	stage.rule_fired.connect(func(id: StringName, _event: StringName) -> void: fired.append(id))
	stage.activate()
	stage.activate()
	ok = _check("activating twice starts only one standoff loop", fired.count(&"z1_standoff") == 1) and ok
	stage.fire(&"deliver")
	stage.fire(&"deliver")
	await process_frame

	var delivered_count := 0
	for id in fired:
		if id == &"z1_delivered":
			delivered_count += 1
	ok = _check("deliver fires the eligible rule once",
		delivered_count == 1 and stage.fired.has(&"z1_delivered")) and ok
	ok = _check("deliver guard prevents the caught rule", not fired.has(&"z1_caught")) and ok

	var changes: Array = []
	stage.var_changed.connect(func(key: StringName, value: Variant) -> void:
		changes.append([key, value]))
	stage.write_var(&"guard_calmed", true)
	ok = _check("stage forwards Blackboard writes to gameplay listeners",
		changes == [[&"guard_calmed", true]] and stage.saved_vars[&"guard_calmed"]) and ok
	ok = (await _test_player_and_bump(stage, fired)) and ok
	stage.deactivate()
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
	enter_only.mode = TriggerArea.Mode.ENTER
	var interactions: Array[StringName] = []
	for event in [&"near", &"far"]:
		var rule := Rule.new(event, event)
		rule.steps.append(Step.new(func(_ctx: Dictionary) -> void: interactions.append(event)))
		stage.engine.rules.append(rule)
	for frame in range(3):
		await physics_frame
	ok = _check("all test areas overlap the player",
		player._reach.overlaps_area(nearest) and player._reach.overlaps_area(farther)
		and player._reach.overlaps_area(enter_only)) and ok
	var interact_key := InputEventKey.new()
	interact_key.keycode = KEY_E
	interact_key.pressed = true
	player._unhandled_input(interact_key)
	ok = _check("E interacts only with the nearest eligible area", interactions == [&"near"]) and ok
	interact_key.echo = true
	player._unhandled_input(interact_key)
	ok = _check("interaction ignores held-key repeats", interactions.size() == 1) and ok

	player.stun(1.0)
	var timer := player._stun_timer
	player.stun(5.0)
	player.stun(0.1)
	player.interact()
	ok = _check("overlapping stuns keep the longest remaining duration and block interaction",
		player.stunned and player._stun_timer == timer and timer.time_left == 5.0
		and interactions.size() == 1) and ok
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
	mesh.material_override = Props.mat(Color(0.2, 0.4, 0.8))
	stage.add_child(mesh)
	var material := mesh.material_override as BaseMaterial3D
	var base := material.albedo_color
	var verbs := stage.verbs as StagingVerbs
	var flash_step := verbs.flash(mesh)
	var first_flash: Signal = flash_step.fn.call({})
	await process_frame
	var second_flash: Signal = flash_step.fn.call({})
	await second_flash
	var ok := _check("re-entered flash returns to its original material color",
		material.albedo_color.is_equal_approx(base))
	await verbs.jump(mesh).fn.call({})
	ok = _check("jump restores its original material color and height",
		material.albedo_color.is_equal_approx(base) and is_zero_approx(mesh.position.y)) and ok
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
	var game := packed.instantiate()
	root.add_child(game)
	await process_frame
	var hud := game.get_node("HUD") as GameHud
	game.stage.scored.emit(25)
	await process_frame
	var ok := _check("the game manager updates the HUD after scoring",
		game.score == 25 and hud.hud.text.begins_with("Score: 25"))
	game.queue_free()
	await process_frame
	return ok

func _check(label: String, condition: bool) -> bool:
	print(("  ok   " if condition else "  FAIL ") + label)
	return condition
