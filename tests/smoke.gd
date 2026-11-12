extends SceneTree
## Short runtime smoke test using the real scene and physics overlap checks.

const ZONE_SCENE_PATH := "res://zones/zone_01/zone_01.tscn"
const GAME_SCENE_PATH := "res://game.tscn"

func _initialize() -> void:
	var packed := load(ZONE_SCENE_PATH) as PackedScene
	var zone := packed.instantiate() as Zone
	root.add_child(zone)
	await process_frame

	var ok := _check("zone loads and validates", zone.validate().is_empty())
	zone.activate() # leaves a repeating relay pending during unload
	var fired: Array[StringName] = []
	zone.rule_fired.connect(func(id: StringName, _event: StringName) -> void: fired.append(id))
	zone.fire(&"deliver")
	zone.fire(&"deliver")
	await process_frame

	var delivered_count := 0
	for id in fired:
		if id == &"z1_delivered":
			delivered_count += 1
	ok = _check("deliver fires the eligible rule once",
		delivered_count == 1 and zone.fired.has(&"z1_delivered")) and ok
	ok = _check("deliver guard prevents the caught rule", not fired.has(&"z1_caught")) and ok

	var changes: Array = []
	zone.var_changed.connect(func(key: StringName, value: Variant) -> void:
		changes.append([key, value]))
	zone.write_var(&"guard_calmed", true)
	ok = _check("zone forwards Blackboard writes to gameplay listeners",
		changes == [[&"guard_calmed", true]] and zone.saved_vars[&"guard_calmed"]) and ok
	ok = (await _test_player_and_bump(zone, fired)) and ok
	zone.deactivate()
	zone.queue_free()
	await process_frame
	ok = (await _test_game_scene()) and ok
	print("SMOKE: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)

func _test_player_and_bump(zone: Zone, fired: Array[StringName]) -> bool:
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
	var nearest := Props.trigger_box(zone, Vector3.ONE, Vector3(0.5, 1, 4), &"near")
	var farther := Props.trigger_box(zone, Vector3.ONE, Vector3(1, 1, 4), &"far")
	var enter_only := Props.trigger_box(zone, Vector3.ONE, Vector3(0, 1, 4), &"enter_only")
	enter_only.mode = TriggerArea.Mode.ENTER
	var interactions: Array[StringName] = []
	for event in [&"near", &"far"]:
		var rule := zone.rule(event, event)
		rule.steps.append(Step.new(func(_ctx: Dictionary) -> void: interactions.append(event)))
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

	var pad := zone.get_node("BumpPad") as BumpProp
	pad.bump_area.body_entered.emit(player)
	pad.bump_area.body_entered.emit(player)
	ok = _check("bumping twice latches the key and dispatches the relay once",
		zone.is_set(&"treat_out") and fired.count(&"z1_treat") == 1
		and fired.count(&"bump_prop") == 1) and ok
	player.queue_free()
	return ok

func _test_game_scene() -> bool:
	var packed := load(GAME_SCENE_PATH) as PackedScene
	if not _check("the main scene loads", packed != null):
		return false
	var game := packed.instantiate()
	root.add_child(game)
	await process_frame
	var hud := game.get_node("HUD") as GameHud
	game.zone.scored.emit(25)
	await process_frame
	var ok := _check("the game manager updates the HUD after scoring",
		game.score == 25 and hud.hud.text.begins_with("Score: 25"))
	game.queue_free()
	await process_frame
	return ok

func _check(label: String, condition: bool) -> bool:
	print(("  ok   " if condition else "  FAIL ") + label)
	return condition
