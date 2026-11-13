extends SceneTree
## Deterministic validator, router and clock-injection tests.

signal clock_tick

func _initialize() -> void:
	var ok := true
	var legacy_definition := load("res://tests/fixtures/legacy_stage_definition.tres") as StageDefinition
	if legacy_definition:
		legacy_definition._migrate()
		var legacy_stage := legacy_definition.instantiate()
		if legacy_stage:
			legacy_stage.build()
			var legacy_rule := legacy_definition.rules[0] as RuleData
			ok = _check("legacy resource fields and rule keys migrate cleanly",
				legacy_definition.external_calls == PackedStringArray(["arrive", "deliver"])
				and legacy_rule.one_shot
				and legacy_rule.steps[0] is StepData
				and legacy_rule.state_key == &"legacy_rule"
				and legacy_definition.format_version == StageDefinition.CURRENT_FORMAT_VERSION
				and legacy_stage.graph_errors.is_empty() and legacy_stage.check().is_empty()) and ok
			legacy_stage.engine.rules.clear()
			legacy_stage.free()
		else:
			ok = _check("legacy resource fixture builds after migration", false) and ok
	else:
		ok = _check("legacy resource fixture loads and migrates", false) and ok

	var bb := Blackboard.new()
	bb.define(&"lamp_on", &"local", false)
	var undeclared_changes := 0
	bb.changed.connect(func(_key: StringName, _value: Variant) -> void: undeclared_changes += 1)
	bb.write(&"missing", true)
	ok = _check("undeclared Blackboard writes are rejected in every build",
		not bb.local.has(&"missing") and undeclared_changes == 0) and ok

	var cycle_a := Rule.new(&"loop_a", &"relay:a")
	var cycle_step := Step.new()
	cycle_step.emits = &"b"
	cycle_a.steps.append(cycle_step)
	var cycle_b := Rule.new(&"loop_b", &"relay:b")
	cycle_b.emits = &"a"
	var cycle_rules: Array[Rule] = [cycle_a, cycle_b]
	var cycle_problems := RuleValidator.check(
		cycle_rules, bb, [&"relay:a", &"relay:b"], [])
	ok = _check("validator detects relay cycles",
		cycle_problems.any(func(p): return "relay cycle" in p and "'loop_a'" in p and "'loop_b'" in p)) and ok

	var shared_a := Rule.new(&"shared_a", &"alarm")
	var shared_b := Rule.new(&"shared_b", &"alarm")
	var shared_rules: Array[Rule] = [shared_a, shared_b]
	var shared_problems := RuleValidator.check(shared_rules, bb, [&"alarm"], [])
	ok = _check("validator flags potentially overlapping shared triggers",
		shared_problems.any(func(p): return "share trigger 'alarm'" in p)) and ok
	var invalid_one_shot := Rule.new(&"invalid_one_shot", &"alarm")
	invalid_one_shot.one_shot = true
	invalid_one_shot.reentry = Rule.ReentryPolicy.QUEUE
	var incompatible_problems := RuleValidator.check(
		[invalid_one_shot], bb, [&"alarm"], [])
	ok = _check("validator rejects re-entry policies on one-shot rules",
		incompatible_problems.any(func(p): return "one-shot and must use Ignore" in p)) and ok

	var exclusive_a := Rule.new(&"exclusive_a", &"alarm")
	exclusive_a.requires = [&"lamp_on"]
	var exclusive_b := Rule.new(&"exclusive_b", &"alarm")
	exclusive_b.forbids = [&"lamp_on"]
	var exclusive_rules: Array[Rule] = [exclusive_a, exclusive_b]
	var exclusive_problems := RuleValidator.check(
		exclusive_rules, bb, [&"alarm"], [&"lamp_on"])
	ok = _check("validator accepts mutually exclusive shared triggers",
		not exclusive_problems.any(func(p): return "share trigger 'alarm'" in p)) and ok
	shared_b.allow_overlap = true
	var overlap_problems := RuleValidator.check(shared_rules, bb, [&"alarm"], [])
	ok = _check("validator permits explicitly intentional shared-trigger overlap",
		not overlap_problems.any(func(p): return "share trigger 'alarm'" in p)) and ok

	var route_bb := Blackboard.new()
	route_bb.define(&"armed", &"local", false)
	route_bb.define(&"blocked", &"local", false)
	route_bb.define(&"cancelled", &"local", false)
	var router := RuleEngine.new(route_bb, {}, Callable())
	var guarded := Rule.new(&"guarded", &"attempt")
	router.rules.append(guarded)
	guarded.requires = [&"armed"]
	guarded.forbids = [&"blocked"]
	guarded.cancel_if = [&"cancelled"]
	guarded.one_shot = true
	var fired: Array[StringName] = []
	router.rule_fired.connect(func(id: StringName, _event: StringName) -> void: fired.append(id))

	router.fire(&"attempt")
	route_bb.write(&"armed", true)
	route_bb.write(&"blocked", true)
	router.fire(&"attempt")
	route_bb.write(&"blocked", false)
	router.fire(&"attempt")
	router.fire(&"attempt")
	ok = _check("router applies requires, forbids and once guards",
		fired == [&"guarded"] and router.fired.has(&"guarded")) and ok
	ok = _check("router honors cancel_if while a rule is alive", router.alive(guarded, 0)) and ok
	route_bb.write(&"cancelled", true)
	ok = _check("router cancels a rule after cancel_if is set", not router.alive(guarded, 0)) and ok

	var engine_bb := Blackboard.new()
	var wait_requests: Array[float] = []
	var fake_wait := func(seconds: float) -> Signal:
		wait_requests.append(seconds)
		return clock_tick
	var latch_engine := RuleEngine.new(engine_bb, {}, fake_wait)
	engine_bb.define(&"stop_latched", &"local", false)
	var latch_state := {"ran": false}
	var latch_rule := Rule.new(&"latch_on_start", &"latch")
	latch_rule.one_shot = true
	latch_rule.cancel_if = [&"stop_latched"]
	var latch_step := Step.new(func(_ctx: Dictionary) -> void: latch_state["ran"] = true)
	latch_step.delay = 1.0
	latch_rule.steps.append(latch_step)
	latch_engine.rules.append(latch_rule)
	latch_engine.fire(&"latch")
	var latched_at_start := latch_engine.fired.has(&"latch_on_start")
	engine_bb.write(&"stop_latched", true)
	clock_tick.emit()
	await process_frame
	ok = _check("one-shot stays latched when cancelled mid-flight",
		latched_at_start and not latch_state["ran"] and not latch_engine.passes(latch_rule)) and ok

	engine_bb.define(&"lamp_on", &"local", false)
	var light_engine := RuleEngine.new(engine_bb, {}, fake_wait)
	var light_factory := StagingVerbs.new(StepContext.new(engine_bb, light_engine, null, Callable()))
	var light_rule := Rule.new(&"timed_light", &"light")
	light_rule.cancel_if = [&"stop_latched"]
	var light_node := Node3D.new()
	var light_step := light_factory.light(light_node, true, 2.0, &"lamp_on")
	light_rule.steps.append(light_step)
	light_engine.rules.append(light_rule)
	light_engine.fire(&"light")
	var light_started := light_node.visible
	engine_bb.write(&"stop_latched", false)
	engine_bb.write(&"lamp_on", false)
	light_engine.fire(&"light")
	engine_bb.write(&"stop_latched", true)
	clock_tick.emit()
	await process_frame
	ok = _check("cancelled timed light cannot apply its delayed off change",
		light_started and light_node.visible) and ok
	light_node.free()
	wait_requests.clear()
	var state := {"step_ran": false}
	var engine := RuleEngine.new(engine_bb, {}, fake_wait)
	var delayed := Rule.new(&"delayed", &"go")
	var delayed_step := Step.new(func(_ctx: Dictionary) -> void: state["step_ran"] = true)
	delayed_step.delay = 12.5
	delayed.steps.append(delayed_step)
	engine.rules.append(delayed)
	engine.fire(&"go")
	var delay_was_injected: bool = wait_requests == [12.5] and not state["step_ran"]
	clock_tick.emit()
	ok = _check("RuleEngine delay uses injected, non-realtime wait",
		delay_was_injected and state["step_ran"]) and ok

	# A relay step receives its own rule and the original event payload.
	var repeated := Rule.new(&"repeated", &"start")
	repeated.cancel_if = [&"stop"]
	engine_bb.define(&"stop", &"local", false)
	var factory := CoreVerbs.new(StepContext.new(engine_bb, engine, null, Callable()))
	repeated.steps.append(factory.repeat_emit(2.0, &"tick"))
	var listener := Rule.new(&"listener", &"relay:tick")
	var received: Array[StringName] = []
	listener.steps.append(Step.new(func(c: Dictionary) -> void:
		received.append(c["_rule"].id)
		received.append(c["item"])
	))
	engine.rules.append_array([repeated, listener])
	engine.fire(&"start", {"item": &"parcel"})
	engine.fire(&"start", {"item": &"duplicate"})
	ok = _check("repeat waits on the same injected clock as delays",
		wait_requests == [12.5, 2.0] and received.is_empty()) and ok
	clock_tick.emit()
	ok = _check("repeat relays supply the listener's rule and preserve event payload",
		received == [&"listener", &"parcel"]) and ok
	engine_bb.write(&"stop", true)
	clock_tick.emit()
	ok = _check("repeat stops at the next tick when cancel_if becomes true",
		received.size() == 2) and ok

	state["step_ran"] = false
	engine.fire(&"go")
	engine.cancel_all()
	clock_tick.emit()
	ok = _check("deactivation cancels an outstanding delay", not state["step_ran"]) and ok

	ok = _test_restart() and ok
	ok = _test_queue() and ok
	ok = _test_retriggered_light() and ok
	print("UNIT: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)

func _test_retriggered_light() -> bool:
	var bb := Blackboard.new()
	bb.define(&"lamp_on", &"local", false)
	var timers: Array[SceneTreeTimer] = []
	var engine := RuleEngine.new(bb, {}, func(seconds: float) -> Signal:
		var timer := create_timer(seconds)
		timers.append(timer)
		return timer.timeout)
	var verbs := StagingVerbs.new(StepContext.new(bb, engine, null, Callable()))
	var lamp := Node3D.new()
	var rule := Rule.new(&"timed_light", &"light")
	rule.reentry = Rule.ReentryPolicy.RESTART
	rule.steps.append(verbs.light(lamp, true, 1.0))
	engine.rules.append(rule)
	engine.fire(&"light")
	engine.fire(&"light")
	var ok := _check("each light activation schedules a timeout", timers.size() == 2)
	if ok:
		timers[0].timeout.emit()
		ok = _check("an older timeout leaves the latest light activation on",
			lamp.visible and bb.is_set(&"lamp_on")) and ok
		timers[1].timeout.emit()
		ok = _check("the latest timeout switches the light and Blackboard key off",
			not lamp.visible and not bb.is_set(&"lamp_on")) and ok
	lamp.free()
	return ok

func _test_restart() -> bool:
	var bb := Blackboard.new()
	bb.define(&"stop", &"local", false)
	var engine := RuleEngine.new(bb, {}, func(_seconds: float) -> Signal: return clock_tick)
	var factory := CoreVerbs.new(StepContext.new(bb, engine, null, Callable()))
	var repeated := Rule.new(&"repeated", &"start")
	repeated.reentry = Rule.ReentryPolicy.RESTART
	repeated.cancel_if = [&"stop"]
	var starts: Array[int] = []
	repeated.steps.append(Step.new(func(c: Dictionary) -> void: starts.append(c["id"])))
	repeated.steps.append(factory.repeat_emit(1.0, &"tick"))
	var listener := Rule.new(&"listener", &"relay:tick")
	var ticks: Array[int] = []
	listener.steps.append(Step.new(func(c: Dictionary) -> void: ticks.append(c["id"])))
	engine.rules.append_array([repeated, listener])

	engine.fire(&"start", {"id": 1})
	engine.fire(&"start", {"id": 2})
	engine.fire(&"start", {"id": 3})
	var ok := _check("restart waits for the running step's cancellation check", starts == [1])
	clock_tick.emit()
	ok = _check("restart uses the latest payload and suppresses the old tick",
		starts == [1, 3] and ticks.is_empty()) and ok
	clock_tick.emit()
	ok = _check("only the replacement repeat emits", ticks == [3]) and ok
	bb.write(&"stop", true)
	clock_tick.emit()
	return ok

func _test_queue() -> bool:
	var bb := Blackboard.new()
	bb.define(&"enabled", &"local", true)
	var engine := RuleEngine.new(bb, {}, func(_seconds: float) -> Signal: return clock_tick)
	var queued := Rule.new(&"queued", &"start")
	queued.reentry = Rule.ReentryPolicy.QUEUE
	queued.requires = [&"enabled"]
	var received: Array[int] = []
	queued.steps.append(Step.new(func(c: Dictionary) -> void: received.append(c["id"])).after(1.0))
	engine.rules.append(queued)

	engine.fire(&"start", {"id": 1})
	var payload := {"id": 2}
	engine.fire(&"start", payload)
	payload["id"] = 99
	engine.fire(&"start", {"id": 3})
	clock_tick.emit()
	var ok := _check("queued triggers wait for the active run", received == [1])
	clock_tick.emit()
	ok = _check("queue keeps the original payload and trigger order", received == [1, 2]) and ok
	clock_tick.emit()
	ok = _check("the queue drains in order", received == [1, 2, 3]) and ok

	engine.fire(&"start", {"id": 4})
	engine.fire(&"start", {"id": 5})
	bb.write(&"enabled", false)
	clock_tick.emit()
	clock_tick.emit()
	ok = _check("queued triggers recheck fire-time guards", received == [1, 2, 3, 4]) and ok

	bb.write(&"enabled", true)
	engine.fire(&"start", {"id": 6})
	engine.fire(&"start", {"id": 7})
	engine.cancel_all()
	engine.fire(&"start", {"id": 8})
	engine.fire(&"start", {"id": 9})
	clock_tick.emit()
	clock_tick.emit()
	return _check("deactivation drops pending triggers and leaves later runs intact",
		received == [1, 2, 3, 4, 8, 9]) and ok

func _check(label: String, condition: bool) -> bool:
	print(("  ok   " if condition else "  FAIL ") + label)
	return condition
