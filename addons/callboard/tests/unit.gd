extends SceneTree
## Deterministic validator, router and clock-injection tests.

signal clock_tick
signal two_argument_tick(value: int, label: String)
signal animation_finished_tick(animation_name: StringName)

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
	relay_stage.define_shared(&"rejected_shared_latch", false)
	relay_stage.register_external_writer(&"sensor_latched", &"yard_sensor", "bool")
	var relay_emitted: Array[StringName] = []
	relay_stage.rule_fired.connect(func(id: StringName, _event: StringName) -> void: relay_emitted.append(id))
	ok = _check("a relay latch requires a Boolean Blackboard key",
		not relay_stage.fire_relay_once(&"ready", &"wrong_latch_type", &"source", &"interact")
		and relay_emitted.is_empty() and relay_stage.get_var(&"wrong_latch_type") == 0) and ok
	relay_stage.bb.shared_write_guard = func(_key: StringName, _value: Variant, _board: Blackboard) -> bool: return false
	var rejected_shared_relay := relay_stage.fire_relay_once(&"ready", &"rejected_shared_latch", &"source", &"interact")
	ok = _check("a rejected shared latch write does not emit or fire a relay",
		not rejected_shared_relay and relay_emitted.is_empty()
		and not relay_stage.is_set(&"rejected_shared_latch")) and ok
	relay_stage.bb.shared_write_guard = Callable()
	var relay_rule_runs := [0]
	var ready_listener := Rule.new(&"ready_listener", &"relay:ready")
	ready_listener.steps.append(Step.new(func(_payload: Dictionary) -> void: relay_rule_runs[0] += 1))
	relay_stage.engine.rules.append(ready_listener)
	var reentry_results: Array[bool] = []
	var latch_reentry := func(key: StringName, value: Variant) -> void:
		if key == &"sensor_latched" and value == true:
			reentry_results.append(relay_stage.fire_relay_once(&"ready", &"sensor_latched", &"yard_sensor", &"sensor_changed"))
	relay_stage.bb.changed.connect(latch_reentry)
	var relay_success := relay_stage.fire_relay_once(&"ready", &"sensor_latched", &"yard_sensor", &"sensor_changed")
	relay_stage.bb.changed.disconnect(latch_reentry)
	var source_emit_count := relay_emitted.count(&"yard_sensor")
	var repeated_relay := relay_stage.fire_relay_once(&"ready", &"sensor_latched", &"yard_sensor", &"sensor_changed")
	ok = _check("one-shot relay follows a committed latch and resists listener re-entry",
		relay_success and not repeated_relay and reentry_results == [false]
		and source_emit_count == 1 and relay_rule_runs[0] == 1
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
	var initial_cancel_engine := RuleEngine.new(Blackboard.new(), {}, Callable())
	var initial_cancel_rule := Rule.new(&"payload_once", &"try_payload")
	initial_cancel_rule.one_shot = true
	initial_cancel_rule.cancel_if = [&"payload.cancelled == true"]
	var initial_cancel_steps := [0]
	var initial_cancel_starts := [0]
	var initial_cancel_fires := [0]
	initial_cancel_rule.steps.append(Step.new(func(_context: Dictionary) -> void:
		initial_cancel_steps[0] += 1))
	initial_cancel_engine.rules.append(initial_cancel_rule)
	initial_cancel_engine.trace_event.connect(func(data: Dictionary) -> void:
		if data.get("kind") == "rule_started":
			initial_cancel_starts[0] += 1)
	initial_cancel_engine.rule_fired.connect(func(_id: StringName, _event: StringName) -> void:
		initial_cancel_fires[0] += 1)
	initial_cancel_engine.fire(&"try_payload", {"cancelled": true})
	var rejected_before_latch: bool = (not initial_cancel_engine.fired.has(initial_cancel_rule.latch_key())
		and initial_cancel_starts[0] == 0 and initial_cancel_fires[0] == 0
		and initial_cancel_steps[0] == 0)
	initial_cancel_engine.fire(&"try_payload", {"cancelled": false})
	await process_frame
	var accepted_after_reject: bool = (initial_cancel_engine.fired.has(initial_cancel_rule.latch_key())
		and initial_cancel_starts[0] == 1 and initial_cancel_fires[0] == 1
		and initial_cancel_steps[0] == 1)
	initial_cancel_engine.cancel_all()
	ok = _check("incoming Cancel If rejects a one-shot before its latch, start trace, and signals",
		rejected_before_latch) and ok
	ok = _check("a one-shot can run when a later payload clears initial Cancel If",
		accepted_after_reject) and ok

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
	var integer_guards := Blackboard.new()
	integer_guards.define(&"large_count", &"local", 1000001)
	integer_guards.define(&"float_value", &"local", 1.0)
	var exact_ints := (not GuardExpression.evaluate(integer_guards, &"large_count == 1000000")
		and GuardExpression.evaluate(integer_guards, &"large_count != 1000000")
		and GuardExpression.evaluate(integer_guards, &"payload.count == 1000001", {"count": 1000001}, &"route", payload_schema)
		and not GuardExpression.evaluate(integer_guards, &"payload.count == 1000000", {"count": 1000001}, &"route", payload_schema))
	var float_semantics := (GuardExpression.evaluate(integer_guards, &"float_value == 1.0000001")
		and GuardExpression.evaluate(integer_guards, &"float_value == 1")
		and GuardExpression.evaluate(integer_guards, &"float_value < 2"))
	ok = _check("integer payload and Blackboard comparisons preserve exact integer values", exact_ints) and ok
	ok = _check("float equality remains approximate and mixed numeric guards compare numerically", float_semantics) and ok
	ok = _check("missing and incompatible payload values fail both equality and inequality",
		not GuardExpression.evaluate(route_bb, &"payload.action != \"confirm\"", {}, &"route", payload_schema)
		and not GuardExpression.evaluate(route_bb, &"payload.count != 3", {"count": "3"}, &"route", payload_schema)
		and not GuardExpression.evaluate(route_bb, &"payload.accepted == true", {"accepted": 1}, &"route", payload_schema)) and ok
	ok = _check("payload presence checks explicitly distinguish present and missing fields",
		GuardExpression.evaluate(route_bb, &"has(payload.action)", confirm_payload, &"route", payload_schema)
		and GuardExpression.evaluate(route_bb, &"missing(payload.action)", {}, &"route", payload_schema)
		and not GuardExpression.evaluate(route_bb, &"has(payload.action)", {}, &"route", payload_schema)) and ok
	ok = _check("runtime payload guards reject undeclared fields on a partially declared event",
		not GuardExpression.evaluate(route_bb, &"payload.extra == true", {"extra": true}, &"route", payload_schema)
		and not GuardExpression.evaluate(route_bb, &"missing(payload.extra)", {}, &"route", payload_schema)) and ok
	var payload_guard_rule := Rule.new(&"payload_guard", &"route")
	payload_guard_rule.requires = [&"payload.action == \"confirm\""]
	payload_guard_rule.steps.append(Step.new(func(_context: Dictionary) -> void: pass))
	var dynamic_payload_rule := Rule.new(&"dynamic_payload_guard", &"dynamic_route")
	dynamic_payload_rule.requires = [&"payload.action == \"confirm\""]
	dynamic_payload_rule.steps.append(Step.new(func(_context: Dictionary) -> void: pass))
	ok = _check("validator leaves undeclared payload schemas dynamic for runtime type checking",
		RuleValidator.check([dynamic_payload_rule], route_bb, [&"dynamic_route"], []).is_empty()) and ok
	var payload_guard_diagnostics := RuleValidator.check([payload_guard_rule], route_bb, [&"route"], [], payload_schema)
	ok = _check("validator treats payload references separately and checks declared field types",
		not payload_guard_diagnostics.any(func(problem: String) -> bool: return "Blackboard" in problem)
		and payload_guard_diagnostics.is_empty()) and ok
	payload_guard_rule.requires = [&"payload.count == \"three\""]
	payload_guard_diagnostics = RuleValidator.check([payload_guard_rule], route_bb, [&"route"], [], payload_schema)
	ok = _check("validator reports payload field and operand type mismatches",
		payload_guard_diagnostics.any(func(problem: String) -> bool: return "incompatible literal or operator" in problem)) and ok
	var typed_write_bb := Blackboard.new()
	typed_write_bb.define(&"flag", &"local", false)
	typed_write_bb.define(&"amount", &"local", 0.0)
	var wrong_set := Rule.new(&"wrong_set", &"write")
	var wrong_set_step := Step.new(func(_context: Dictionary) -> void: pass)
	wrong_set_step.verb = &"set_var"
	wrong_set_step.args = [&"flag", "yes"]
	wrong_set_step.sets = [&"flag"]
	wrong_set.steps.append(wrong_set_step)
	var widened_set := Rule.new(&"widened_set", &"write")
	var widened_set_step := Step.new(func(_context: Dictionary) -> void: pass)
	widened_set_step.verb = &"set_var"
	widened_set_step.args = [&"amount", 3]
	widened_set_step.sets = [&"amount"]
	widened_set.steps.append(widened_set_step)
	var wrong_set_problems := RuleValidator.check([wrong_set], typed_write_bb, [&"write"], [])
	ok = _check("validator catches statically incompatible set_var values",
		wrong_set_problems.any(func(problem: String) -> bool: return "set_var value of type String is incompatible" in problem)) and ok
	ok = _check("validator permits the runtime's integer-to-float set_var widening",
		RuleValidator.check([widened_set], typed_write_bb, [&"write"], []).is_empty()) and ok

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

	ok = await _test_restart() and ok
	ok = _test_queue() and ok
	ok = _test_signal_callbacks_accept_arguments() and ok
	ok = await _test_playback_wait_exits() and ok
	ok = await _test_cancel_if_interrupts_a_wait() and ok
	ok = _test_shared_write_order() and ok
	ok = _test_emit_relay() and ok
	ok = _test_on_change_triggers() and ok
	ok = await _test_dispatch_limits_and_ancestry() and ok
	ok = _test_stage_dispatch_policy() and ok
	ok = _test_retriggered_light() and ok
	ok = await _test_light_from_restarted_run() and ok
	ok = await _test_managed_stages_and_restoration() and ok
	print("UNIT: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)

func _test_signal_callbacks_accept_arguments() -> bool:
	var engine := RuleEngine.new(Blackboard.new(), {}, Callable())
	var completion_seen := [false]
	var completion := engine.interruptible(two_argument_tick)
	completion.connect(func() -> void: completion_seen[0] = true)
	engine.track_signal(two_argument_tick, &"signal_arity", "two-argument signal")
	var pending_before_emit := engine.pending_snapshot().size() == 1
	two_argument_tick.emit(23, "finished")
	var ok := _check("wait and diagnostic callbacks accept signals with two arguments",
		pending_before_emit and completion_seen[0] and engine._awaited_signals.is_empty()
		and engine.pending_snapshot().is_empty() and two_argument_tick.get_connections().is_empty())
	engine.cancel_all()
	var filtered_engine := RuleEngine.new(Blackboard.new(), {}, Callable())
	var expected_completion_seen := [false]
	var expected_completion := filtered_engine.interruptible(animation_finished_tick,
		func(animation_name: StringName) -> bool: return animation_name == &"requested")
	expected_completion.connect(func() -> void: expected_completion_seen[0] = true)
	animation_finished_tick.emit(&"replacement")
	var replacement_was_ignored: bool = not expected_completion_seen[0]
	animation_finished_tick.emit(&"requested")
	ok = _check("a playback wait ignores completion from a different animation",
		replacement_was_ignored and expected_completion_seen[0]
		and filtered_engine._awaited_signals.is_empty()
		and animation_finished_tick.get_connections().is_empty()) and ok
	filtered_engine.cancel_all()
	var ticket_engine := RuleEngine.new(Blackboard.new(), {}, Callable())
	var ticket_factory := StagingVerbs.new(StepContext.new(Blackboard.new(), ticket_engine, null, Callable()))
	var animation_player := AnimationPlayer.new()
	var first_ticket := ticket_factory._supersede_animation_playback(animation_player)
	var ticket_run := {"cancelled": false}
	var ticket_wait := ticket_engine.interruptible(animation_finished_tick,
		func(animation_name: StringName) -> bool: return animation_name == &"requested",
		[first_ticket.superseded], ticket_run)
	var ticket_wait_resumed := [false]
	ticket_wait.connect(func() -> void: ticket_wait_resumed[0] = true)
	ticket_factory._supersede_animation_playback(animation_player)
	ok = _check("replaying an animation supersedes and cancels its earlier wait",
		ticket_run["cancelled"] and ticket_wait_resumed[0]
		and ticket_engine._awaited_signals.is_empty()
		and animation_finished_tick.get_connections().is_empty()) and ok
	animation_player.free()
	ticket_engine.cancel_all()
	var cancelled_engine := RuleEngine.new(Blackboard.new(), {}, Callable())
	cancelled_engine.interruptible(two_argument_tick)
	cancelled_engine.track_signal(two_argument_tick, &"signal_arity", "cancelled two-argument signal")
	cancelled_engine.cancel_all()
	ok = _check("cancelling a wait disconnects its source and clears diagnostics",
		cancelled_engine._awaited_signals.is_empty() and cancelled_engine.pending_snapshot().is_empty()
		and two_argument_tick.get_connections().is_empty()) and ok
	return ok

func _test_playback_wait_exits() -> bool:
	var factory := StagingVerbs.new(StepContext.new(Blackboard.new(), null, root, Callable()))
	var stopped_target := Node.new()
	root.add_child(stopped_target)
	var stopped_ticket := StagingVerbs.PlaybackTicket.new()
	var stopped_reason: Array[StringName] = []
	stopped_ticket.interrupted.connect(func(reason: StringName) -> void: stopped_reason.append(reason))
	var playing := [true]
	factory._start_playback_monitor(stopped_target, stopped_ticket,
		func() -> bool: return playing[0], 0.0)
	playing[0] = false
	await process_frame
	var stop_releases := stopped_reason == [&"stopped"]
	stopped_target.queue_free()
	await process_frame

	var removed_target := Node.new()
	root.add_child(removed_target)
	var removed_ticket := StagingVerbs.PlaybackTicket.new()
	var removed_reason: Array[StringName] = []
	removed_ticket.interrupted.connect(func(reason: StringName) -> void: removed_reason.append(reason))
	factory._start_playback_monitor(removed_target, removed_ticket,
		func() -> bool: return true, 0.0)
	await process_frame
	root.remove_child(removed_target)
	await process_frame
	var removal_releases := removed_reason == [&"target_removed"]
	removed_target.free()

	var looping_target := Node.new()
	root.add_child(looping_target)
	var looping_ticket := StagingVerbs.PlaybackTicket.new()
	var timeout_reason: Array[StringName] = []
	looping_ticket.interrupted.connect(func(reason: StringName) -> void: timeout_reason.append(reason))
	factory._start_playback_monitor(looping_target, looping_ticket,
		func() -> bool: return true, 0.02)
	await create_timer(0.06).timeout
	var timeout_releases := timeout_reason == [&"timeout"]
	looping_target.queue_free()
	await process_frame
	return (_check("stopping playback cancels its wait", stop_releases)
		and _check("removing a playback target cancels its wait", removal_releases)
		and _check("a looping playback wait is released by its optional timeout", timeout_releases))

func _test_cancel_if_interrupts_a_wait() -> bool:
	var bb := Blackboard.new()
	bb.define(&"stop_playback", &"local", false)
	var engine := RuleEngine.new(bb, {}, func(_seconds: float) -> Signal: return clock_tick)
	var engine_ref := weakref(engine)
	var rule := Rule.new(&"cancel_playback", &"play")
	rule.cancel_if = [&"stop_playback"]
	var later_step_ran := [false]
	rule.steps.append(Step.new(func(payload: Dictionary) -> Signal:
		var run: Dictionary = payload["_callboard"]["run"]
		var cancellation: RuleEngine.AwaitedSignal = run["cancel_signal"]
		var active_engine := engine_ref.get_ref() as RuleEngine
		return active_engine.interruptible(clock_tick, Callable(), [cancellation.cancelled], run)))
	rule.steps.append(Step.new(func(_payload: Dictionary) -> void: later_step_ran[0] = true))
	engine.rules.append(rule)
	engine.fire(&"play")
	bb.write(&"stop_playback", true)
	await process_frame
	var cancelled: bool = later_step_ran[0] == false and engine._cancel_if_callbacks.is_empty()
	clock_tick.emit()
	await process_frame
	engine.cancel_all()
	return _check("Cancel If releases a playback wait and skips remaining steps", cancelled)

func _test_shared_write_order() -> bool:
	var store := StageStateStore.new()
	store.shared_values = {}
	var source := Blackboard.new({}, store.shared_values)
	var receiver := Blackboard.new({}, store.shared_values)
	source.define(&"ready", &"shared", false, &"town_ready")
	receiver.define(&"ready", &"shared", false, &"town_ready")
	store.register_blackboard(source)
	store.register_blackboard(receiver)
	var notifications: Array[String] = []
	var source_nested := [false]
	var receiver_nested := [false]
	var source_callback := func(key: StringName, value: Variant) -> void:
		if key != &"ready":
			return
		notifications.append("source:%s" % str(value))
		if value == true and not source_nested[0]:
			source_nested[0] = true
			receiver.write(&"ready", false, &"source_listener")
	var receiver_callback := func(key: StringName, value: Variant) -> void:
		if key != &"ready":
			return
		notifications.append("receiver:%s" % str(value))
		if value == true and not receiver_nested[0]:
			receiver_nested[0] = true
			source.write(&"ready", true, &"receiver_listener")
	source.changed.connect(source_callback)
	receiver.changed.connect(receiver_callback)
	source.write(&"ready", true, &"initial_writer")
	var expected := ["source:true", "receiver:true", "receiver:false", "source:false",
		"source:true", "receiver:true"]
	var in_order := notifications == expected
	var one_final_value: bool = (store.shared_values[&"town_ready"] == true
		and source.get_var(&"ready") == true and receiver.get_var(&"ready") == true
		and source.last_writers[&"ready"] == &"receiver_listener"
		and receiver.last_writers[&"ready"] == &"receiver_listener")
	var notification_count := notifications.size()
	source.write(&"ready", true, &"no_op_writer")
	var unchanged_is_quiet: bool = notifications.size() == notification_count
	source.write(&"ready", "wrong type", &"rejected_writer")
	var rejected_is_quiet: bool = notifications.size() == notification_count
	var final_writer_survived: bool = source.last_writers[&"ready"] == &"receiver_listener"
	source.changed.disconnect(source_callback)
	receiver.changed.disconnect(receiver_callback)
	store.unregister_blackboard(source)
	store.unregister_blackboard(receiver)
	return (_check("nested shared writes deliver each commit to all Stages in order (notifications=%s)" % [notifications], in_order)
		and _check("shared values and writer attribution match the final committed write", one_final_value)
		and _check("unchanged shared writes do not notify or replace the writer", unchanged_is_quiet and final_writer_survived)
		and _check("rejected shared writes do not notify", rejected_is_quiet))

func _test_emit_relay() -> bool:
	var bb := Blackboard.new()
	var engine := RuleEngine.new(bb, {}, Callable())
	engine.payload_schema = {
		&"start": {&"action": TYPE_STRING, &"ignored": TYPE_INT},
		&"relay:mapped": {&"result": TYPE_STRING},
	}
	var factory := CoreVerbs.new(StepContext.new(bb, engine, null, Callable()))
	var source := Rule.new(&"mapped_source", &"start")
	var mapping := {"result": "action"}
	var emit_step := factory.emit_relay(&"mapped", mapping)
	emit_step.verb = &"emit_relay"
	emit_step.args = [&"mapped", mapping]
	source.steps.append(emit_step)
	var received: Array[Dictionary] = []
	var listener := Rule.new(&"mapped_listener", &"relay:mapped")
	listener.steps.append(Step.new(func(context: Dictionary) -> void:
		received.append(context["payload"].duplicate(true))))
	engine.rules.append_array([source, listener])
	var traced_step: Array[Dictionary] = []
	engine.trace_event.connect(func(entry: Dictionary) -> void:
		if entry.get("kind") == "step_started" and entry.get("verb") == "emit_relay":
			traced_step.append(entry))
	engine.fire(&"start", {"action": "confirm", "ignored": 7})
	var mapped_payload: bool = received == [{"result": "confirm"}]
	var relay_metadata: bool = emit_step.emits == &"mapped" and emit_step.emit_arg == 0 \
		and traced_step.size() == 1 and traced_step[0].get("relay") == "mapped" \
		and traced_step[0].get("relay_argument") == 0
	var valid_mapping := RuleValidator.check([source, listener], bb, [&"start"], [], engine.payload_schema)
	var valid_types: bool = valid_mapping.is_empty()
	engine.payload_schema[&"relay:mapped"][&"result"] = TYPE_BOOL
	var invalid_mapping := RuleValidator.check([source, listener], bb, [&"start"], [], engine.payload_schema)
	var mismatch_reported: bool = invalid_mapping.any(func(problem: String) -> bool:
		return "emit_relay maps 'action'" in problem and "incompatible types" in problem)

	var cycle_engine := RuleEngine.new(Blackboard.new(), {}, Callable())
	var cycle_factory := CoreVerbs.new(StepContext.new(cycle_engine.bb, cycle_engine, null, Callable()))
	var first := Rule.new(&"immediate_cycle_a", &"relay:a")
	first.reentry = Rule.ReentryPolicy.QUEUE
	first.steps.append(cycle_factory.emit_relay(&"b"))
	var second := Rule.new(&"immediate_cycle_b", &"relay:b")
	second.reentry = Rule.ReentryPolicy.QUEUE
	second.steps.append(cycle_factory.emit_relay(&"a"))
	cycle_engine.rules.append_array([first, second])
	var cycle_stopped := [false]
	cycle_engine.dispatch_limit_reached.connect(func(limit: String, chain: PackedStringArray, _rule: StringName) -> void:
		if limit == "event depth" and chain.has("relay:a") and chain.has("relay:b"):
			cycle_stopped[0] = true)
	cycle_engine.fire(&"relay:a")
	return (_check("emit_relay selects/remaps fields and exposes its relay argument in step traces",
		mapped_payload and relay_metadata) \
		and _check("emit_relay payload mappings validate source and destination schema types",
		valid_types and mismatch_reported) \
		and _check("immediate relay cycles carry ancestry into the engine depth limit", cycle_stopped[0]))

func _test_on_change_triggers() -> bool:
	var definition := StageDefinition.new()
	definition.external_calls = PackedStringArray(["arrive"])
	definition.external_vars = PackedStringArray(["local_count", "saved_count", "shared_count"])
	var local_value := VariableData.new()
	local_value.key = &"local_count"
	local_value.default_value = 0
	var saved_value := VariableData.new()
	saved_value.key = &"saved_count"
	saved_value.scope = "saved"
	saved_value.default_value = 0
	var shared_value := VariableData.new()
	shared_value.key = &"shared_count"
	shared_value.scope = "shared"
	shared_value.default_value = 0
	shared_value.state_key = &"town_count"
	definition.variables = [local_value, saved_value, shared_value]
	var store := StageStateStore.new()
	store.shared_values = {}
	var stage := Stage.new()
	stage.definition = definition
	store.attach(stage, &"watch_source")
	stage.build()
	var changes: Array[Dictionary] = []
	for watched_key: StringName in [&"local_count", &"saved_count", &"shared_count"]:
		var listener := Rule.new(StringName("watch_" + String(watched_key)), &"on_change")
		listener.requires = [StringName('payload.key == "%s"' % watched_key)]
		listener.steps.append(Step.new(func(context: Dictionary) -> void:
			changes.append(context["payload"].duplicate(true))))
		stage.engine.rules.append(listener)
	var no_initial_events := changes.is_empty()
	var per_key_listeners_validate := not RuleValidator.check(stage.engine.rules, stage.bb,
		stage.external_calls, stage.external_vars, stage.payload_schema).any(
		func(problem: String) -> bool: return "share trigger 'on_change'" in problem)
	stage.write_var(&"local_count", 1, &"local_writer")
	stage.write_var(&"local_count", 1, &"no_op")
	stage.write_var(&"local_count", "bad", &"rejected")
	stage.write_var(&"saved_count", 2, &"save_writer")
	var local_saved_commits := changes.size() == 2 \
		and changes[0] == {"key": "local_count", "previous": 0, "value": 1, "scope": "local", "writer": "local_writer"} \
		and changes[1] == {"key": "saved_count", "previous": 0, "value": 2, "scope": "saved", "writer": "save_writer"}
	stage._restoring_state = true
	stage.write_var(&"local_count", 3, &"restoration")
	stage._restoring_state = false
	var restoration_suppressed := changes.size() == 2
	var nested_write_requested := [false]
	var nested_write_listener := func(key: StringName, value: Variant) -> void:
		if key == &"local_count" and value == 4 and not nested_write_requested[0]:
			nested_write_requested[0] = true
			stage.write_var(key, 5, &"nested_writer")
	stage.var_changed.connect(nested_write_listener)
	stage.write_var(&"local_count", 4, &"outer_writer")
	stage.var_changed.disconnect(nested_write_listener)
	var nested_transitions_ordered: bool = changes.size() == 4 \
		and changes[2].get("previous") == 3 and changes[2].get("value") == 4 \
		and changes[3].get("previous") == 4 and changes[3].get("value") == 5
	var dynamic_transition_values_work := GuardExpression.evaluate(stage.bb, &"payload.previous == 0",
		{"previous": 0}, &"on_change", definition.payload_schema()) \
		and GuardExpression.evaluate(stage.bb, &"payload.value == 2",
		{"value": 2}, &"on_change", definition.payload_schema())

	var receiver_definition := definition.duplicate(true) as StageDefinition
	receiver_definition.managed_lifecycle = true
	var receiver := Stage.new()
	receiver.definition = receiver_definition
	store.attach(receiver, &"watch_receiver")
	receiver.build()
	var receiver_changes: Array[Dictionary] = []
	var receiver_shared_listener := Rule.new(&"watch_shared_receiver", &"on_change")
	receiver_shared_listener.requires = [StringName('payload.key == "shared_count"')]
	receiver_shared_listener.steps.append(Step.new(func(context: Dictionary) -> void:
		var payload: Dictionary = context["payload"]
		receiver_changes.append(payload.duplicate(true))))
	receiver.engine.rules.append(receiver_shared_listener)
	var dormant_notifications_suppressed := true
	stage.write_var(&"shared_count", 1, &"shared_writer")
	var source_shared_transition := changes.any(func(payload: Dictionary) -> bool:
		return payload.get("key") == "shared_count" and payload.get("previous") == 0 \
			and payload.get("value") == 1 and payload.get("scope") == "shared")
	dormant_notifications_suppressed = receiver.get_var(&"shared_count") == 1 \
		and receiver.engine.active_snapshot().is_empty()
	receiver.activate()
	stage.write_var(&"shared_count", 2, &"shared_writer")
	var shared_reaches_active_receiver: bool = receiver.get_var(&"shared_count") == 2 \
		and receiver_changes.size() == 1 and receiver_changes[0].get("previous") == 1 \
		and receiver_changes[0].get("value") == 2
	store.unregister_blackboard(stage.bb)
	store.unregister_blackboard(receiver.bb)
	store.release_stage(stage)
	store.release_stage(receiver)
	stage.free()
	receiver.free()

	var loop_definition := StageDefinition.new()
	var loop_value := VariableData.new()
	loop_value.key = &"loop_count"
	loop_value.default_value = 0
	loop_definition.variables = [loop_value]
	var loop_stage := Stage.new()
	loop_stage.definition = loop_definition
	loop_stage.build()
	var loop_rule := Rule.new(&"loop_on_change", &"on_change")
	loop_rule.requires = [StringName('payload.key == "loop_count"')]
	loop_rule.reentry = Rule.ReentryPolicy.QUEUE
	loop_rule.steps.append(CoreVerbs.new(StepContext.new(loop_stage.bb, loop_stage.engine,
		loop_stage, Callable())).add_var(&"loop_count", 1.0))
	loop_stage.engine.rules.append(loop_rule)
	var loop_limited := [false]
	loop_stage.engine.dispatch_limit_reached.connect(func(limit: String, _chain: PackedStringArray, _rule: StringName) -> void:
		if limit == "event depth":
			loop_limited[0] = true)
	loop_stage.write_var(&"loop_count", 1)
	var feedback_stopped: bool = loop_limited[0] and loop_stage.get_var(&"loop_count") < 100
	loop_stage.free()

	var validation_bb := Blackboard.new()
	validation_bb.define(&"writable", &"local", 0)
	var bad_listener := Rule.new(&"bad_change_listener", &"on_change")
	bad_listener.requires = [StringName('payload.key == "missing"')]
	bad_listener.steps.append(Step.new(func(_context: Dictionary) -> void: pass))
	var bad_writer_problems := RuleValidator.check([bad_listener], validation_bb, [], [])
	var writer_diagnostic := bad_writer_problems.any(func(problem: String) -> bool:
		return "on_change key 'missing'" in problem and "not declared" in problem)
	var undeclared_writer_listener := Rule.new(&"unwritten_change_listener", &"on_change")
	undeclared_writer_listener.requires = [StringName('payload.key == "writable"')]
	undeclared_writer_listener.steps.append(Step.new(func(_context: Dictionary) -> void: pass))
	var missing_writer_diagnostic := RuleValidator.check([undeclared_writer_listener], validation_bb, [], []).any(
		func(problem: String) -> bool: return "on_change key 'writable'" in problem and "no writer is declared" in problem)
	return (_check("Blackboard change events carry typed committed transitions and ignore initialization, no-op and rejected writes",
		no_initial_events and local_saved_commits and restoration_suppressed and nested_transitions_ordered and dynamic_transition_values_work
		and per_key_listeners_validate) \
		and _check("shared change listeners observe commits only while active Stages are dispatchable",
		source_shared_transition and dormant_notifications_suppressed and shared_reaches_active_receiver) \
		and _check("on_change feedback inherits event ancestry and stops at the RuleEngine depth limit", feedback_stopped) \
		and _check("on_change listeners validate their Blackboard key and declared writers",
			writer_diagnostic and missing_writer_diagnostic))

func _test_dispatch_limits_and_ancestry() -> bool:
	var depth_engine := RuleEngine.new(Blackboard.new(), {}, Callable())
	var started := [0]
	var limit_chains: Array[PackedStringArray] = []
	var next_events: Dictionary = {}
	var depth_engine_ref := weakref(depth_engine)
	depth_engine.dispatch_limit_reached.connect(func(_limit: String, chain: PackedStringArray,
			_rule_id: StringName) -> void: limit_chains.append(chain))
	depth_engine.rule_fired.connect(func(rule_id: StringName, _event: StringName) -> void:
		started[0] += 1
		if next_events.has(rule_id):
			var engine := depth_engine_ref.get_ref() as RuleEngine
			engine.fire(next_events[rule_id]))
	for event_index in RuleEngine.MAX_FIRE_DEPTH:
		var event_name := StringName("chain_%d" % event_index)
		var next_event := StringName("chain_%d" % (event_index + 1))
		var rule := Rule.new(StringName("chain_rule_%d" % event_index), event_name)
		next_events[rule.id] = next_event
		depth_engine.rules.append(rule)
	depth_engine.fire(&"chain_0")
	var depth_stopped: bool = started[0] == RuleEngine.MAX_FIRE_DEPTH and limit_chains.size() == 1 \
		and limit_chains[0].size() == RuleEngine.MAX_FIRE_DEPTH + 1
	depth_engine.cancel_all()
	depth_engine.rules.clear()

	var cycle_engine := RuleEngine.new(Blackboard.new(), {}, func(_seconds: float) -> Signal: return clock_tick)
	var cycle_engine_ref := weakref(cycle_engine)
	var cycle_limit_chains: Array[PackedStringArray] = []
	cycle_engine.dispatch_limit_reached.connect(func(limit: String, chain: PackedStringArray,
			_rule_id: StringName) -> void:
		if limit == "event depth":
			cycle_limit_chains.append(chain))
	var cycle_a := Rule.new(&"cycle_a", &"cycle_a")
	cycle_a.reentry = Rule.ReentryPolicy.QUEUE
	cycle_a.steps.append(Step.new(func(payload: Dictionary) -> Signal:
		var run: Dictionary = payload["_callboard"]["run"]
		var cancellation: RuleEngine.AwaitedSignal = run["cancel_signal"]
		var engine := cycle_engine_ref.get_ref() as RuleEngine
		return engine.interruptible(clock_tick, Callable(), [cancellation.cancelled], run)))
	cycle_a.steps.append(Step.new(func(payload: Dictionary) -> void:
		var context: Dictionary = payload["_callboard"]["run"]["context"]
		var engine := cycle_engine_ref.get_ref() as RuleEngine
		engine.fire_from_context(&"cycle_b", {}, context)))
	var cycle_b := Rule.new(&"cycle_b", &"cycle_b")
	cycle_b.steps.append(Step.new(func(payload: Dictionary) -> void:
		var context: Dictionary = payload["_callboard"]["run"]["context"]
		var engine := cycle_engine_ref.get_ref() as RuleEngine
		engine.fire_from_context(&"cycle_a", {}, context)))
	cycle_engine.rules.append_array([cycle_a, cycle_b])
	cycle_engine.fire(&"cycle_a")
	for _i in RuleEngine.MAX_FIRE_DEPTH + 2:
		clock_tick.emit()
		await process_frame
	var yielding_cycle_stopped := cycle_limit_chains.size() == 1 \
		and cycle_limit_chains[0].size() == RuleEngine.MAX_FIRE_DEPTH + 1
	cycle_engine.cancel_all()
	clock_tick.emit()
	cycle_engine.rules.clear()

	var queue_engine := RuleEngine.new(Blackboard.new(), {}, func(_seconds: float) -> Signal: return clock_tick)
	var queue_rule := Rule.new(&"bounded_queue", &"queue_limit")
	queue_rule.reentry = Rule.ReentryPolicy.QUEUE
	queue_rule.steps.append(Step.new(func(_payload: Dictionary) -> void: pass).after(1.0))
	queue_engine.rules.append(queue_rule)
	var queue_limit_count := [0]
	queue_engine.dispatch_limit_reached.connect(func(limit: String, _chain: PackedStringArray,
			_rule_id: StringName) -> void:
		if limit == "pending queue":
			queue_limit_count[0] += 1)
	queue_engine.fire(&"queue_limit")
	for _i in RuleEngine.MAX_PENDING_PER_RULE + 1:
		queue_engine.fire(&"queue_limit")
	var queue_bounded: bool = queue_engine.active_snapshot()[0]["queued"] == RuleEngine.MAX_PENDING_PER_RULE \
		and queue_limit_count[0] == 1
	queue_engine.cancel_all()
	clock_tick.emit()

	var frame_engine := RuleEngine.new(Blackboard.new(), {}, Callable())
	var frame_starts := [0]
	for _i in RuleEngine.MAX_DISPATCHES_PER_FRAME + 1:
		var rule := Rule.new(StringName("budget_%d" % _i), &"frame_budget")
		rule.steps.append(Step.new(func(_payload: Dictionary) -> void: frame_starts[0] += 1))
		frame_engine.rules.append(rule)
	var frame_limits := [0]
	frame_engine.dispatch_limit_reached.connect(func(limit: String, _chain: PackedStringArray,
			_rule_id: StringName) -> void:
		if limit == "per-frame dispatch budget":
			frame_limits[0] += 1)
	frame_engine.fire(&"frame_budget")
	var frame_bounded: bool = frame_starts[0] == RuleEngine.MAX_DISPATCHES_PER_FRAME \
		and frame_limits[0] == 1
	frame_engine.cancel_all()
	await process_frame
	return (_check("nested public fires retain ancestry and stop at the depth limit", depth_stopped)
		and _check("a yielding host-callback cycle keeps ancestry and hits the depth limit", yielding_cycle_stopped)
		and _check("queued re-entry preserves accepted order within the pending limit", queue_bounded)
		and _check("dispatch work is capped per frame with one diagnostic", frame_bounded))

func _test_stage_dispatch_policy() -> bool:
	var unbuilt := Stage.new()
	var unbuilt_events := [0]
	var unbuilt_blocked := [false]
	unbuilt.gameplay_event.connect(func(_id: StringName, _args: Dictionary) -> void: unbuilt_events[0] += 1)
	unbuilt.dispatch_blocked.connect(func(action: String, reason: String) -> void:
		if "has not been built" in reason and action.begins_with("Call"):
			unbuilt_blocked[0] = true)
	unbuilt.fire(&"before_build")
	unbuilt.publish_gameplay_event(&"before_build")
	var unbuilt_relay := unbuilt.fire_relay_once(&"ready", &"missing", &"source", &"call")
	var unbuilt_ok: bool = not unbuilt_relay and unbuilt_events[0] == 0 and unbuilt_blocked[0]
	unbuilt.free()

	var partial := Stage.new()
	var definition := StageDefinition.new()
	var variable := VariableData.new()
	variable.key = &"valid_called"
	definition.variables = [variable]
	var partial_rule := RuleData.new()
	partial_rule.id = &"partially_compiled"
	partial_rule.trigger = &"partial_call"
	var valid_step := StepData.new()
	valid_step.verb = &"set_var"
	valid_step.args = PackedStringArray(['&"valid_called"', "true"])
	var invalid_step := StepData.new()
	invalid_step.verb = &"missing_verb"
	partial_rule.steps = [valid_step, invalid_step]
	definition.rules = [partial_rule]
	partial.definition = definition
	partial.build()
	var partial_diagnostic := [false]
	partial.dispatch_blocked.connect(func(action: String, reason: String) -> void:
		if action == "Call 'partial_call'" and "missing_verb" in reason:
			partial_diagnostic[0] = true)
	var placeholder_preserved: bool = (partial.engine.rules.size() == 1
		and partial.engine.rules[0].steps.size() == 2
		and partial.graph_errors.size() == 1)
	partial.fire(&"partial_call")
	partial.activate()
	var partial_blocked: bool = (placeholder_preserved and not partial.get_var(&"valid_called")
		and partial_diagnostic[0])
	partial.free()

	var unmanaged := Stage.new()
	unmanaged.build()
	unmanaged.define_local(&"direct_called", false)
	var direct_rule := Rule.new(&"direct_rule", &"direct_call")
	direct_rule.steps.append(CoreVerbs.new(StepContext.new(unmanaged.bb, unmanaged.engine,
		unmanaged, Callable())).set_var(&"direct_called", true))
	unmanaged.engine.rules.append(direct_rule)
	unmanaged.fire(&"direct_call")
	var unmanaged_direct_call: bool = unmanaged.is_set(&"direct_called")
	unmanaged.free()
	return (_check("unbuilt Stages reject Calls, relays, and gameplay events with diagnostics", unbuilt_ok)
		and _check("an invalid partial graph blocks even its valid compiled steps", partial_blocked)
		and _check("a valid unmanaged Stage accepts Calls after build without activate()", unmanaged_direct_call))

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
	var dormant_call_reported := [false]
	stage.dispatch_blocked.connect(func(action: String, reason: String) -> void:
		if action == "Call 'give:robot'" and "dormant" in reason:
			dormant_call_reported[0] = true)
	stage.fire(&"give:robot")
	var duplicate_id_refused := store.load_stage(scene, &"house_01_left", root) == null
	var dormant_prompt_filtered := not gift_target.can_interact(actor)
	ok = _check("managed Stage ignores Calls and interactions while dormant, and rejects duplicate instance IDs",
		duplicate_id_refused and dormant_prompt_filtered
		and not stage.get_var(&"delivered_robot") and stage.engine.active_snapshot().is_empty()
		and dormant_call_reported[0])
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
	var run_trace: Array[String] = []
	engine.trace_event.connect(func(entry: Dictionary) -> void:
		run_trace.append("%s:%s:%s" % [entry["kind"], entry["rule"], entry["event"]]))
	rule.steps.append(Step.new(func(ctx: Dictionary) -> void:
		starts.append(ctx["turn_on"])
		if ctx["turn_on"]:
			light_step.fn.call(ctx)))
	rule.steps.append(Step.new(func(_ctx: Dictionary) -> void: pass).after(1.0))
	engine.rules.append(rule)
	engine.fire(&"light", {"turn_on": true})
	var light_started := lamp.visible and bb.is_set(&"lamp_on")
	engine.fire(&"light", {"turn_on": false})
	await process_frame
	var replacement_started_without_clock := starts == [true, false]
	clock_tick.emit()
	var light_restart_succeeded := (light_started and starts == [true, false]
		and replacement_started_without_clock and not lamp.visible and not bb.is_set(&"lamp_on"))
	var ok := _check("restart wakes the timed-light run before its replacement skips the light (starts=%s, replacement_started=%s, trace=%s)" % [
		starts, replacement_started_without_clock, run_trace], light_restart_succeeded)
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
	await process_frame
	var ok := _check("restart releases the old wait and starts the latest run immediately",
		starts == [1, 3] and engine.pending_snapshot().size() == 1)
	clock_tick.emit()
	ok = _check("the replacement repeat emits only its own tick", ticks == [3]) and ok
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
