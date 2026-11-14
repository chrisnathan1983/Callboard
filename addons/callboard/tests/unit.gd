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
	var scene_writer := BlackboardWriterData.new()
	scene_writer.key = &"lamp_on"
	scene_writer.source = &"yard_sensor"
	scene_writer.value_type = "bool"
	var externally_guarded := Rule.new(&"external_guard", &"sensor_changed")
	externally_guarded.requires = [&"lamp_on"]
	externally_guarded.steps.append(Step.new(func(_context: Dictionary) -> void: pass))
	var external_writer_problems := RuleValidator.check(
		[externally_guarded], bb, [&"sensor_changed"], [], {}, [scene_writer])
	ok = _check("declared external Blackboard writers satisfy guard producer analysis",
		not external_writer_problems.any(func(problem: String) -> bool: return "nothing sets it" in problem)) and ok
	var wrong_writer := scene_writer.duplicate_data()
	wrong_writer.value_type = "String"
	external_writer_problems = RuleValidator.check(
		[externally_guarded], bb, [&"sensor_changed"], [], {}, [wrong_writer])
	ok = _check("external Blackboard writer declarations report incompatible output types",
		external_writer_problems.any(func(problem: String) -> bool: return "outputs String" in problem)) and ok
	var missing_writer := scene_writer.duplicate_data()
	missing_writer.key = &"missing_output"
	external_writer_problems = RuleValidator.check(
		[externally_guarded], bb, [&"sensor_changed"], [], {}, [missing_writer])
	ok = _check("external Blackboard writer declarations reject undeclared keys",
		external_writer_problems.any(func(problem: String) -> bool: return "not declared on the Blackboard" in problem)) and ok
	bb.write(&"lamp_on", true, &"yard_sensor")
	ok = _check("Blackboard retains the source label of the latest accepted write",
		bb.last_writers.get(&"lamp_on") == &"yard_sensor") and ok
	var writer_definition := StageDefinition.new()
	writer_definition.external_calls = PackedStringArray(["sensor_changed"])
	var sensor_value := VariableData.new()
	sensor_value.key = &"sensor_active"
	sensor_value.default_value = false
	var output_value := VariableData.new()
	output_value.key = &"lamp_on"
	output_value.default_value = false
	writer_definition.variables = [sensor_value, output_value]
	var external_rule_data := RuleData.new()
	external_rule_data.id = &"sensor_guard"
	external_rule_data.trigger = &"sensor_changed"
	external_rule_data.requires = PackedStringArray(["sensor_active"])
	var external_rule_step := StepData.new()
	external_rule_step.verb = &"set_var"
	external_rule_step.args = PackedStringArray(['&"lamp_on"', "true"])
	external_rule_data.steps.append(external_rule_step)
	writer_definition.rules = [external_rule_data]
	var scene_output := BlackboardWriterData.new()
	scene_output.key = &"sensor_active"
	scene_output.value_type = "bool"
	var writer_component := BlackboardWriter.new()
	writer_component.name = "yard_sensor"
	writer_component.callboard_writers.append(scene_output)
	var writer_stage := Stage.new()
	writer_stage.definition = writer_definition
	writer_stage.add_child(writer_component)
	root.add_child(writer_stage)
	writer_stage.build()
	var stage_writer_diagnostics := writer_stage.check()
	writer_component.publish(&"sensor_active", true)
	ok = _check("scene BlackboardWriter declarations feed editor/runtime guard validation and publish typed values",
		writer_stage.external_writers.size() == 1
		and not stage_writer_diagnostics.any(func(problem: String) -> bool: return "nothing sets it" in problem)
		and writer_stage.get_var(&"sensor_active") and writer_stage.bb.last_writers.get(&"sensor_active") == &"yard_sensor") and ok
	root.remove_child(writer_stage)
	writer_stage.free()
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
	relay_stage.define_saved(&"sensor_latched", false)
	relay_stage.register_external_writer(&"sensor_latched", &"yard_sensor", "bool")
	var relay_emitted: Array[StringName] = []
	relay_stage.rule_fired.connect(func(id: StringName, _event: StringName) -> void: relay_emitted.append(id))
	ok = _check("a relay latch requires a Boolean Blackboard key",
		not relay_stage.fire_relay_once(&"ready", &"wrong_latch_type", &"source", &"interact")
		and relay_emitted.is_empty() and relay_stage.get_var(&"wrong_latch_type") == 0) and ok
	ok = _check("external relay latch writes retain their gameplay source",
		relay_stage.fire_relay_once(&"ready", &"sensor_latched", &"yard_sensor", &"sensor_changed")
		and relay_stage.bb.last_writers.get(&"sensor_latched") == &"yard_sensor") and ok
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
	ok = await _test_managed_stages_and_restoration() and ok
	print("UNIT: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)

func _test_managed_stages_and_restoration() -> bool:
	var definition := StageDefinition.new()
	definition.managed_lifecycle = true
	definition.external_calls = PackedStringArray(["arrive", "give:robot", "give:skateboard"])
	for variable_spec in [
		[&"delivered_robot", "saved", false],
		[&"delivered_skateboard", "saved", false],
		[&"gifts_delivered", "saved", 0],
		[&"arrival_count", "saved", 0],
		[&"town_bell", "shared", false],
		[&"garage_door_transform", "saved", Transform3D.IDENTITY],
	]:
		var variable := VariableData.new()
		variable.key = variable_spec[0]
		variable.scope = variable_spec[1]
		variable.default_value = variable_spec[2]
		definition.variables.append(variable)
	var arrival_rule := RuleData.new()
	arrival_rule.id = &"arrival_once"
	arrival_rule.trigger = &"arrive"
	arrival_rule.one_shot = true
	var arrival_step := StepData.new()
	arrival_step.verb = &"add_var"
	arrival_step.args = PackedStringArray(['&"arrival_count"', "1.0"])
	arrival_rule.steps.append(arrival_step)
	var gift_rule := RuleData.new()
	gift_rule.id = &"deliver_robot"
	gift_rule.trigger = &"give:robot"
	gift_rule.forbids = PackedStringArray(["delivered_robot"])
	var set_delivered := StepData.new()
	set_delivered.verb = &"set_var"
	set_delivered.args = PackedStringArray(['&"delivered_robot"', "true"])
	var count_delivery := StepData.new()
	count_delivery.verb = &"add_var"
	count_delivery.args = PackedStringArray(['&"gifts_delivered"', "1.0"])
	gift_rule.steps.assign([set_delivered, count_delivery])
	var skateboard_rule := RuleData.new()
	skateboard_rule.id = &"deliver_skateboard"
	skateboard_rule.trigger = &"give:skateboard"
	skateboard_rule.forbids = PackedStringArray(["delivered_skateboard"])
	var set_skateboard := StepData.new()
	set_skateboard.verb = &"set_var"
	set_skateboard.args = PackedStringArray(['&"delivered_skateboard"', "true"])
	var count_skateboard := StepData.new()
	count_skateboard.verb = &"add_var"
	count_skateboard.args = PackedStringArray(['&"gifts_delivered"', "1.0"])
	skateboard_rule.steps.assign([set_skateboard, count_skateboard])
	definition.rules.assign([arrival_rule, gift_rule, skateboard_rule])

	var binding_window := StageRestorationBinding.new()
	binding_window.key = &"delivered_robot"
	binding_window.kind = StageRestorationBinding.Kind.VISIBILITY
	binding_window.target_path = NodePath("BedroomWindowRobot")
	var binding_skateboard_window := StageRestorationBinding.new()
	binding_skateboard_window.key = &"delivered_skateboard"
	binding_skateboard_window.kind = StageRestorationBinding.Kind.VISIBILITY
	binding_skateboard_window.target_path = NodePath("BedroomWindowSkateboard")
	var binding_pose := StageRestorationBinding.new()
	binding_pose.key = &"delivered_robot"
	binding_pose.kind = StageRestorationBinding.Kind.SNAP_TO_MARKER
	binding_pose.target_path = NodePath("Buster")
	binding_pose.marker_path = NodePath("RedDoghouse")
	binding_pose.animation_player_path = NodePath("Buster/AnimationPlayer")
	binding_pose.animation_name = &"sleep"
	binding_pose.animation_time = 5.0
	var binding_door := StageRestorationBinding.new()
	binding_door.key = &"garage_door_transform"
	binding_door.kind = StageRestorationBinding.Kind.TRANSFORM
	binding_door.target_path = NodePath("GarageDoor")
	definition.restoration_bindings.assign([binding_window, binding_skateboard_window, binding_pose, binding_door])

	var template := Stage.new()
	template.name = "Stage"
	template.definition = definition
	var window := Node3D.new()
	window.name = "BedroomWindowRobot"
	template.add_child(window)
	window.owner = template
	var skateboard_window := Node3D.new()
	skateboard_window.name = "BedroomWindowSkateboard"
	template.add_child(skateboard_window)
	skateboard_window.owner = template
	var garage_door := Node3D.new()
	garage_door.name = "GarageDoor"
	template.add_child(garage_door)
	garage_door.owner = template
	var doghouse := Marker3D.new()
	doghouse.name = "RedDoghouse"
	doghouse.position = Vector3(3, 0, 2)
	template.add_child(doghouse)
	doghouse.owner = template
	var buster := Node3D.new()
	buster.name = "Buster"
	template.add_child(buster)
	buster.owner = template
	var visual := Node3D.new()
	visual.name = "Visual"
	buster.add_child(visual)
	visual.owner = template
	var animation_player := AnimationPlayer.new()
	animation_player.name = "AnimationPlayer"
	buster.add_child(animation_player)
	animation_player.owner = template
	var library := AnimationLibrary.new()
	var sleep_animation := Animation.new()
	sleep_animation.length = 10.0
	var sleep_track := sleep_animation.add_track(Animation.TYPE_VALUE)
	sleep_animation.track_set_path(sleep_track, NodePath("Visual:position"))
	sleep_animation.track_insert_key(sleep_track, 0.0, Vector3.ZERO)
	sleep_animation.track_insert_key(sleep_track, 10.0, Vector3(0, 0.25, 0))
	library.add_animation(&"sleep", sleep_animation)
	animation_player.add_animation_library(&"", library)
	var gift := TriggerArea.new()
	gift.name = "RobotGiftTarget"
	gift.mode = TriggerArea.Mode.INTERACT
	gift.event = &"give:robot"
	template.add_child(gift)
	gift.owner = template
	var skateboard_gift := TriggerArea.new()
	skateboard_gift.name = "SkateboardGiftTarget"
	skateboard_gift.mode = TriggerArea.Mode.INTERACT
	skateboard_gift.event = &"give:skateboard"
	template.add_child(skateboard_gift)
	skateboard_gift.owner = template
	var scene := PackedScene.new()
	var packed_ok := scene.pack(template) == OK
	template.free()
	if not _check("managed stage fixture packs with saved gift restoration bindings", packed_ok):
		return false

	var store := StageStateStore.new()
	var stage := store.load_stage(scene, &"house_01_left", root)
	await process_frame
	if stage == null:
		return _check("state store loads a managed Stage", false)
	var ok := _check("restoration bindings validate against authored keys and scene nodes",
		stage.check().is_empty())
	var invalid_binding := StageRestorationBinding.new()
	invalid_binding.key = &"gifts_delivered"
	invalid_binding.kind = StageRestorationBinding.Kind.SNAP_TO_MARKER
	invalid_binding.target_path = NodePath("Buster")
	invalid_binding.marker_path = NodePath("MissingMarker")
	invalid_binding.animation_player_path = NodePath("MissingPlayer")
	invalid_binding.animation_name = &"missing_pose"
	var binding_errors := invalid_binding.validate(stage)
	ok = _check("restoration validation reports bad types and missing marker or animation references",
		binding_errors.any(func(problem: String) -> bool: return "must be Boolean" in problem)
		and binding_errors.any(func(problem: String) -> bool: return "Marker3D" in problem)
		and binding_errors.any(func(problem: String) -> bool: return "AnimationPlayer" in problem)) and ok
	var actor := Node3D.new()
	root.add_child(actor)
	var gift_target := stage.get_node("RobotGiftTarget") as TriggerArea
	gift_target.set_eligibility_hook(func(_actor: Node) -> bool: return not stage.get_var(&"delivered_robot"))
	stage.fire(&"give:robot")
	var duplicate_id_refused := store.load_stage(scene, &"house_01_left", root) == null
	var dormant_prompt_filtered := not gift_target.can_interact(actor)
	ok = _check("managed Stage ignores Calls and interactions while dormant, and rejects duplicate instance IDs",
		duplicate_id_refused and dormant_prompt_filtered
		and not stage.get_var(&"delivered_robot") and stage.engine.active_snapshot().is_empty())
	stage.activate()
	ok = _check("managed Stage activates once and fires its arrival rule",
		stage.is_active and stage.has_fired(&"arrival_once") and stage.get_var(&"arrival_count") == 1) and ok
	var outcome := gift_target.interact(actor)
	await process_frame
	ok = _check("per-gift saved flag and add_var counter update on an accepted delivery",
		outcome.get("accepted", false) and stage.get_var(&"delivered_robot")
		and stage.get_var(&"gifts_delivered") == 1) and ok
	ok = _check("saved gift flag rejects duplicate interaction before unload",
		not gift_target.can_interact(actor)) and ok
	var changed_on_neighbor: Array = []
	var neighbor := store.load_stage(scene, &"house_01_right", root)
	await process_frame
	neighbor.var_changed.connect(func(key: StringName, value: Variant) -> void: changed_on_neighbor.append([key, value]))
	stage.write_var(&"town_bell", true, &"town_clock")
	ok = _check("shared Blackboard values propagate while stage-saved values remain independent",
		neighbor.get_var(&"town_bell") and changed_on_neighbor == [[&"town_bell", true]]
		and neighbor.bb.last_writers.get(&"town_bell") == &"town_clock"
		and not neighbor.get_var(&"delivered_robot") and neighbor.get_var(&"gifts_delivered") == 0) and ok
	var conflict_definition := StageDefinition.new()
	var conflict_value := VariableData.new()
	conflict_value.key = &"town_bell"
	conflict_value.scope = "shared"
	conflict_value.default_value = 0
	conflict_value.state_key = &"town_bell"
	conflict_definition.variables = [conflict_value]
	var conflict_stage := Stage.new()
	conflict_stage.definition = conflict_definition
	store.attach(conflict_stage, &"house_01_conflict")
	root.add_child(conflict_stage)
	await process_frame
	var type_conflicts := conflict_stage.check().filter(func(problem: String) -> bool: return "shared Blackboard key" in problem and "conflicting types" in problem)
	conflict_stage.write_var(&"town_bell", 1)
	ok = _check("shared Blackboard type conflicts are diagnosed and incompatible writes are rejected",
		not type_conflicts.is_empty() and store.shared_values[&"town_bell"] == true) and ok
	store.unload_stage(conflict_stage)
	var garage_transform := Transform3D(Basis.IDENTITY, Vector3(0, 1.2, 0))
	stage.write_var(&"garage_door_transform", garage_transform)
	store.unload_stage(neighbor)
	store.unload_stage(stage)
	actor.queue_free()
	await process_frame
	var restored := store.load_stage(scene, &"house_01_left", root)
	await process_frame
	if restored == null:
		return _check("state store reloads a previously unloaded Stage", false) and ok
	var restored_window := restored.get_node("BedroomWindowRobot") as Node3D
	var restored_skateboard_window := restored.get_node("BedroomWindowSkateboard") as Node3D
	var restored_door := restored.get_node("GarageDoor") as Node3D
	var restored_buster := restored.get_node("Buster") as Node3D
	var restored_player := restored.get_node("Buster/AnimationPlayer") as AnimationPlayer
	ok = _check("unloaded Stage restores saved gift state, counter and latch while dormant",
		not restored.is_active and restored.get_var(&"delivered_robot")
		and restored.get_var(&"gifts_delivered") == 1 and restored.get_var(&"arrival_count") == 1
		and restored.has_fired(&"arrival_once")) and ok
	ok = _check("restoration restores the saved window visibility",
		restored_window.visible and not restored_skateboard_window.visible) and ok
	ok = _check("restoration snaps the actor to its Marker3D",
		restored_buster.global_position.is_equal_approx((restored.get_node("RedDoghouse") as Marker3D).global_position)) and ok
	ok = _check("restoration applies a saved Node3D transform",
		restored_door.transform.origin.is_equal_approx(Vector3(0, 1.2, 0))) and ok
	var restored_visual := restored_buster.get_node("Visual") as Node3D
	ok = _check("restoration applies and pauses the configured animation pose",
		is_equal_approx(restored_visual.position.y, 0.125) and not restored_player.is_playing()) and ok
	var restored_gift := restored.get_node("RobotGiftTarget") as TriggerArea
	restored_gift.set_eligibility_hook(func(_actor: Node) -> bool: return not restored.get_var(&"delivered_robot"))
	var restored_skateboard_gift := restored.get_node("SkateboardGiftTarget") as TriggerArea
	restored_skateboard_gift.set_eligibility_hook(func(_actor: Node) -> bool: return not restored.get_var(&"delivered_skateboard"))
	var restored_actor := Node3D.new()
	root.add_child(restored_actor)
	restored.activate()
	ok = _check("restored gift flag rejects duplicates while a different gift remains eligible",
		not restored_gift.can_interact(restored_actor) and restored_skateboard_gift.can_interact(restored_actor)
		and restored.get_var(&"gifts_delivered") == 1
		and restored.get_var(&"arrival_count") == 1) and ok
	var skateboard_result := restored_skateboard_gift.interact(restored_actor)
	await process_frame
	ok = _check("a second gift increments the restored aggregate counter exactly once",
		skateboard_result.get("accepted", false) and restored.get_var(&"delivered_skateboard")
		and restored.get_var(&"gifts_delivered") == 2
		and not restored_skateboard_gift.can_interact(restored_actor)) and ok
	store.unload_stage(restored)
	restored_actor.queue_free()
	await process_frame
	var all_gifts_restored := store.load_stage(scene, &"house_01_left", root)
	await process_frame
	var completed_robot_window := all_gifts_restored.get_node("BedroomWindowRobot") as Node3D
	var completed_skateboard_window := all_gifts_restored.get_node("BedroomWindowSkateboard") as Node3D
	ok = _check("each gift restores its own visual and the saved counter after the next reload",
		completed_robot_window.visible and completed_skateboard_window.visible
		and all_gifts_restored.get_var(&"gifts_delivered") == 2) and ok
	store.unload_stage(all_gifts_restored)
	await process_frame
	return ok

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
