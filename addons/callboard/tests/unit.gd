extends SceneTree
## Deterministic validator, router and clock-injection tests.

signal clock_tick

func _initialize() -> void:
	var ok := true
	var legacy_definition := load("res://addons/callboard/tests/fixtures/legacy_stage_definition.tres") as StageDefinition
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
	var undeclared_changes := [0]
	bb.changed.connect(func(_key: StringName, _value: Variant) -> void: undeclared_changes[0] += 1)
	bb.write(&"missing", true)
	ok = _check("undeclared Blackboard writes are rejected in every build",
		not bb.local.has(&"missing") and undeclared_changes[0] == 0) and ok
	var speed_changes: Array = []
	bb.changed.connect(func(key: StringName, value: Variant) -> void:
		if key == &"speed":
			speed_changes.append(value))
	bb.define(&"speed", &"saved", 0.0)
	bb.write(&"speed", 1)
	bb.write(&"speed", 1.0)
	ok = _check("integer writes to float Blackboard keys store and emit a float",
		typeof(bb.saved[&"speed"]) == TYPE_FLOAT and bb.saved[&"speed"] == 1.0
		and speed_changes.size() == 1 and typeof(speed_changes[0]) == TYPE_FLOAT) and ok

	var counter_saved := {&"counter": 4}
	var counter_bb := Blackboard.new(counter_saved)
	counter_bb.define(&"counter", &"saved", 0)
	counter_bb.define(&"fractional", &"local", 1.5)
	counter_bb.define(&"enabled", &"local", false)
	var counter_factory := CoreVerbs.new(StepContext.new(counter_bb, null, null, Callable()))
	var decrement := counter_factory.add_var(&"counter", -1.0)
	var observed_counters: Array[int] = []
	var observe_step := Step.new(func(_context: Dictionary) -> void:
		observed_counters.append(counter_bb.get_var(&"counter")))
	var counter_rule := Rule.new(&"counter_update", &"increment")
	decrement.verb = &"add_var"
	decrement.args = [&"counter", -1.0]
	counter_rule.steps.append_array([decrement, observe_step])
	var counter_engine := RuleEngine.new(counter_bb, {}, Callable())
	counter_engine.rules.append(counter_rule)
	counter_engine.fire(&"increment")
	await process_frame
	counter_engine.fire(&"increment")
	await process_frame
	ok = _check("add_var applies negative deltas at execution and later steps read the updated counter",
		observed_counters == [3, 2] and counter_saved[&"counter"] == 2
		and decrement.reads == [&"counter"] and decrement.sets == [&"counter"]) and ok
	var restored_counter_bb := Blackboard.new(counter_saved)
	restored_counter_bb.define(&"counter", &"saved", 0)
	var restored_step := CoreVerbs.new(StepContext.new(restored_counter_bb, null, null, Callable())).add_var(&"counter", 3.0)
	restored_step.fn.call({})
	ok = _check("add_var resumes from the restored saved counter and preserves its integer type",
		restored_counter_bb.get_var(&"counter") == 5 and typeof(counter_saved[&"counter"]) == TYPE_INT
		and typeof(restored_counter_bb.get_var(&"counter")) == TYPE_INT) and ok
	var float_update := counter_factory.add_var(&"fractional", -0.25)
	float_update.fn.call({})
	ok = _check("add_var preserves float values and accepts fractional negative deltas",
		counter_bb.get_var(&"fractional") == 1.25
		and typeof(counter_bb.get_var(&"fractional")) == TYPE_FLOAT) and ok
	var bad_add := counter_factory.add_var(&"counter", 0.5)
	bad_add.verb = &"add_var"
	bad_add.args = [&"counter", 0.5]
	var numeric_rule := Rule.new(&"numeric_check", &"increment")
	numeric_rule.steps.append(bad_add)
	var numeric_problems := RuleValidator.check([numeric_rule], counter_bb, [&"increment"], [])
	ok = _check("validator flags fractional deltas for integer Blackboard keys",
		numeric_problems.any(func(problem: String) -> bool: return "whole number" in problem)) and ok
	var invalid_target := counter_factory.add_var(&"enabled", 1.0)
	invalid_target.verb = &"add_var"
	invalid_target.args = [&"enabled", 1.0]
	numeric_rule.steps = [invalid_target]
	numeric_problems = RuleValidator.check([numeric_rule], counter_bb, [&"increment"], [])
	ok = _check("validator requires add_var targets to be numeric Blackboard keys",
		numeric_problems.any(func(problem: String) -> bool: return "must be int or float" in problem)) and ok
	var compiled_saved := {&"counter": 6}
	var compiled_stage := Stage.new()
	compiled_stage.saved_vars = compiled_saved
	compiled_stage.build()
	compiled_stage.define_saved(&"counter", 0)
	var compile_definition := StageDefinition.new()
	var compile_rule := RuleData.new()
	compile_rule.id = &"compiled_increment"
	compile_rule.trigger = &"increment"
	var compile_step := StepData.new()
	compile_step.verb = &"add_var"
	compile_step.args = PackedStringArray(['&"counter"', "2.0"])
	compile_rule.steps.append(compile_step)
	compile_definition.rules = [compile_rule]
	var compile_problems := compile_definition.apply_graph(compiled_stage)
	if compile_problems.is_empty():
		compiled_stage.engine.rules[0].steps[0].fn.call({})
	ok = _check("add_var compiles from authored step data and uses the restored Blackboard value",
		compile_problems.is_empty() and compiled_saved[&"counter"] == 8) and ok
	compiled_stage.free()

	var relay_stage := Stage.new()
	relay_stage.build()
	relay_stage.define_local(&"wrong_latch_type", 0)
	var relay_emitted: Array[StringName] = []
	relay_stage.rule_fired.connect(func(id: StringName, _event: StringName) -> void: relay_emitted.append(id))
	ok = _check("a relay latch requires a Boolean Blackboard key",
		not relay_stage.fire_relay_once(&"ready", &"wrong_latch_type", &"source", &"interact")
		and relay_emitted.is_empty() and relay_stage.get_var(&"wrong_latch_type") == 0) and ok
	relay_stage.free()

	bb.alias(&"previous_lamp_name", &"lamp_on")
	var alias_rule := Rule.new(&"alias_writer", &"alarm")
	alias_rule.requires = [&"lamp_on"]
	alias_rule.steps.append(CoreVerbs.new(StepContext.new(bb, null, null, Callable())).set_var(&"previous_lamp_name"))
	ok = _check("validator resolves renamed Blackboard keys in step writes",
		RuleValidator.check([alias_rule], bb, [&"alarm"], []).is_empty()) and ok

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

	var payload_schema := {&"route": {&"action": TYPE_STRING, &"count": TYPE_INT, &"accepted": TYPE_BOOL}}
	var schema_definition := StageDefinition.new()
	schema_definition.external_calls = PackedStringArray(["route"])
	var declared_action := PayloadFieldData.new()
	declared_action.event_id = &"route"
	declared_action.key = &"action"
	declared_action.type_name = "String"
	schema_definition.payload_fields.append(declared_action)
	var schema_stage := Stage.new()
	schema_stage.definition = schema_definition
	schema_stage.build()
	ok = _check("StageDefinition payload fields compile into a trigger-specific runtime schema",
		schema_stage.payload_schema.get(&"route", {}).get(&"action", TYPE_NIL) == TYPE_STRING
		and schema_stage.engine.payload_schema == schema_stage.payload_schema) and ok
	schema_stage.free()
	var confirm_payload := {"action": "confirm", "count": 3, "accepted": true}
	ok = _check("payload parser separates authored fields from Blackboard keys",
		GuardExpression.referenced_payload_field(&"payload.action == \"confirm\"") == &"action"
		and GuardExpression.referenced_key(&"payload.action == \"confirm\"").is_empty()
		and GuardExpression.referenced_key(&"armed") == &"armed") and ok
	ok = _check("payload guards compare strings, booleans, and numbers by declared type",
		GuardExpression.evaluate(route_bb, &"payload.action == \"confirm\"", confirm_payload, &"route", payload_schema)
		and GuardExpression.evaluate(route_bb, &"payload.accepted != false", confirm_payload, &"route", payload_schema)
		and GuardExpression.evaluate(route_bb, &"payload.count >= 3", confirm_payload, &"route", payload_schema)) and ok
	ok = _check("missing and incompatible payload values fail both equality and inequality",
		not GuardExpression.evaluate(route_bb, &"payload.action != \"confirm\"", {}, &"route", payload_schema)
		and not GuardExpression.evaluate(route_bb, &"payload.count != 3", {"count": "3"}, &"route", payload_schema)
		and not GuardExpression.evaluate(route_bb, &"payload.accepted == true", {"accepted": 1}, &"route", payload_schema)) and ok
	ok = _check("payload presence checks explicitly distinguish present and missing fields",
		GuardExpression.evaluate(route_bb, &"has(payload.action)", confirm_payload, &"route", payload_schema)
		and GuardExpression.evaluate(route_bb, &"missing(payload.absent)", confirm_payload, &"route", payload_schema)
		and not GuardExpression.evaluate(route_bb, &"has(payload.absent)", confirm_payload, &"route", payload_schema)) and ok
	var payload_guard_rule := Rule.new(&"payload_guard", &"route")
	payload_guard_rule.requires = [&"payload.action == \"confirm\""]
	payload_guard_rule.steps.append(Step.new(func(_context: Dictionary) -> void: pass))
	var payload_guard_diagnostics := RuleValidator.check([payload_guard_rule], route_bb, [&"route"], [], payload_schema)
	ok = _check("validator treats payload references separately and checks declared field types",
		not payload_guard_diagnostics.any(func(problem: String) -> bool: return "Blackboard" in problem)
		and payload_guard_diagnostics.is_empty()) and ok
	payload_guard_rule.requires = [&"payload.count == \"three\""]
	payload_guard_diagnostics = RuleValidator.check([payload_guard_rule], route_bb, [&"route"], [], payload_schema)
	ok = _check("validator reports payload field and operand type mismatches",
		payload_guard_diagnostics.any(func(problem: String) -> bool: return "incompatible literal or operator" in problem)) and ok

	var payload_engine := RuleEngine.new(Blackboard.new(), {}, Callable())
	payload_engine.payload_schema = payload_schema
	var confirmations: Array[String] = []
	for route_pair in [["confirm", "confirm"], ["decline", "decline"]]:
		var route_name: String = route_pair[0]
		var expected_action: String = route_pair[1]
		var route_rule := Rule.new(StringName("route_" + route_name), &"route")
		route_rule.requires = [StringName('payload.action == "%s"' % expected_action)]
		route_rule.steps.append(Step.new(func(c: Dictionary) -> void: confirmations.append(c["payload"]["action"])))
		payload_engine.rules.append(route_rule)
	payload_engine.fire(&"route", {"action": "confirm"})
	payload_engine.fire(&"route", {"action": "decline"})
	ok = _check("one Call routes distinct payload values to different rules",
		confirmations == ["confirm", "decline"]) and ok

	var forwarded: Array[String] = []
	var source_rule := Rule.new(&"payload_source", &"route")
	source_rule.requires = [&"payload.action == \"confirm\""]
	source_rule.emits = &"payload_forwarded"
	var relay_rule := Rule.new(&"payload_relay_listener", &"relay:payload_forwarded")
	relay_rule.requires = [&"payload.action == \"confirm\""]
	relay_rule.steps.append(Step.new(func(c: Dictionary) -> void: forwarded.append(c["action"])))
	payload_engine.rules.append_array([source_rule, relay_rule])
	payload_engine.fire(&"route", {"action": "confirm"})
	ok = _check("completion relays preserve authored payload fields for listener guards and steps",
		forwarded == ["confirm"]) and ok

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
	var light_timer := create_timer(2.0)
	var light_engine := RuleEngine.new(engine_bb, {}, func(seconds: float) -> Signal:
		return light_timer.timeout if seconds == 2.0 else clock_tick)
	var light_factory := StagingVerbs.new(StepContext.new(engine_bb, light_engine, null, Callable()))
	var light_rule := Rule.new(&"timed_light", &"light")
	light_rule.cancel_if = [&"stop_latched"]
	var light_node := Node3D.new()
	light_node.hide()
	var light_step := light_factory._light(light_node, true, 2.0, &"lamp_on")
	light_rule.steps.append(light_step)
	light_rule.steps.append(Step.new(func(_ctx: Dictionary) -> void: pass).after(1.0))
	light_engine.rules.append(light_rule)
	engine_bb.write(&"stop_latched", false)
	light_engine.fire(&"light")
	var light_started := light_node.visible and engine_bb.is_set(&"lamp_on")
	engine_bb.write(&"stop_latched", true)
	clock_tick.emit()
	ok = _check("rule cancellation switches the light and Blackboard key off before timeout",
		light_started and not light_node.visible and not engine_bb.is_set(&"lamp_on")) and ok
	light_timer.timeout.emit()
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
		received.append(c["_callboard"]["rule"].id)
		received.append(c["payload"]["item"])
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
	ok = _check("deactivation releases a delayed rule before the clock ticks",
		engine._awaited_signals.is_empty() and clock_tick.get_connections().is_empty()) and ok
	clock_tick.emit()
	ok = _check("deactivation cancels an outstanding delay", not state["step_ran"]) and ok

	ok = _test_restart() and ok
	ok = _test_queue() and ok
	ok = _test_retriggered_light() and ok
	ok = _test_light_from_restarted_run() and ok
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
	rule.steps.append(verbs._light(lamp, true, 1.0, &"lamp_on"))
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

func _test_light_from_restarted_run() -> bool:
	var bb := Blackboard.new()
	bb.define(&"lamp_on", &"local", false)
	var light_timer := create_timer(10.0)
	var engine := RuleEngine.new(bb, {}, func(seconds: float) -> Signal:
		return light_timer.timeout if seconds == 10.0 else clock_tick)
	var verbs := StagingVerbs.new(StepContext.new(bb, engine, null, Callable()))
	var lamp := Node3D.new()
	var light_step := verbs._light(lamp, true, 10.0, &"lamp_on")
	var rule := Rule.new(&"timed_light", &"light")
	rule.reentry = Rule.ReentryPolicy.RESTART
	var starts: Array[bool] = []
	rule.steps.append(Step.new(func(ctx: Dictionary) -> void:
		starts.append(ctx["turn_on"])
		if ctx["turn_on"]:
			light_step.fn.call(ctx)))
	rule.steps.append(Step.new(func(_ctx: Dictionary) -> void: pass).after(1.0))
	engine.rules.append(rule)
	engine.fire(&"light", {"turn_on": true})
	var light_started := lamp.visible and bb.is_set(&"lamp_on")
	engine.fire(&"light", {"turn_on": false})
	clock_tick.emit()
	var ok := _check("restarting a rule turns off its timed light before the replacement skips light",
		light_started and starts == [true, false] and not lamp.visible and not bb.is_set(&"lamp_on"))
	var lamp_writes: Array[bool] = []
	bb.changed.connect(func(key: StringName, value: Variant) -> void:
		if key == &"lamp_on":
			lamp_writes.append(value))
	light_timer.timeout.emit()
	ok = _check("the cancelled run's timeout does not write the light key again",
		lamp_writes.is_empty()) and ok
	clock_tick.emit()
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

	var payload_engine := RuleEngine.new(Blackboard.new(), {}, func(_seconds: float) -> Signal: return clock_tick)
	payload_engine.payload_schema = {&"start": {&"stop": TYPE_BOOL}}
	var payload_queue := Rule.new(&"payload_queue", &"start")
	payload_queue.reentry = Rule.ReentryPolicy.QUEUE
	payload_queue.requires = [&"has(payload.stop)"]
	payload_queue.cancel_if = [&"payload.stop == true"]
	var payload_runs: Array[bool] = []
	payload_queue.steps.append(Step.new(func(c: Dictionary) -> void: payload_runs.append(c["stop"])).after(1.0))
	payload_engine.rules.append(payload_queue)
	payload_engine.fire(&"start", {"stop": false})
	payload_engine.fire(&"start", {"stop": true})
	clock_tick.emit()
	ok = _check("queued run cancellation uses that queued event's payload", payload_runs == [false]) and ok

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
