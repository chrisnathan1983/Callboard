extends SceneTree
## Deterministic validator, router and clock-injection tests.

const CrossStageValidator := preload("res://addons/callboard/model/cross_stage_event_validator.gd")
const DeliveryTargetScript := preload("res://addons/callboard/core/delivery_target.gd")
const CallboardLocalizationScript := preload("res://addons/callboard/core/callboard_localization.gd")
const TriggerRoutingData = preload("res://addons/callboard/core/trigger_routing_data.gd")
const CallboardHistoryScript = preload("res://addons/callboard/editor/callboard_history.gd")
const ScenarioClockScript = preload("res://addons/callboard/tests/scenario_clock.gd")
const ScenarioRunnerScript = preload("res://addons/callboard/tests/scenario_runner.gd")

signal clock_tick
signal two_argument_tick(value: int, label: String)
signal animation_finished_tick(animation_name: StringName)

func _initialize() -> void:
	var ok := true
	var localized_fallback := CallboardLocalizationScript.resolve(&"Callboard.Tests.Missing", {"item": "kite"}, "Take the {item}")
	var prompt := TriggerArea.new()
	prompt.prompt_translation_key = &"Callboard.Tests.MissingPrompt"
	prompt.prompt_fallback_text = "Open the {target}"
	prompt.prompt_substitutions = {"target": "gate"}
	var authored_prompt := prompt.resolve_prompt(null).get("text", "")
	prompt.set_prompt_provider(func(_actor: Node, _context: Dictionary) -> Dictionary:
		return {"translation_key": &"Callboard.Tests.DynamicPrompt", "fallback": "Use {item}",
			"substitutions": {"item": "key"}}
	)
	var host_prompt := prompt.resolve_prompt(null).get("text", "")
	var speech_target := Node3D.new()
	root.add_child(speech_target)
	var speech_context := StepContext.new(Blackboard.new(), null, null, Callable())
	var speech_step := StagingVerbs.new(speech_context).say_key(speech_target, &"Callboard.Tests.MissingSpeech",
		{"name": "Ari"}, 1.0, "Hello, {name}!")
	speech_step.fn.call({})
	var speech_label := speech_target.get_node_or_null("CallboardSpeech") as Label3D
	var localized_speech := speech_label != null and speech_label.text == "Hello, Ari!"
	speech_target.queue_free()
	prompt.free()
	ok = _check("localized messages preserve literals and format speech, authored prompts, and host prompts",
		localized_fallback == "Take the kite" and authored_prompt == "Open the gate"
		and host_prompt == "Use key" and localized_speech) and ok
	var diagnostic_bb := Blackboard.new()
	diagnostic_bb.define(&"coins", &"local", 3)
	var diagnostic_engine := RuleEngine.new(diagnostic_bb, {&"already_seen": true},
		func(_seconds: float) -> Signal: return clock_tick)
	var guarded_rule := Rule.new(&"guarded", &"diagnose")
	guarded_rule.one_shot = true
	guarded_rule.requires = [&"coins >= 5"]
	var latched_rule := Rule.new(&"already_seen", &"diagnose")
	latched_rule.one_shot = true
	diagnostic_engine.rules = [guarded_rule, latched_rule]
	var diagnostics: Array[Dictionary] = []
	diagnostic_engine.trace_event.connect(func(entry: Dictionary) -> void:
		if entry.get("kind") == "rule_rejected":
			diagnostics.append(entry.duplicate(true)))
	diagnostic_engine.fire(&"diagnose")
	var failed_guard_trace: Dictionary = diagnostics[0] if diagnostics.size() > 0 else {}
	var latched_trace: Dictionary = diagnostics[1] if diagnostics.size() > 1 else {}
	ok = _check("rule rejection traces expose guard values, trigger order, and one-shot latch state",
		diagnostics.size() == 2 and failed_guard_trace.get("order") == 1
		and failed_guard_trace.get("trigger_rule_count") == 2
		and failed_guard_trace.get("guard") == "coins >= 5"
		and failed_guard_trace.get("observations", []).any(func(item: Dictionary) -> bool:
			return "observed 3" in item.get("detail", ""))
		and latched_trace.get("order") == 2 and latched_trace.get("latch_set", false)
		and latched_trace.get("reason") == "one-shot latch is already set") and ok
	var routing_bb := Blackboard.new()
	routing_bb.define(&"branch", &"local", 0)
	var routing_engine := RuleEngine.new(routing_bb, {},
		func(_seconds: float) -> Signal: return clock_tick)
	var routing_runs: Array[StringName] = []
	var route_a := Rule.new(&"route_a", &"route")
	var route_b := Rule.new(&"route_b", &"route")
	routing_engine.trace_event.connect(func(entry: Dictionary) -> void:
		if entry.get("kind") == "rule_started":
			routing_runs.append(StringName(entry.get("rule", ""))))
	routing_engine.rules = [route_a, route_b]
	routing_engine.fire(&"route")
	await process_frame
	await process_frame
	var default_multi_match := routing_runs == [&"route_a", &"route_b"]
	routing_runs.clear()
	routing_engine.trigger_routing[&"route"] = {"mode": TriggerRoutingData.Mode.FIRST_MATCH}
	routing_engine.fire(&"route")
	await process_frame
	await process_frame
	var first_match_only := routing_runs == [&"route_a"]
	routing_runs.clear()
	route_a.requires = [&"branch == 1"]
	route_b.requires = [&"branch == 0"]
	routing_engine.fire(&"route")
	await process_frame
	await process_frame
	var next_eligible_only := routing_runs == [&"route_b"]
	routing_runs.clear()
	route_b.requires.clear()
	routing_engine.trigger_routing[&"route"]["fallback_rule_id"] = &"route_b"
	routing_engine.fire(&"route")
	await process_frame
	await process_frame
	var fallback_only := routing_runs == [&"route_b"]
	ok = _check("routing defaults to multi-match and opt-in first-match evaluates fallback last",
		default_multi_match and first_match_only and next_eligible_only and fallback_only) and ok
	var route_data := TriggerRoutingData.new()
	route_data.trigger = &"route"
	route_data.mode = TriggerRoutingData.Mode.FIRST_MATCH
	route_data.fallback_rule_id = &"route_b"
	var order_definition := StageDefinition.new()
	var legacy_route_definition := StageDefinition.new()
	legacy_route_definition.trigger_routing = [{"trigger": "route",
		"mode": TriggerRoutingData.Mode.FIRST_MATCH, "fallback_rule_id": "route_b"}]
	legacy_route_definition._migrate()
	var order_first := RuleData.new()
	order_first.id = &"route_a"
	order_first.trigger = &"route"
	order_first.pos = Vector2(12, 34)
	order_first.has_pos = true
	var order_second := RuleData.new()
	order_second.id = &"route_b"
	order_second.trigger = &"route"
	order_second.pos = Vector2(56, 78)
	order_second.has_pos = true
	order_definition.rules = [order_first, order_second]
	order_definition.trigger_routing = [route_data]
	var invalid_route_draft := GraphDraft.new()
	invalid_route_draft.rules = [order_first.duplicate(true), order_second.duplicate(true)]
	var invalid_route := route_data.duplicate(true) as TriggerRoutingData
	invalid_route.fallback_rule_id = &"missing_rule"
	invalid_route_draft.trigger_routing = [invalid_route]
	RuleGraphReader.validate_resources(invalid_route_draft)
	var invalid_fallback_rejected := invalid_route_draft.errors.any(func(message: String) -> bool:
		return "fallback must be a rule listening to that trigger" in message)
	var routed_stage := Stage.new()
	routed_stage.definition = order_definition
	routed_stage.build()
	var compiled_routing: int = int(routed_stage.engine.trigger_routing.get(&"route", {}).get("mode", -1))
	routed_stage.engine.cancel_all()
	routed_stage.free()
	var order_draft := GraphDraft.new()
	order_draft.definition = order_definition
	order_draft.rules = [order_second.duplicate(true), order_first.duplicate(true)]
	order_draft.trigger_routing = [route_data.duplicate(true)]
	var before_layout := order_draft.rules.map(func(rule: RuleData) -> Vector2: return rule.pos)
	var order_snapshot := order_draft.snapshot()
	var restored_draft := GraphDraft.new()
	restored_draft.definition = order_definition
	restored_draft.restore(order_snapshot)
	var saved_order_definition := RuleGraphReader.make_definition(restored_draft)
	var order_history := CallboardHistoryScript.new()
	order_history.reset(order_snapshot)
	var history_draft := GraphDraft.new()
	history_draft.restore(order_snapshot)
	var swapped_rules := history_draft.rules.duplicate()
	swapped_rules.reverse()
	history_draft.rules = swapped_rules
	order_history.record(history_draft.snapshot())
	var undo_state := order_history.undo(history_draft.snapshot())
	var undo_draft := GraphDraft.new()
	undo_draft.restore(undo_state)
	var redo_state := order_history.redo(undo_draft.snapshot())
	var redo_draft := GraphDraft.new()
	redo_draft.restore(redo_state)
	var route_save_path := "user://routing_order_test.tres"
	var route_save_error := ResourceSaver.save(saved_order_definition, route_save_path)
	var loaded_order_definition := ResourceLoader.load(route_save_path, "", ResourceLoader.CACHE_MODE_IGNORE) as StageDefinition
	var route_round_trip: bool = route_save_error == OK and loaded_order_definition != null \
		and loaded_order_definition.rules[0].id == &"route_b" \
		and loaded_order_definition.trigger_routing[0].fallback_rule_id == &"route_b"
	if FileAccess.file_exists(route_save_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(route_save_path))
	ok = _check("same-trigger order and routing persist independently of graph positions and undo snapshots",
		restored_draft.rules[0].id == &"route_b"
		and restored_draft.trigger_routing.size() == 1
		and restored_draft.trigger_routing[0].fallback_rule_id == &"route_b"
		and saved_order_definition.rules[0].id == &"route_b"
		and saved_order_definition.trigger_routing[0].mode == TriggerRoutingData.Mode.FIRST_MATCH
		and legacy_route_definition.trigger_routing[0] is TriggerRoutingData
		and legacy_route_definition.trigger_routing[0].fallback_rule_id == &"route_b"
		and invalid_fallback_rejected
		and compiled_routing == TriggerRoutingData.Mode.FIRST_MATCH
		and saved_order_definition.rules.map(func(rule: RuleData) -> Vector2: return rule.pos) == before_layout
		and undo_draft.rules[0].id == &"route_b" and redo_draft.rules[0].id == &"route_a"
		and route_round_trip) and ok
	routing_engine.cancel_all()
	routing_engine = null
	routing_bb = null
	var attach_store := StageStateStore.new()
	var attach_stage := Stage.new()
	var attached_before_build := attach_store.attach(attach_stage, &"attach_before_build")
	var store_refs_injected := attached_before_build and attach_stage.state_store == attach_store
	attach_stage.build()
	var rejected_after_build := not attach_store.attach(attach_stage, &"attach_after_build")
	ok = _check("state store attaches before Stage build and rejects late attachment",
		store_refs_injected and rejected_after_build
		and attach_stage.stage_instance_id == &"attach_before_build"
		and not attach_store.stage_states.has(&"attach_after_build")) and ok
	attach_store.release_stage(attach_stage)
	attach_stage.free()
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
	_expect_error("Undeclared Blackboard key 'missing'")
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
	var extended_guards := Blackboard.new()
	extended_guards.define(&"sensor_active", &"local", false)
	extended_guards.define(&"override_enabled", &"local", true)
	extended_guards.define(&"completed_count", &"local", 5)
	extended_guards.define(&"required_count", &"local", 5)
	extended_guards.define(&"other_count", &"local", 6)
	extended_guards.define(&"named_mode", &"local", &"standby")
	extended_guards.define(&"text_mode", &"local", "standby")
	var grouped_guard := &"(sensor_active or override_enabled) and completed_count >= required_count"
	var extended_runtime := GuardExpression.evaluate(extended_guards, &"any(sensor_active, override_enabled)") \
		and GuardExpression.evaluate(extended_guards, grouped_guard) \
		and not GuardExpression.evaluate(extended_guards, &"(sensor_active or override_enabled) and completed_count > required_count") \
		and GuardExpression.evaluate(extended_guards, &"completed_count != other_count") \
		and GuardExpression.evaluate(extended_guards, &"named_mode == \"standby\"") \
		and GuardExpression.evaluate(extended_guards, &"named_mode == &\"standby\"") \
		and GuardExpression.evaluate(extended_guards, &"text_mode == named_mode") \
		and not GuardExpression.evaluate(extended_guards, &"named_mode > \"standby\"")
	var renamed_guard := GuardExpression.rename_key(String(grouped_guard), "required_count", "quota_required")
	var guard_refs := GuardExpression.referenced_keys(grouped_guard)
	var renamed_refs := GuardExpression.referenced_keys(StringName(renamed_guard))
	var grouped_wait := CoreVerbs.new(StepContext.new(extended_guards, null, null, Callable())).wait_until(grouped_guard)
	var rename_draft := GraphDraft.new()
	var rename_variable := VariableData.new()
	rename_variable.key = &"required_count"
	rename_variable.default_value = 5
	var rename_rule := RuleData.new()
	rename_rule.id = &"renamed_group_guard"
	rename_rule.requires = PackedStringArray([String(grouped_guard)])
	rename_draft.variables = [rename_variable]
	rename_draft.rules = [rename_rule]
	AuthoredData.rename_key(rename_draft, "required_count", "quota_required")
	ok = _check("integer payload and Blackboard comparisons preserve exact integer values", exact_ints) and ok
	ok = _check("float equality remains approximate and mixed numeric guards compare numerically", float_semantics) and ok
	ok = _check("guard expressions support any(), boolean grouping, key-to-key comparisons, and String/StringName equality",
		extended_runtime) and ok
	ok = _check("guard reference discovery and Blackboard renames traverse grouped and key-to-key expressions",
		guard_refs == [&"sensor_active", &"override_enabled", &"completed_count", &"required_count"]
		and renamed_refs == [&"sensor_active", &"override_enabled", &"completed_count", &"quota_required"]
		and GuardExpression.referenced_payload_fields(&"any(payload.action == \"confirm\", has(payload.count))") == [&"action", &"count"]
		and grouped_wait.reads == guard_refs
		and rename_variable.key == &"quota_required"
		and GuardExpression.referenced_keys(rename_rule.requires[0]).has(&"quota_required")) and ok
	var extended_rule := Rule.new(&"extended_guard_types", &"guard_check")
	extended_rule.requires = [grouped_guard, &"named_mode == \"standby\"", &"text_mode == named_mode"]
	extended_rule.steps = [Step.new(func(_c: Dictionary) -> void: pass)]
	var extended_type_validation := RuleValidator.check([extended_rule], extended_guards,
		[&"guard_check"], [&"sensor_active", &"override_enabled", &"completed_count",
		&"required_count", &"named_mode", &"text_mode"], {})
	var invalid_key_type_rule := Rule.new(&"invalid_key_operand", &"guard_check")
	invalid_key_type_rule.requires = [&"completed_count > text_mode"]
	invalid_key_type_rule.steps = [Step.new(func(_c: Dictionary) -> void: pass)]
	var invalid_key_type_problems := RuleValidator.check([invalid_key_type_rule], extended_guards,
		[&"guard_check"], [&"completed_count", &"text_mode"], {})
	ok = _check("guard validator accepts typed key-to-key and String/StringName comparisons",
		extended_type_validation.is_empty()) and ok
	ok = _check("guard validator rejects incompatible key-to-key operand types",
		invalid_key_type_problems.any(func(problem: String) -> bool: return "numeric Blackboard key" in problem)) and ok
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
	ok = await _test_queue() and ok
	ok = await _test_conditional_groups() and ok
	ok = await _test_random_groups() and ok
	ok = await _test_core_verb_branch_factories() and ok
	ok = _test_signal_callbacks_accept_arguments() and ok
	ok = _test_snap_to_marker() and ok
	ok = await _test_staging_tweens() and ok
	ok = await _test_staging_controls() and ok
	ok = _test_scene_lifecycle_verbs() and ok
	ok = await _test_playback_wait_exits() and ok
	ok = await _test_cancel_if_interrupts_a_wait() and ok
	ok = _test_shared_write_order() and ok
	ok = _test_emit_relay() and ok
	ok = _test_runtime_step_inputs() and ok
	ok = await _test_blackboard_toggle_reset() and ok
	ok = await _test_named_actor_states() and ok
	ok = await _test_authored_waits() and ok
	ok = await _test_gameplay_requests() and ok
	ok = await _test_stage_controls() and ok
	ok = _test_on_change_triggers() and ok
	ok = await _test_dispatch_limits_and_ancestry() and ok
	ok = _test_stage_dispatch_policy() and ok
	ok = _test_cross_stage_event_bus() and ok
	ok = _test_cross_stage_route_validation() and ok
	ok = _test_session_scope_reset() and ok
	ok = _test_retriggered_light() and ok
	ok = await _test_light_from_restarted_run() and ok
	ok = await _test_managed_stages_and_restoration() and ok
	ok = await _test_async_stage_loading() and ok
	ok = _test_trigger_groups() and ok
	ok = await _test_trigger_collision_settings() and ok
	ok = await _test_trigger_contact_events() and ok
	ok = _test_delivery_target() and ok
	ok = await _test_scenario_runner() and ok
	print("UNIT: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)

func _test_scenario_runner() -> bool:
	var stage := Stage.new()
	root.add_child(stage)
	stage.build()
	stage.define_local(&"completed", false)
	stage.define_local(&"use_first_branch", true)
	var clock = ScenarioClockScript.new()
	stage.engine.wait = clock.wait
	var rule := Rule.new(&"scenario_rule", &"begin")
	var received_payloads: Array[Dictionary] = []
	var mark_complete := Step.new(func(context: Dictionary) -> void:
		received_payloads.append(context.get("payload", {}).duplicate(true))
		stage.write_var(&"completed", true, &"scenario_rule"))
	mark_complete.delay = 1.0
	var unused_branch := Step.new(func(_context: Dictionary) -> void: pass)
	rule.steps.append(Step.conditional([&"use_first_branch"], [[mark_complete], [unused_branch]], 1))
	stage.engine.rules = [rule]
	var actions: Array[Dictionary] = [
		{"action": "call", "event": "begin", "payload": {"source": "scenario"}},
		{"action": "frames", "count": 2},
		{"action": "assert", "check": "pending_remaining", "rule": "scenario_rule", "equals": 1.0},
		{"action": "advance", "seconds": 1.0},
		{"action": "frames", "count": 2},
		{"action": "assert", "check": "var", "key": &"completed", "equals": true},
		{"action": "assert", "check": "rule_covered", "rule": &"scenario_rule"},
		{"action": "assert", "check": "branch_covered", "group": "scenario_rule:1", "branch": 1},
		{"action": "assert", "check": "trace_count", "kind": "rule_completed", "rule": "scenario_rule", "equals": 1},
		{"action": "teardown"},
	]
	var result: Dictionary = await ScenarioRunnerScript.run(stage, actions, clock)
	var passed: bool = bool(result.get("ok", false)) and bool(result.get("torn_down", false))
	stage.queue_free()
	await process_frame
	return _check("scenario runner dispatches payloads, fast-forwards waits, asserts state and coverage, and tears down",
		passed and result.get("errors", []).is_empty() and received_payloads == [{"source": "scenario"}])

func _test_snap_to_marker() -> bool:
	var stage := Stage.new()
	root.add_child(stage)
	var actor := Node3D.new()
	actor.name = "Actor"
	actor.position = Vector3(-3, 1, 2)
	stage.add_child(actor)
	var marker := Marker3D.new()
	marker.name = "ResolvedPose"
	marker.position = Vector3(4, 2, -1)
	marker.rotation = Vector3(0.1, 0.8, 0.0)
	stage.add_child(marker)
	var animation_player := AnimationPlayer.new()
	actor.add_child(animation_player)
	var library := AnimationLibrary.new()
	var resolve_animation := Animation.new()
	resolve_animation.length = 1.0
	library.add_animation(&"resolve", resolve_animation)
	animation_player.add_animation_library(&"", library)
	var factory := StagingVerbs.new(StepContext.new(Blackboard.new(), null, stage, Callable()))
	var step := factory.snap_to_marker(actor, marker, animation_player, &"resolve", 0.4)
	step.verb = &"snap_to_marker"
	step.args = [actor, marker, animation_player, &"resolve", 0.4]
	var validation := factory.validate_step(&"snap_actor", step, factory.context.bb)
	step.fn.call({})
	var snapped_pose: bool = actor.global_transform.is_equal_approx(marker.global_transform)
	var animation_selected: bool = animation_player.assigned_animation == &"resolve"
	var animation_paused: bool = not animation_player.is_playing()
	var animation_seek: bool = is_equal_approx(animation_player.current_animation_position, 0.4)
	var invalid := Step.new()
	invalid.verb = &"snap_to_marker"
	var wrong_marker := Node3D.new()
	invalid.args = [actor, wrong_marker, animation_player, &"missing", -1.0]
	var invalid_validation := factory.validate_step(&"bad_snap", invalid, factory.context.bb)
	var reports_target := invalid_validation.any(func(problem: String) -> bool: return "Marker3D" in problem)
	var reports_animation := invalid_validation.any(func(problem: String) -> bool: return "animation" in problem)
	var reports_time := invalid_validation.any(func(problem: String) -> bool: return "time must be finite and nonnegative" in problem)
	wrong_marker.free()
	root.remove_child(stage)
	stage.free()
	var ok := _check("snap_to_marker validates its authored target and optional pose",
		validation.is_empty())
	ok = _check("snap_to_marker copies the Marker3D world transform", snapped_pose) and ok
	ok = _check("snap_to_marker selects the resolved animation", animation_selected) and ok
	ok = _check("snap_to_marker pauses the resolved animation", animation_paused) and ok
	ok = _check("snap_to_marker seeks to the resolved animation time", animation_seek) and ok
	return _check("snap_to_marker validation rejects invalid markers, animation clips, and pose times",
		reports_target and reports_animation and reports_time) and ok

func _test_staging_tweens() -> bool:
	var stage := Stage.new()
	root.add_child(stage)
	var actor := Node3D.new()
	stage.add_child(actor)
	var destination := Node3D.new()
	destination.position = Vector3(2, 1, -3)
	stage.add_child(destination)
	var path := Path3D.new()
	path.curve = Curve3D.new()
	path.curve.add_point(Vector3.ZERO)
	path.curve.add_point(Vector3(3, 0, 0))
	stage.add_child(path)
	var factory := StagingVerbs.new(StepContext.new(Blackboard.new(), null, stage, Callable()))
	var move := factory.move_to(actor, destination, Vector3.ZERO, 0.03, Tween.TRANS_SINE, Tween.EASE_IN_OUT)
	await move.fn.call({})
	var moved := actor.global_position.is_equal_approx(destination.global_position)
	var rotate := factory.rotate_to(actor, Vector3(0, 0.7, 0), 0.03, true,
		Tween.TRANS_QUAD, Tween.EASE_OUT)
	await rotate.fn.call({})
	var rotated := is_equal_approx(actor.rotation.y, 0.7)
	var property := factory.tween_property(actor, ^"scale", Vector3(2, 3, 4), 0.03,
		true, Tween.TRANS_CUBIC, Tween.EASE_IN)
	property.verb = &"tween_property"
	property.args = [actor, ^"scale", Vector3(2, 3, 4), 0.03, true, Tween.TRANS_CUBIC, Tween.EASE_IN]
	var valid_property := factory.validate_step(&"scale_actor", property, factory.context.bb).is_empty()
	await property.fn.call({})
	var property_tweened := actor.scale.is_equal_approx(Vector3(2, 3, 4))
	var follow := factory.follow_path(actor, path, 0.03, true, true,
		Tween.TRANS_LINEAR, Tween.EASE_IN_OUT)
	await follow.fn.call({})
	var followed := actor.global_position.is_equal_approx(path.to_global(Vector3(3, 0, 0)))
	var final_path_sample := path.curve.sample_baked_with_rotation(path.curve.get_baked_length(), true, false)
	var oriented := actor.global_rotation.is_equal_approx(
		(path.global_transform.basis * final_path_sample.basis).get_euler())
	actor.global_position = Vector3(-10, 2, 6)
	var immediate := factory.follow_path(actor, path, 0.0)
	immediate.fn.call({})
	var immediate_path_snapped := actor.global_position.is_equal_approx(path.to_global(Vector3(3, 0, 0)))
	var invalid_property := not factory._tween_values_compatible(Vector3.ZERO, Color.WHITE)
	var invalid_property_step := Step.new()
	invalid_property_step.verb = &"tween_property"
	invalid_property_step.args = [actor, ^"scale", Color.WHITE, 0.03, true,
		Tween.TRANS_LINEAR, Tween.EASE_IN_OUT]
	var invalid_property_errors := factory.validate_step(&"bad_property", invalid_property_step,
		factory.context.bb)
	var invalid_property_reported := invalid_property_errors.any(func(problem: String) -> bool:
		return "value type is incompatible" in problem)
	destination.position = Vector3(12, -2, 5)
	var moving_away := factory.move_to(actor, destination, Vector3.ZERO, 0.15)
	moving_away.fn.call({})
	var path_override := factory.follow_path(actor, path, 0.03)
	await path_override.fn.call({})
	await create_timer(0.17).timeout
	var latest_path_wins := actor.global_position.is_equal_approx(path.to_global(Vector3(3, 0, 0)))
	destination.position = Vector3(-2, 4, 1)
	var superseded_move := factory.move_to(actor, destination, Vector3.ZERO, 0.15)
	superseded_move.fn.call({})
	var snap_move := factory.move_to(actor, destination, Vector3.ZERO, 0.0)
	snap_move.fn.call({})
	await create_timer(0.2).timeout
	var immediate_move_wins := actor.global_position.is_equal_approx(destination.global_position)
	root.remove_child(stage)
	stage.free()
	var ok := _check("move_to and rotate_to accept configurable easing", moved and rotated)
	ok = _check("typed property tween validates and interpolates a Vector3 property",
		valid_property and property_tweened) and ok
	ok = _check("follow_path interpolates position and orientation along Curve3D",
		followed and oriented) and ok
	ok = _check("generic property tween rejects incompatible value types",
		invalid_property and invalid_property_reported) and ok
	ok = _check("follow_path takes ownership from an older move_to tween", latest_path_wins) and ok
	ok = _check("zero-duration follow_path snaps to the path endpoint", immediate_path_snapped) and ok
	ok = _check("immediate move invalidates a previous position tween", immediate_move_wins) and ok
	return ok

func _test_staging_controls() -> bool:
	var stage := Stage.new()
	root.add_child(stage)
	var factory := StagingVerbs.new(StepContext.new(Blackboard.new(), null, stage, Callable()))
	var light := OmniLight3D.new()
	light.light_energy = 2.0
	stage.add_child(light)
	factory.set_light_color(light, Color(0.2, 0.4, 0.8)).fn.call({})
	factory.set_light_energy(light, 1.5).fn.call({})
	var color_set := light.light_color.is_equal_approx(Color(0.2, 0.4, 0.8))
	var energy_set := is_equal_approx(light.light_energy, 1.5)
	var flicker := factory.flicker_light(light, 0.1, 2.0, 0.02, 0.08)
	await flicker.fn.call({})
	var flicker_restored := is_equal_approx(light.light_energy, 1.5)
	var particles := CPUParticles3D.new()
	stage.add_child(particles)
	factory.restart_particles(particles).fn.call({})
	var particles_restarted := particles.emitting
	var audio := AudioStreamPlayer.new()
	stage.add_child(audio)
	factory.set_audio_pitch(audio, 1.5).fn.call({})
	factory.set_audio_bus(audio, &"Master").fn.call({})
	factory.stop_audio(audio).fn.call({})
	var audio_configured := is_equal_approx(audio.pitch_scale, 1.5) and audio.bus == "Master" and not audio.playing
	var shader := Shader.new()
	shader.code = "shader_type spatial; uniform float glow_strength = 0.0; void fragment() { ALBEDO = vec3(glow_strength); }"
	var material := ShaderMaterial.new()
	material.shader = shader
	factory.set_shader_parameter(material, &"glow_strength", 0.75).fn.call({})
	var shader_set := is_equal_approx(float(material.get_shader_parameter(&"glow_strength")), 0.75)
	var animation_player := AnimationPlayer.new()
	stage.add_child(animation_player)
	var library := AnimationLibrary.new()
	var animation := Animation.new()
	animation.length = 0.2
	library.add_animation(&"resolve", animation)
	animation_player.add_animation_library(&"", library)
	var play_animation := factory.play_animation(animation_player, &"resolve", false, 0.0, 0.05, 1.5)
	play_animation.fn.call({})
	factory.set_animation_speed(animation_player, 0.75).fn.call({})
	var animation_controls := animation_player.assigned_animation == &"resolve" \
		and is_equal_approx(animation_player.speed_scale, 0.75)
	var valid_shader_step := factory.set_shader_parameter(material, &"glow_strength", 1.0)
	valid_shader_step.verb = &"set_shader_parameter"
	valid_shader_step.args = [material, &"glow_strength", 1.0]
	var shader_validation := factory.validate_step(&"glow", valid_shader_step, factory.context.bb).is_empty()
	var invalid_shader_step := Step.new()
	invalid_shader_step.verb = &"set_shader_parameter"
	invalid_shader_step.args = [material, &"missing_uniform", 1.0]
	var shader_rejected := factory.validate_step(&"bad_glow", invalid_shader_step,
		factory.context.bb).any(func(problem: String) -> bool: return "was not found" in problem)
	var invalid_pitch_step := Step.new()
	invalid_pitch_step.verb = &"set_audio_pitch"
	invalid_pitch_step.args = [audio, 0.0]
	var pitch_rejected := factory.validate_step(&"bad_pitch", invalid_pitch_step,
		factory.context.bb).any(func(problem: String) -> bool: return "pitch must be finite" in problem)
	var invalid_flicker_step := Step.new()
	invalid_flicker_step.verb = &"flicker_light"
	invalid_flicker_step.args = [light, 2.0, 1.0, 0.0, 0.0]
	var flicker_rejected := factory.validate_step(&"bad_flicker", invalid_flicker_step,
		factory.context.bb).size() >= 2
	root.remove_child(stage)
	stage.free()
	var ok := _check("light color and energy setters validate and apply", color_set and energy_set)
	ok = _check("light flicker restores its original energy after finishing", flicker_restored) and ok
	ok = _check("restart_particles restarts a CPU particle emitter", particles_restarted) and ok
	ok = _check("audio stop, pitch, and bus controls apply", audio_configured) and ok
	ok = _check("shader parameter setter checks and applies declared uniforms",
		shader_set and shader_validation and shader_rejected) and ok
	ok = _check("audio pitch and flicker validators reject invalid settings",
		pitch_rejected and flicker_rejected) and ok
	return _check("AnimationPlayer speed, custom playback speed, and blend settings apply",
		animation_controls) and ok

func _test_scene_lifecycle_verbs() -> bool:
	var stage := Stage.new()
	root.add_child(stage)
	var parent := Node3D.new()
	parent.name = "OriginalParent"
	stage.add_child(parent)
	var destination := Node3D.new()
	destination.position = Vector3(12, 1, -4)
	stage.add_child(destination)
	var template := Node3D.new()
	template.name = "SpawnedProp"
	template.position = Vector3(1, 0, 0)
	var packed_scene := PackedScene.new()
	var packed := packed_scene.pack(template) == OK
	template.free()
	var factory := StagingVerbs.new(StepContext.new(Blackboard.new(), null, stage, Callable()))
	var spawn := factory.spawn(packed_scene, parent, stage,
		Transform3D(Basis.IDENTITY, Vector3(3, 2, 1)))
	spawn.verb = &"spawn"
	spawn.args = [packed_scene, parent, stage, Transform3D(Basis.IDENTITY, Vector3(3, 2, 1))]
	var spawn_valid := factory.validate_step(&"spawn_prop", spawn, factory.context.bb).is_empty()
	spawn.fn.call({})
	var spawned := parent.get_node_or_null("SpawnedProp") as Node3D
	var spawned_with_owner := spawned != null and spawned.owner == stage \
		and spawned.position.is_equal_approx(Vector3(3, 2, 1))
	var original_world := spawned.global_transform if spawned != null else Transform3D.IDENTITY
	var reparent := factory.reparent(spawned, destination, stage, stage, true)
	reparent.verb = &"reparent"
	reparent.args = [spawned, destination, stage, stage, true]
	var reparent_valid := factory.validate_step(&"move_prop", reparent, factory.context.bb).is_empty()
	reparent.fn.call({})
	var world_preserved := spawned.get_parent() == destination \
		and spawned.owner == stage and spawned.global_transform.is_equal_approx(original_world)
	var detached_transform := spawned.global_transform
	var detach := factory.despawn(spawned, stage, false, true)
	detach.verb = &"despawn"
	detach.args = [spawned, stage, false, true]
	var detach_valid := factory.validate_step(&"detach_prop", detach, factory.context.bb).is_empty()
	detach.fn.call({})
	var detached := spawned.get_parent() == null and spawned.owner == null \
		and spawned.transform.is_equal_approx(detached_transform)
	var second_spawn := factory.spawn(packed_scene, parent, stage)
	second_spawn.fn.call({})
	var queued_node := parent.get_node_or_null("SpawnedProp2") as Node3D
	if queued_node == null:
		for child in parent.get_children():
			if child != spawned:
				queued_node = child as Node3D
	var destroy := factory.despawn(queued_node, stage)
	destroy.fn.call({})
	var queued_for_deletion := queued_node != null and queued_node.is_queued_for_deletion()
	var mismatch := factory.reparent(spawned, destination, stage, stage, true)
	mismatch.verb = &"reparent"
	mismatch.args = [spawned, destination, stage, stage, true]
	var mismatch_reported := factory.validate_step(&"wrong_owner", mismatch,
		factory.context.bb).any(func(problem: String) -> bool: return "expected owner" in problem)
	if is_instance_valid(spawned):
		spawned.free()
	root.remove_child(stage)
	stage.free()
	var ok := _check("spawn validates a PackedScene and assigns explicit ownership/local transform",
		packed and spawn_valid and spawned_with_owner)
	ok = _check("reparent preserves the global transform and assigns the requested owner",
		reparent_valid and world_preserved) and ok
	ok = _check("despawn can detach while preserving global transform and clearing invalid ownership",
		detach_valid and detached) and ok
	ok = _check("despawn can queue an owned node for deletion", queued_for_deletion) and ok
	return _check("reparent validation rejects an unexpected current owner", mismatch_reported) and ok

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

func _test_trigger_groups() -> bool:
	var trigger := TriggerArea.new()
	var player := Node3D.new()
	player.add_to_group(&"Player")
	var companion := Node3D.new()
	companion.add_to_group(&"Companion")
	var prop := Node3D.new()
	prop.add_to_group(&"MovableProp")
	var projectile := Node3D.new()
	projectile.add_to_group(&"Projectile")
	var vehicle := Node3D.new()
	vehicle.add_to_group(&"Vehicle")
	var unrelated := Node3D.new()
	var default_groups_match := (
		trigger._matches_trigger_groups(player)
		and trigger._matches_trigger_groups(companion)
	)
	var defaults_preserved := trigger.trigger_groups == [&"Player", &"Companion"]
	trigger.trigger_groups = [&"MovableProp", &"Projectile", &"Vehicle"]
	var configured_groups_match := (
		trigger._matches_trigger_groups(prop)
		and trigger._matches_trigger_groups(projectile)
		and trigger._matches_trigger_groups(vehicle)
	)
	var unrelated_rejected := not trigger._matches_trigger_groups(unrelated)
	trigger.trigger_groups.clear()
	var empty_filter_accepts_all := trigger._matches_trigger_groups(unrelated)
	trigger.free()
	player.free()
	companion.free()
	prop.free()
	projectile.free()
	vehicle.free()
	unrelated.free()
	return _check("TriggerArea ENTER filters configurable body groups, preserves Player/Companion defaults, and accepts all groups when unfiltered",
		default_groups_match and defaults_preserved and configured_groups_match
		and unrelated_rejected and empty_filter_accepts_all)

func _test_trigger_collision_settings() -> bool:
	var defaults := TriggerArea.new()
	var default_values_preserved := (
		defaults.collision_layer == StageCollisionLayers.TRIGGER
		and defaults.collision_mask == (StageCollisionLayers.PLAYER | StageCollisionLayers.COMPANION)
	)
	root.add_child(defaults)
	var authored := TriggerArea.new()
	authored.collision_layer = 1 << 5
	authored.collision_mask = 1 << 6
	root.add_child(authored)
	var overridden := TriggerArea.new()
	overridden.collision_layer = 1 << 7
	overridden.collision_mask = 1 << 8
	overridden.collision_mask_override = 0
	root.add_child(overridden)
	await process_frame
	var scene_settings_preserved := (
		authored.collision_layer == (1 << 5)
		and authored.collision_mask == (1 << 6)
	)
	var explicit_zero_override_applied := (
		overridden.collision_layer == (1 << 7)
		and overridden.collision_mask == 0
	)
	defaults.free()
	authored.free()
	overridden.free()
	return _check("TriggerArea keeps legacy defaults, honors scene collision settings, and applies an explicit zero mask override",
		default_values_preserved and scene_settings_preserved and explicit_zero_override_applied)

func _test_trigger_contact_events() -> bool:
	var definition := StageDefinition.new()
	definition.managed_lifecycle = true
	definition.external_calls = PackedStringArray(["arrive", "entered", "exited"])
	var stage := Stage.new()
	stage.definition = definition
	root.add_child(stage)
	await process_frame
	var received: Array[Dictionary] = []
	var enter_rule := Rule.new(&"capture_enter", &"entered")
	enter_rule.steps.append(Step.new(func(context: Dictionary) -> void:
		received.append({"event": "entered", "payload": context.get("payload", {}).duplicate(true)})
	))
	var exit_rule := Rule.new(&"capture_exit", &"exited")
	exit_rule.steps.append(Step.new(func(context: Dictionary) -> void:
		received.append({"event": "exited", "payload": context.get("payload", {}).duplicate(true)})
	))
	stage.engine.rules.append_array([enter_rule, exit_rule])
	var trigger := TriggerArea.new()
	trigger.event = &"entered"
	trigger.exit_event = &"exited"
	trigger.trigger_groups.clear()
	trigger.ctx["body"] = {"forged": true}
	stage.add_child(trigger)
	var body := Node3D.new()
	body.name = "DeliveryCart"
	body.add_to_group(&"Vehicle")
	root.add_child(body)
	stage.activate()
	trigger._on_body_entered(body)
	trigger._on_body_exited(body)
	await process_frame
	var body_data: Dictionary = received[0].get("payload", {}).get("body", {}) if received.size() >= 2 else {}
	var paired_events_include_body_metadata: bool = (
		received.size() == 2
		and received[0].get("event") == "entered"
		and received[1].get("event") == "exited"
		and body_data.get("name") == "DeliveryCart"
		and body_data.get("path") == String(body.get_path())
		and body_data.get("instance_id") == body.get_instance_id()
		and body_data.get("groups", []).has(&"Vehicle")
		and not body_data.has("forged")
	)
	stage.deactivate()
	trigger._on_body_entered(body)
	stage.activate()
	trigger._on_body_exited(body)
	await process_frame
	var dormant_contact_not_replayed := received.size() == 2
	stage.queue_free()
	body.queue_free()
	await process_frame
	return _check("TriggerArea sends body metadata with paired enter/exit Calls and does not replay a dormant contact on exit",
		paired_events_include_body_metadata and dormant_contact_not_replayed)

func _test_delivery_target() -> bool:
	var target = DeliveryTargetScript.new()
	target.mode = TriggerArea.Mode.INTERACT
	target.event = &"item_delivered"
	target.rejected_event = &"item_rejected"
	var accepted_item_ids: Array[StringName] = [&"blue_crystal"]
	target.accepted_item_ids = accepted_item_ids
	target.capacity = 1
	var actor := Node3D.new()
	actor.name = "Carrier"
	var inventory := {"held": &"red_token", "consumed": 0}
	var provider := func(_actor: Node) -> Variant: return inventory["held"]
	var consume := func(_actor: Node, item_id: StringName) -> bool:
		if inventory["held"] != item_id:
			return false
		inventory["consumed"] += 1
		inventory["held"] = &""
		return true
	var return_item := func(_actor: Node, item_id: StringName) -> bool:
		if not StringName(inventory["held"]).is_empty():
			return false
		inventory["held"] = item_id
		return true
	target.set_inventory_adapter(provider, consume, return_item)
	root.add_child(actor)
	root.add_child(target)
	var wrong_item := target.interact(actor)
	var wrong_item_rejected: bool = not wrong_item.get("accepted", true) \
		and wrong_item.get("event") == &"item_rejected" \
		and wrong_item.get("payload", {}).get("reason") == "wrong_item" \
		and inventory["held"] == &"red_token" and inventory["consumed"] == 0
	inventory["held"] = &"blue_crystal"
	var accepted_delivery := target.interact(actor)
	var delivery_id := int(accepted_delivery.get("payload", {}).get("delivery_id", -1))
	var accepted_once: bool = accepted_delivery.get("accepted", false) \
		and accepted_delivery.get("event") == &"item_delivered" \
		and accepted_delivery.get("payload", {}).get("item_id") == "blue_crystal" \
		and delivery_id > 0 and inventory["held"].is_empty() \
		and inventory["consumed"] == 1 and target.delivered_count == 1
	inventory["held"] = &"blue_crystal"
	var full_rejected: bool = not target.interact(actor).get("accepted", true) \
		and inventory["consumed"] == 1 and target.delivered_count == 1
	var blocked_return_preserves_delivery: bool = not target.return_delivery(delivery_id, actor) \
		and target.delivered_count == 1
	inventory["held"] = &""
	var returned := target.return_delivery(delivery_id, actor)
	var return_released_capacity: bool = returned and inventory["held"] == &"blue_crystal" \
		and target.delivered_count == 0
	var second_delivery := target.interact(actor)
	var exactly_once_per_attempt: bool = second_delivery.get("accepted", false) \
		and inventory["consumed"] == 2 and target.delivered_count == 1
	actor.free()
	target.free()
	var ok := _check("DeliveryTarget rejects a wrong item without consuming it", wrong_item_rejected)
	ok = _check("DeliveryTarget accepts and consumes the configured held item once", accepted_once) and ok
	ok = _check("DeliveryTarget rejects repeated attempts after capacity is reached without consuming again",
		full_rejected) and ok
	ok = _check("DeliveryTarget retains the delivery reservation when the host cannot return the item yet",
		blocked_return_preserves_delivery) and ok
	ok = _check("DeliveryTarget can return an accepted item and release its capacity", return_released_capacity) and ok
	return _check("DeliveryTarget accepts a new delivery after a successful return",
		exactly_once_per_attempt) and ok

func _test_session_scope_reset() -> bool:
	var definition := StageDefinition.new()
	var session := VariableData.new()
	session.key = &"noise_floor"
	session.scope = "session"
	session.default_value = 0.25
	definition.variables = [session]
	var store := StageStateStore.new()
	var first := Stage.new()
	first.definition = definition
	var attached := store.attach(first, &"session_stage")
	first.build()
	var changed: Array[Dictionary] = []
	first.write_var(&"noise_floor", 0.8, &"night_event")
	first.write_var(&"noise_floor", 0.8, &"night_event")
	var persisted_across_reload: bool = store.session_values.get(&"noise_floor") == 0.8
	store.release_stage(first)
	first.free()
	var second := Stage.new()
	second.definition = definition
	var reattached := store.attach(second, &"session_stage")
	second.build()
	second.bb.value_changed.connect(func(key: StringName, previous: Variant, value: Variant,
			scope: StringName, writer: StringName, _context: Dictionary) -> void:
		changed.append({"key": key, "previous": previous, "value": value,
			"scope": scope, "writer": writer}))
	var survives_reload: bool = second.get_var(&"noise_floor") == 0.8
	second.write_var(&"noise_floor", 0.9, &"night_event")
	store.state_for(&"session_stage")["saved"][&"progress"] = 7
	store.state_for(&"session_stage")["fired"][&"once"] = true
	store.reset_session()
	var reset_only_session: bool = second.get_var(&"noise_floor") == 0.25 \
		and store.state_for(&"session_stage")["saved"].get(&"progress") == 7 \
		and store.state_for(&"session_stage")["fired"].get(&"once") == true \
		and changed.size() == 2 and changed[0]["scope"] == &"session" \
		and changed[1]["scope"] == &"session" and changed[1]["writer"] == &"session_reset"
	store.release_stage(second)
	second.free()
	return _check("Session values survive Stage reloads and reset to defaults without clearing saved progress or latches",
		attached and reattached and persisted_across_reload and survives_reload and reset_only_session)

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
	_expect_error("Callboard stopped event depth")
	cycle_engine.fire(&"relay:a")
	return (_check("emit_relay selects/remaps fields and exposes its relay argument in step traces",
		mapped_payload and relay_metadata) \
		and _check("emit_relay payload mappings validate source and destination schema types",
		valid_types and mismatch_reported) \
		and _check("immediate relay cycles carry ancestry into the engine depth limit", cycle_stopped[0]))

func _test_blackboard_toggle_reset() -> bool:
	var saved_values := {&"saved_reset": true}
	var local_bb := Blackboard.new(saved_values)
	local_bb.define(&"local_flag", &"local", false)
	local_bb.define(&"saved_toggle", &"saved", false)
	local_bb.define(&"saved_reset", &"saved", false)
	local_bb.define(&"counter", &"local", 7)
	local_bb.define(&"label", &"local", "default")
	local_bb.define(&"items", &"local", [1, 2])
	local_bb.write(&"counter", 10, &"setup")
	local_bb.write(&"label", "changed", &"setup")
	local_bb.write(&"items", [9], &"setup")
	var engine := RuleEngine.new(local_bb, {}, Callable())
	var verbs := CoreVerbs.new(StepContext.new(local_bb, engine, null, Callable()))
	var local_toggle := verbs.toggle_var(&"local_flag")
	local_toggle.verb = &"toggle_var"
	local_toggle.args = [&"local_flag"]
	var toggle_saved := verbs.toggle_var(&"saved_toggle")
	toggle_saved.verb = &"toggle_var"
	toggle_saved.args = [&"saved_toggle"]
	var reset_saved := verbs.reset_var(&"saved_reset")
	reset_saved.verb = &"reset_var"
	reset_saved.args = [&"saved_reset"]
	var reset_counter := verbs.reset_var(&"counter")
	reset_counter.verb = &"reset_var"
	reset_counter.args = [&"counter"]
	var reset_label := verbs.reset_var(&"label")
	reset_label.verb = &"reset_var"
	reset_label.args = [&"label"]
	var reset_items := verbs.reset_var(&"items")
	reset_items.verb = &"reset_var"
	reset_items.args = [&"items"]
	var local_rule := Rule.new(&"state_ops", &"state_ops")
	local_rule.steps = [local_toggle, toggle_saved, reset_saved, reset_counter, reset_label, reset_items]
	engine.rules = [local_rule]
	var changes: Array[Dictionary] = []
	local_bb.value_changed.connect(func(key: StringName, previous: Variant, value: Variant,
			scope: StringName, writer: StringName, _dispatch: Dictionary) -> void:
		changes.append({"key": key, "previous": previous, "value": value,
			"scope": scope, "writer": writer}))
	engine.fire(&"state_ops")
	await process_frame
	var local_state_ok: bool = local_bb.get_var(&"local_flag") == true \
		and local_bb.get_var(&"saved_toggle") == true \
		and local_bb.get_var(&"saved_reset") == false \
		and saved_values[&"saved_toggle"] == true and saved_values[&"saved_reset"] == false \
		and local_bb.get_var(&"counter") == 7 \
		and local_bb.get_var(&"label") == "default" \
		and local_bb.get_var(&"items") == [1, 2]
	var writer_and_scope_ok: bool = local_bb.last_writers.get(&"local_flag") == &"rule:state_ops" \
		and local_bb.last_writers.get(&"saved_toggle") == &"rule:state_ops" \
		and local_bb.last_writers.get(&"saved_reset") == &"rule:state_ops" \
		and changes.any(func(change: Dictionary) -> bool:
			return change["key"] == &"saved_reset" and change["scope"] == &"saved" \
			and change["writer"] == &"rule:state_ops") \
		and local_toggle.reads == [&"local_flag"] and local_toggle.sets == [&"local_flag"] \
		and reset_counter.reads == [&"counter"] and reset_counter.sets == [&"counter"]
	var reset_only_engine := RuleEngine.new(local_bb, {}, Callable())
	var reset_only := CoreVerbs.new(StepContext.new(local_bb, reset_only_engine, null, Callable())).reset_var(&"saved_reset")
	reset_only.verb = &"reset_var"
	reset_only.args = [&"saved_reset"]
	var reset_only_rule := Rule.new(&"reset_only", &"reset_only")
	reset_only_rule.steps = [reset_only]
	reset_only_engine.rules = [reset_only_rule]
	var before_noop_reset := changes.filter(func(change: Dictionary) -> bool:
		return change["key"] == &"saved_reset").size()
	reset_only_engine.fire(&"reset_only")
	await process_frame
	var unchanged_reset_quiet := changes.filter(func(change: Dictionary) -> bool:
		return change["key"] == &"saved_reset").size() == before_noop_reset

	var store := StageStateStore.new()
	var shared_source := Blackboard.new({}, store.shared_values)
	var shared_receiver := Blackboard.new({}, store.shared_values)
	shared_source.define(&"shared_flag", &"shared", false, &"reset_test_flag")
	shared_receiver.define(&"shared_flag", &"shared", false, &"reset_test_flag")
	store.register_blackboard(shared_source)
	store.register_blackboard(shared_receiver)
	shared_source.write(&"shared_flag", true, &"setup")
	var shared_engine := RuleEngine.new(shared_source, {}, Callable())
	var shared_verbs := CoreVerbs.new(StepContext.new(shared_source, shared_engine, null, Callable()))
	var reset_shared := shared_verbs.reset_var(&"shared_flag")
	reset_shared.verb = &"reset_var"
	reset_shared.args = [&"shared_flag"]
	var toggle_shared := shared_verbs.toggle_var(&"shared_flag")
	toggle_shared.verb = &"toggle_var"
	toggle_shared.args = [&"shared_flag"]
	var shared_rule := Rule.new(&"shared_state_ops", &"shared_state_ops")
	shared_rule.steps = [reset_shared, toggle_shared]
	shared_engine.rules = [shared_rule]
	var receiver_changes: Array = []
	shared_receiver.value_changed.connect(func(key: StringName, _previous: Variant, value: Variant,
			scope: StringName, writer: StringName, _dispatch: Dictionary) -> void:
		if key == &"shared_flag":
			receiver_changes.append({"value": value, "scope": scope, "writer": writer}))
	shared_engine.fire(&"shared_state_ops")
	await process_frame
	var shared_state_ok: bool = store.shared_values[&"reset_test_flag"] == true \
		and shared_source.get_var(&"shared_flag") == true \
		and shared_receiver.get_var(&"shared_flag") == true \
		and receiver_changes.size() == 2 \
		and receiver_changes[0]["value"] == false and receiver_changes[1]["value"] == true \
		and receiver_changes.all(func(change: Dictionary) -> bool:
			return change["scope"] == &"shared" and change["writer"] == &"rule:shared_state_ops")
	store.unregister_blackboard(shared_source)
	store.unregister_blackboard(shared_receiver)

	var invalid_toggle := verbs.toggle_var(&"counter")
	invalid_toggle.verb = &"toggle_var"
	invalid_toggle.args = [&"counter"]
	var missing_reset := verbs.reset_var(&"missing")
	missing_reset.verb = &"reset_var"
	missing_reset.args = [&"missing"]
	var invalid_rule := Rule.new(&"invalid_state_ops", &"state_ops")
	invalid_rule.steps = [invalid_toggle, missing_reset]
	var validation := RuleValidator.check([invalid_rule], local_bb, [&"state_ops"], [&"counter"])
	return _check("toggle_var and reset_var use typed values and normal Local/Saved writes",
		local_state_ok and writer_and_scope_ok and unchanged_reset_quiet) \
		and _check("Shared toggle/reset operations commit in order and notify all registered Blackboards",
			shared_state_ok) \
		and _check("toggle_var and reset_var validator reject wrong-type and undeclared keys",
			validation.any(func(problem: String) -> bool: return "must be Boolean" in problem)
			and validation.any(func(problem: String) -> bool: return "not declared on the Blackboard" in problem))

func _test_runtime_step_inputs() -> bool:
	var stage_script := GDScript.new()
	stage_script.source_code = """extends Stage
var actor: Node3D
func _build_props() -> void:
	actor = Node3D.new()
	actor.name = "Actor"
	add_child(actor)
"""
	if stage_script.reload() != OK:
		return _check("runtime input fixture compiles", false)
	var definition := StageDefinition.new()
	definition.stage_script = stage_script
	definition.external_calls = PackedStringArray(["start"])
	for spec in [
		{"key": "total", "default": 0},
		{"key": "source", "default": 3},
		{"key": "relayed", "default": 0},
		{"key": "sourced", "default": 0},
	]:
		var variable := VariableData.new()
		variable.key = StringName(spec["key"])
		variable.default_value = spec["default"]
		definition.variables.append(variable)
	definition.payload_fields = [
		PayloadFieldData.from_dictionary({"event_id": "start", "key": "points", "type": "int"}),
		PayloadFieldData.from_dictionary({"event_id": "start", "key": "message", "type": "String"}),
		PayloadFieldData.from_dictionary({"event_id": "relay:paid", "key": "points", "type": "int"}),
	]
	var start_rule := RuleData.new()
	start_rule.id = &"dynamic_inputs"
	start_rule.trigger = &"start"
	for verb_args in [
		["add_var", ['&"total"', 'callboard_payload(&"points")']],
		["say", ["actor", 'callboard_payload(&"message")']],
		["set_var", ['&"sourced"', 'callboard_blackboard(&"source")']],
		["score", ['callboard_payload(&"points")']],
		["gameplay_event", ['&"host_ack"', '{"points": callboard_payload(&"points"), "source": callboard_blackboard(&"source")}']],
		["emit_relay", ['&"paid"', '{"points": callboard_payload(&"points")}']],
	]:
		var step := StepData.new()
		step.verb = StringName(verb_args[0])
		step.args = PackedStringArray(verb_args[1])
		start_rule.steps.append(step)
	var relay_listener := RuleData.new()
	relay_listener.id = &"read_paid"
	relay_listener.trigger = &"relay:paid"
	var relay_step := StepData.new()
	relay_step.verb = &"set_var"
	relay_step.args = PackedStringArray(['&"relayed"', 'callboard_payload(&"points")'])
	relay_listener.steps.append(relay_step)
	definition.rules = [start_rule, relay_listener]
	var stage := definition.instantiate()
	if stage == null:
		return _check("runtime input fixture instantiates", false)
	stage.build()
	var score_total := [0]
	var request_seen: Array[Dictionary] = []
	stage.scored.connect(func(points: int) -> void: score_total[0] += points)
	stage.gameplay_event.connect(func(_id: StringName, arguments: Dictionary) -> void:
		request_seen.append(arguments.duplicate(true)))
	var built_ok := stage.graph_errors.is_empty()
	if built_ok:
		stage.fire(&"start", {"points": 4, "message": "Hello at runtime"})
	var actor := stage.get("actor") as Node3D
	var label := actor.get_node_or_null(NodePath("CallboardSpeech")) as Label3D if actor != null else null
	var passed_payload: bool = (stage.get_var(&"total") == 4 and stage.get_var(&"relayed") == 4
		and stage.get_var(&"sourced") == 3
		and score_total[0] == 4 and label != null and label.text == "Hello at runtime"
		and request_seen == [{"points": 4, "source": 3}])
	if built_ok:
		stage.fire(&"start", {"message": "No points"})
	var missing_skips_only_affected_steps: bool = stage.get_var(&"total") == 4 and score_total[0] == 4
	if built_ok:
		stage.fire(&"start", {"points": "wrong type", "message": "Bad points"})
	var incompatible_skips_only_affected_steps: bool = stage.get_var(&"total") == 4 and score_total[0] == 4
	stage.free()
	return (_check("runtime input references resolve payload and Blackboard values across gameplay steps",
		built_ok and passed_payload) \
		and _check("missing or type-incompatible runtime inputs skip affected steps without blocking static arguments",
		missing_skips_only_affected_steps and incompatible_skips_only_affected_steps))

func _test_authored_waits() -> bool:
	var stage := Stage.new()
	stage.definition = StageDefinition.new()
	stage.definition.managed_lifecycle = true
	stage.definition.external_calls = PackedStringArray(["arrive", "start", "ack"])
	var ready := VariableData.new()
	ready.key = &"ready"
	ready.default_value = false
	stage.definition.variables = [ready]
	var start := RuleData.new()
	start.id = &"request"
	start.trigger = &"start"
	start.reentry = Rule.ReentryPolicy.RESTART
	start.emit = &"done"
	var acknowledgment := StepData.new()
	acknowledgment.verb = &"wait_for_call"
	acknowledgment.args = PackedStringArray(['&"ack"', ExprText.format_literal(&'payload.result == "ok"'), "1.0", '&"expired"'])
	var condition := StepData.new()
	condition.verb = &"wait_until"
	condition.args = PackedStringArray(['&"ready"', "1.0", '&"expired"'])
	start.steps = [acknowledgment, condition]
	stage.definition.rules = [start]
	for event in [&"relay:done", &"relay:expired", &"ack"]:
		var listener := RuleData.new()
		listener.id = StringName(String(event).trim_prefix("relay:"))
		listener.trigger = event
		var score := StepData.new()
		score.verb = &"score"
		score.args = PackedStringArray([str([&"done", &"expired", &"ack"].find(listener.id) + 1)])
		listener.steps = [score]
		stage.definition.rules.append(listener)
	root.add_child(stage)
	stage.build()
	var ok := _check("authored wait verbs compile with correctly indexed timeout relays", stage.graph_errors.is_empty()
		and stage.engine.rules[0].steps[0].emit_arg == 3 and stage.engine.rules[0].steps[1].emit_arg == 2)
	if not ok:
		stage.free()
		return false
	stage.engine.wait = func(_seconds: float) -> Signal: return clock_tick
	var scores: Array[int] = []
	var acknowledgments := [0]
	var outcomes: Array[String] = []
	stage.scored.connect(func(points: int) -> void:
		if points == 3:
			acknowledgments[0] += 1
		else:
			scores.append(points))
	stage.engine.trace_event.connect(func(entry: Dictionary) -> void:
		if entry.kind.begins_with("wait_"):
			outcomes.append(entry.kind))
	stage.activate()
	stage.fire(&"start")
	stage.fire(&"ack", {"result": "retry"})
	await process_frame
	ok = _check("unmatched host acknowledgment leaves the wait pending",
		outcomes.is_empty() and stage.engine.pending_snapshot().size() == 1) and ok
	stage.fire(&"ack", {"result": "ok"})
	ok = _check("acknowledgments dispatch ordinary listeners before a waiting rule resumes",
		acknowledgments[0] == 2 and outcomes.is_empty()) and ok
	clock_tick.emit()
	await process_frame
	stage.write_var(&"ready", true)
	await process_frame
	ok = _check("matching acknowledgment wins over a later timeout and condition wakes on a Blackboard write",
		scores == [1] and outcomes == ["wait_matched", "wait_matched"]
		and clock_tick.get_connections().is_empty()) and ok

	stage.fire(&"start")
	clock_tick.emit()
	stage.fire(&"ack", {"result": "ok"})
	await process_frame
	ok = _check("timeout wins if first and sends only the recovery relay",
		scores == [1, 2] and outcomes.back() == "wait_timed_out") and ok

	stage.fire(&"start")
	stage.fire(&"start")
	stage.fire(&"ack", {"result": "ok"})
	await process_frame
	ok = _check("Restart discards the cancelled subscription before arming its replacement",
		scores == [1, 2] and stage.engine.pending_snapshot().size() == 1) and ok
	stage.fire(&"ack", {"result": "ok"})
	await process_frame
	ok = _check("an already-true condition continues without another timer",
		scores == [1, 2, 1] and clock_tick.get_connections().is_empty()) and ok

	stage.fire(&"start")
	stage.deactivate()
	clock_tick.emit()
	stage.fire(&"ack", {"result": "ok"})
	await process_frame
	ok = _check("Stage deactivation disconnects the Call observer and clock without running recovery",
		stage.engine._event_received.get_connections().is_empty()
		and stage.engine.pending_snapshot().is_empty() and clock_tick.get_connections().is_empty()
		and scores == [1, 2, 1]) and ok
	stage.free()
	return ok

func _test_named_actor_states() -> bool:
	var saved_values := {&"actor_state": &"active"}
	var bb := Blackboard.new(saved_values)
	bb.define(&"actor_state", &"saved", &"idle")
	var initial_restored_state: bool = bb.get_var(&"actor_state") == &"active"
	var factory := CoreVerbs.new(StepContext.new(bb, null, null, Callable()))
	var step := factory.set_state(&"actor_state", &"resolved")
	step.verb = &"set_state"
	step.args = [&"actor_state", &"resolved"]
	var changes: Array[Dictionary] = []
	bb.value_changed.connect(func(key: StringName, previous: Variant, value: Variant,
			scope: StringName, writer: StringName, _context: Dictionary) -> void:
		changes.append({"key": key, "previous": previous, "value": value,
			"scope": scope, "writer": writer}))
	var rule := Rule.new(&"resolve_actor", &"resolve")
	rule.steps = [step]
	var engine := RuleEngine.new(bb, {}, Callable())
	engine.rules = [rule]
	engine.fire(&"resolve")
	await process_frame
	var valid_state: bool = bb.get_var(&"actor_state") == &"resolved"
	var normal_saved_write: bool = saved_values[&"actor_state"] == &"resolved" \
		and changes.size() == 1 and changes[0].previous == &"active" \
		and changes[0].value == &"resolved" and changes[0].scope == &"saved" \
		and changes[0].writer == &"rule:resolve_actor"
	var authored_stage := Stage.new()
	authored_stage.definition = StageDefinition.new()
	authored_stage.definition.external_calls = PackedStringArray(["set_actor_state"])
	var authored_variable := VariableData.new()
	authored_variable.key = &"actor_state"
	authored_variable.default_value = &"idle"
	authored_variable.scope = "saved"
	authored_stage.definition.variables = [authored_variable]
	var authored_rule := RuleData.new()
	authored_rule.id = &"set_actor_active"
	authored_rule.trigger = &"set_actor_state"
	var authored_step := StepData.new()
	authored_step.verb = &"set_state"
	authored_step.args = PackedStringArray(['&"actor_state"', '&"active"'])
	authored_rule.steps = [authored_step]
	authored_stage.definition.rules = [authored_rule]
	authored_stage.build()
	var authored_compiles: bool = authored_stage.graph_errors.is_empty() \
		and authored_stage.engine.rules.size() == 1 \
		and authored_stage.engine.rules[0].steps[0].verb == &"set_state"
	if authored_compiles:
		authored_stage.fire(&"set_actor_state")
		await process_frame
		authored_compiles = authored_stage.get_var(&"actor_state") == &"active"
	authored_stage.free()
	var validation_bb := Blackboard.new()
	validation_bb.define(&"actor_state", &"local", &"idle")
	validation_bb.define(&"not_state", &"local", false)
	var valid_rule := Rule.new(&"state_rule", &"state_change")
	valid_rule.steps = [factory.set_state(&"actor_state", &"active")]
	valid_rule.steps[0].verb = &"set_state"
	valid_rule.steps[0].args = [&"actor_state", &"active"]
	var invalid_type_rule := Rule.new(&"bad_state", &"state_change")
	var invalid_type_step := factory.set_state(&"not_state", &"active")
	invalid_type_step.verb = &"set_state"
	invalid_type_step.args = [&"not_state", &"active"]
	invalid_type_rule.steps = [invalid_type_step]
	var invalid_name_rule := Rule.new(&"empty_state", &"state_change")
	var invalid_name_step := factory.set_state(&"actor_state", &"")
	invalid_name_step.verb = &"set_state"
	invalid_name_step.args = [&"actor_state", &""]
	invalid_name_rule.steps = [invalid_name_step]
	var validation := RuleValidator.check([valid_rule], validation_bb, [&"state_change"], [])
	var type_validation := RuleValidator.check([invalid_type_rule], validation_bb, [&"state_change"], [])
	var name_validation := RuleValidator.check([invalid_name_rule], validation_bb, [&"state_change"], [])
	var invalid_initial_bb := Blackboard.new()
	invalid_initial_bb.define(&"actor_state", &"local", &"")
	var initial_validation := RuleValidator.check([valid_rule], invalid_initial_bb,
		[&"state_change"], [])
	var ambient := Rule.new(&"idle_ambient", &"arrive")
	var ambient_step := factory.repeat_emit(1.0)
	ambient_step.verb = &"repeat_emit"
	ambient_step.args = [1.0]
	ambient.steps = [ambient_step]
	var ambient_validation := RuleValidator.check([ambient], validation_bb, [&"arrive"], [])
	return _check("set_state writes named StringName states through the declared Saved scope",
		initial_restored_state and valid_state and normal_saved_write) \
		and _check("authored set_state steps compile from StageDefinition and update state",
			authored_compiles) \
		and _check("set_state validator requires a declared StringName key and non-empty state",
		validation.is_empty() and type_validation.any(func(problem: String) -> bool: return "must be StringName" in problem)
		and name_validation.any(func(problem: String) -> bool: return "non-empty StringName" in problem)
		and initial_validation.any(func(problem: String) -> bool: return "initial state" in problem)) \
		and _check("repeat_emit supports relay-free ambient waits without an unused-relay diagnostic",
		ambient_validation.is_empty())

func _test_stage_controls() -> bool:
	var adapter := StageControlAdapter.new()
	var host_input_lock := [false]
	var apply_host_input := func() -> void:
		host_input_lock[0] = adapter.is_input_locked()
	adapter.state_changed.connect(apply_host_input)
	var first := Stage.new()
	var second := Stage.new()
	first.control_adapter = adapter
	second.control_adapter = adapter
	root.add_child(first)
	root.add_child(second)
	await process_frame
	var target := Node3D.new()
	first.add_child(target)
	var first_verbs := first.verbs as StagingVerbs
	var second_verbs := second.verbs as StagingVerbs
	var catalog := RuntimeVerbCatalog.from_factory(first_verbs)
	var ok := _check("input and camera verbs are available to the board",
		not RuntimeVerbCatalog.find(catalog, "lock_input").is_empty()
		and not RuntimeVerbCatalog.find(catalog, "camera_focus").is_empty()
		and not RuntimeVerbCatalog.find(catalog, "camera_frame").is_empty()
		and not RuntimeVerbCatalog.find(catalog, "camera_shake").is_empty())
	first.define_local(&"stop", false)
	var base := Rule.new(&"base", &"base")
	base.cancel_if = [&"stop"]
	base.steps = [
		first_verbs.lock_input(), first_verbs.lock_input(),
		first_verbs.camera_focus(target, 0.2),
		first_verbs.wait_for_call(&"done"),
	]
	first.engine.rules.append(base)
	var overlay := Rule.new(&"overlay", &"overlay")
	overlay.reentry = Rule.ReentryPolicy.RESTART
	var overlay_branch: Array[Step] = [
		second_verbs.lock_input(),
		second_verbs.camera_frame(&"detail", 0.15),
		second_verbs.camera_shake(0.25, 8.0),
		second_verbs.wait_for_call(&"release"),
		second_verbs.release_input(), second_verbs.release_camera(),
		second_verbs.wait_for_call(&"done"),
	]
	var nested_branch: Array[Step] = [Step.parallel([overlay_branch], false)]
	overlay.steps = [Step.parallel([nested_branch])]
	second.engine.rules.append(overlay)
	first.fire(&"base")
	var base_shot := adapter.camera_request()
	ok = _check("focus targets a Stage prop and input locks are per channel",
		base_shot != null and base_shot.target == target and base_shot.blend_seconds == 0.2
		and host_input_lock[0] and not adapter.is_input_locked(&"menu")) and ok
	second.fire(&"overlay")
	var initial_overlay := adapter.camera_request()
	ok = _check("a nested unjoined branch retains independent shot and shake claims",
		initial_overlay != null and initial_overlay.shot == &"detail"
		and adapter.shake_request() != null and adapter.shake_request().frequency == 8.0) and ok
	second.fire(&"overlay")
	await process_frame
	await process_frame
	ok = _check("Restart replaces an unjoined camera owner without releasing another Stage's input",
		adapter.camera_request() != null and adapter.camera_request() != initial_overlay
		and adapter.camera_request().shot == &"detail" and adapter.is_input_locked()) and ok
	second.fire(&"release")
	await process_frame
	await process_frame
	ok = _check("explicit releases restore the previous shot and leave another owner's lock intact",
		adapter.camera_request() == base_shot and adapter.shake_request() == null
		and adapter.is_input_locked()) and ok
	first.write_var(&"stop", true)
	ok = _check("Cancel If immediately releases the last input lock and returns camera control",
		not host_input_lock[0] and adapter.camera_request() == null) and ok
	second.fire(&"overlay")
	await process_frame
	await process_frame
	second.free()
	ok = _check("Stage teardown releases input, focus and shake even with a branch waiting",
		not adapter.is_input_locked() and adapter.camera_request() == null
		and adapter.shake_request() == null) and ok

	first.write_var(&"stop", false)
	first.fire(&"base")
	first.fire(&"done")
	await process_frame
	await process_frame
	ok = _check("normal rule completion restores controls without explicit release steps",
		not adapter.is_input_locked() and adapter.camera_request() == null) and ok
	var timeout_rule := Rule.new(&"timeout", &"timeout")
	timeout_rule.steps = [
		first_verbs.lock_input(),
		first_verbs.camera_frame(&"wide"),
		first_verbs.wait_for_call(&"missing", &"", 0.01),
	]
	first.engine.rules.append(timeout_rule)
	first.fire(&"timeout")
	await create_timer(0.04).timeout
	await process_frame
	ok = _check("a timed-out wait restores the camera and releases input",
		not adapter.is_input_locked() and adapter.camera_request() == null) and ok
	first.free()
	adapter.state_changed.disconnect(apply_host_input)
	return ok

func _test_gameplay_requests() -> bool:
	var stage := Stage.new()
	root.add_child(stage)
	await process_frame
	var request_ids: Array[int] = []
	var request_arguments: Array[Dictionary] = []
	var request_finished: Array[Dictionary] = []
	var wait_registered := [false]
	var response_checks := {"invalid": false, "accepted": false, "duplicate": false, "rejected": false}
	stage.bb.define(&"request_accepted", &"local", false)
	var request_callback := func(request_id: int, event_id: StringName,
			arguments: Dictionary) -> void:
		request_ids.append(request_id)
		request_arguments.append(arguments.duplicate(true))
		wait_registered[0] = stage.engine.pending_snapshot().any(func(entry: Dictionary) -> bool:
			return entry.get("label", "").begins_with("host request "))
		if event_id == &"grant_score":
			response_checks["invalid"] = not stage.respond_gameplay_request(request_id, true,
				{&"score": "seven", &"multiplier": 2})
			response_checks["accepted"] = stage.respond_gameplay_request(request_id, true,
				{&"score": 7, &"multiplier": 2})
			response_checks["duplicate"] = not stage.respond_gameplay_request(request_id, false,
				{&"score": 8, &"multiplier": 2})
		elif event_id == &"deny_access":
			response_checks["rejected"] = stage.respond_gameplay_request(request_id, false,
				{&"score": 0, &"multiplier": 1})
	stage.gameplay_request.connect(request_callback)
	stage.gameplay_request_finished.connect(func(request_id: int, event_id: StringName,
			outcome: StringName, data: Dictionary) -> void:
		request_finished.append({"id": request_id, "event": event_id,
			"outcome": outcome, "data": data.duplicate(true)})
		if event_id in [&"grant_score", &"deny_access"]:
			stage.write_var(&"request_accepted", outcome == &"accepted", &"host"))
	var response_schema: Dictionary = {&"score": TYPE_INT, &"multiplier": TYPE_FLOAT}
	var authored_arguments: Dictionary = {"amount": 2}
	var factory := StagingVerbs.new(StepContext.new(stage.bb, stage.engine, stage, Callable()))
	var sync_step := factory.gameplay_request(&"grant_score", authored_arguments,
		0.0, response_schema)
	authored_arguments["amount"] = 99
	var sync_sequence_saw_ack := [false]
	var sync_rule := Rule.new(&"sync_host_request", &"start_sync_request")
	sync_rule.steps.append(sync_step)
	sync_rule.steps.append(Step.new(func(_context: Dictionary) -> void:
		sync_sequence_saw_ack[0] = stage.get_var(&"request_accepted")))
	stage.engine.rules.append(sync_rule)
	stage.engine.fire(&"start_sync_request")
	await process_frame
	await process_frame
	var sync_response: Dictionary = request_finished[0] if not request_finished.is_empty() else {}
	var sync_ack_captured: bool = request_ids.size() == 1 and request_ids[0] > 0 \
		and wait_registered[0] and request_arguments[0].get("amount") == 2 \
		and response_checks["invalid"] and response_checks["accepted"] \
		and response_checks["duplicate"] and sync_response.get("outcome") == &"accepted" \
		and sync_response.get("data", {}).get("score") == 7 \
		and typeof(sync_response.get("data", {}).get("multiplier")) == TYPE_FLOAT \
		and sync_sequence_saw_ack[0] \
		and not stage.engine.pending_snapshot().any(func(entry: Dictionary) -> bool:
			return entry.get("label", "").begins_with("host request "))
	var rejection_sequence_saw_result := [true]
	var rejection_rule := Rule.new(&"rejected_host_request", &"start_rejected_request")
	rejection_rule.steps.append(factory.gameplay_request(&"deny_access", {}, 0.0,
		response_schema))
	rejection_rule.steps.append(Step.new(func(_context: Dictionary) -> void:
		rejection_sequence_saw_result[0] = not stage.get_var(&"request_accepted")))
	stage.engine.rules.append(rejection_rule)
	stage.engine.fire(&"start_rejected_request")
	await process_frame
	await process_frame
	var rejected_response: Dictionary = request_finished[1] if request_finished.size() > 1 else {}
	var rejection_outcome_routed: bool = response_checks["rejected"] \
		and rejected_response.get("outcome") == &"rejected" \
		and rejected_response.get("data", {}).get("score") == 0 \
		and typeof(rejected_response.get("data", {}).get("multiplier")) == TYPE_FLOAT \
		and rejection_sequence_saw_result[0]

	var timeout_fired := [false]
	var timeout_listener := Rule.new(&"request_timeout_listener", &"relay:request_expired")
	timeout_listener.steps.append(Step.new(func(_context: Dictionary) -> void:
		timeout_fired[0] = true))
	stage.engine.rules.append(timeout_listener)
	var timeout_rule := Rule.new(&"timed_host_request", &"start_timed_request")
	timeout_rule.steps.append(factory.gameplay_request(&"slow_operation", {}, 0.02,
		{}, &"request_expired"))
	stage.engine.rules.append(timeout_rule)
	stage.engine.fire(&"start_timed_request")
	await create_timer(0.08).timeout
	await process_frame
	var timeout_id: int = request_ids[2] if request_ids.size() > 2 else -1
	var late_timeout_response_rejected: bool = timeout_id > 0 \
		and not stage.respond_gameplay_request(timeout_id, true, {})
	var timeout_recorded: bool = request_finished.any(func(entry: Dictionary) -> bool:
		return entry.get("id") == timeout_id and entry.get("outcome") == &"timed_out")

	var cancel_rule := Rule.new(&"cancelled_host_request", &"start_cancel_request")
	cancel_rule.steps.append(factory.gameplay_request(&"cancelled_operation"))
	stage.engine.rules.append(cancel_rule)
	stage.engine.fire(&"start_cancel_request")
	var cancel_id: int = request_ids[3] if request_ids.size() > 3 else -1
	stage.deactivate()
	await process_frame
	var cancellation_recorded: bool = request_finished.any(func(entry: Dictionary) -> bool:
		return entry.get("id") == cancel_id and entry.get("outcome") == &"cancelled")
	var late_cancel_response_rejected: bool = cancel_id > 0 \
		and not stage.respond_gameplay_request(cancel_id, true, {})
	var explicit_id_request := stage.reserve_gameplay_request(&"manual_request", {}, {}, 9001)
	var duplicate_explicit_id_rejected: bool = stage.reserve_gameplay_request(&"manual_request", {}, {}, 9001) == null
	var explicit_id_cancelled: bool = explicit_id_request != null \
		and stage.cancel_gameplay_request(9001, &"cancelled")
	var settled_explicit_id_not_reused: bool = stage.reserve_gameplay_request(&"manual_request", {}, {}, 9001) == null
	var ok: bool = _check("host requests register before emission, copy arguments, validate typed synchronous acknowledgments, and reject duplicates",
		sync_ack_captured)
	ok = _check("host request rejection outcomes reach host listeners before the rule sequence resumes",
		rejection_outcome_routed) and ok
	ok = _check("host request timeouts emit the timeout relay and reject late acknowledgments",
		timeout_fired[0] and timeout_recorded and late_timeout_response_rejected) and ok
	ok = _check("rule cancellation settles a pending host request and rejects its late acknowledgment",
		cancellation_recorded and late_cancel_response_rejected) and ok
	ok = _check("host request IDs can be supplied explicitly but cannot be duplicated or reused",
		duplicate_explicit_id_rejected and explicit_id_cancelled and settled_explicit_id_not_reused) and ok
	stage.queue_free()
	await process_frame
	return ok

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
	_expect_error("Callboard stopped event depth")
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
	_expect_error("Callboard stopped event depth")
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
	_expect_error("Callboard stopped event depth")
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
	_expect_error("Callboard stopped pending queue")
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
	_expect_error("Callboard stopped per-frame dispatch budget")
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
	_expect_error("rule 'partially_compiled' has an invalid step: missing_verb()")
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
		[&"selected_variant", "saved", 1],
		[&"garage_rotation", "saved", Vector3.ZERO],
		[&"lamp_energy", "saved", 2.5],
		[&"lamp_color", "saved", Color(0.25, 0.5, 0.75)],
		[&"ambience_playing", "saved", true],
		[&"dust_emitting", "saved", true],
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
	var binding_pose_only := StageRestorationBinding.new()
	binding_pose_only.key = &"delivered_skateboard"
	binding_pose_only.kind = StageRestorationBinding.Kind.POSE_ANIMATION
	binding_pose_only.target_path = NodePath("Buster/AnimationPlayer")
	binding_pose_only.animation_name = &"sleep"
	binding_pose_only.animation_time = 7.5
	var binding_door := StageRestorationBinding.new()
	binding_door.key = &"garage_door_transform"
	binding_door.kind = StageRestorationBinding.Kind.TRANSFORM
	binding_door.target_path = NodePath("GarageDoor")
	var binding_choice := StageRestorationBinding.new()
	binding_choice.key = &"selected_variant"
	binding_choice.kind = StageRestorationBinding.Kind.CHILD_INDEX
	binding_choice.target_path = NodePath("GiftVariant")
	binding_choice.child_choices = [NodePath("GiftVariant/RobotVariant"), NodePath("GiftVariant/SkateboardVariant")]
	var binding_rotation := StageRestorationBinding.new()
	binding_rotation.key = &"garage_rotation"
	binding_rotation.kind = StageRestorationBinding.Kind.PROPERTY
	binding_rotation.target_path = NodePath("GarageDoor")
	binding_rotation.property_name = &"rotation"
	var binding_energy := StageRestorationBinding.new()
	binding_energy.key = &"lamp_energy"
	binding_energy.kind = StageRestorationBinding.Kind.LIGHT_ENERGY
	binding_energy.target_path = NodePath("Lamp")
	var binding_color := StageRestorationBinding.new()
	binding_color.key = &"lamp_color"
	binding_color.kind = StageRestorationBinding.Kind.LIGHT_COLOR
	binding_color.target_path = NodePath("Lamp")
	var binding_audio := StageRestorationBinding.new()
	binding_audio.key = &"ambience_playing"
	binding_audio.kind = StageRestorationBinding.Kind.AUDIO_PLAYBACK
	binding_audio.target_path = NodePath("Ambience")
	var binding_particles := StageRestorationBinding.new()
	binding_particles.key = &"dust_emitting"
	binding_particles.kind = StageRestorationBinding.Kind.PARTICLE_EMITTING
	binding_particles.target_path = NodePath("Dust")
	definition.restoration_bindings.assign([binding_window, binding_skateboard_window, binding_pose, binding_pose_only, binding_door, binding_choice, binding_rotation, binding_energy, binding_color, binding_audio, binding_particles])

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
	var variant_root := Node3D.new()
	variant_root.name = "GiftVariant"
	template.add_child(variant_root)
	variant_root.owner = template
	for variant_name: String in ["RobotVariant", "SkateboardVariant"]:
		var variant_node := Node3D.new()
		variant_node.name = variant_name
		variant_root.add_child(variant_node)
		variant_node.owner = template
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
	var lamp := OmniLight3D.new()
	lamp.name = "Lamp"
	template.add_child(lamp)
	lamp.owner = template
	var ambience := AudioStreamPlayer.new()
	ambience.name = "Ambience"
	template.add_child(ambience)
	ambience.owner = template
	var dust := CPUParticles3D.new()
	dust.name = "Dust"
	template.add_child(dust)
	dust.owner = template
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
	var invalid_pose_only := StageRestorationBinding.new()
	invalid_pose_only.key = &"gifts_delivered"
	invalid_pose_only.kind = StageRestorationBinding.Kind.POSE_ANIMATION
	invalid_pose_only.target_path = NodePath("Buster/AnimationPlayer")
	invalid_pose_only.animation_name = &"missing_pose"
	var pose_errors := invalid_pose_only.validate(stage)
	ok = _check("standalone animation pose binding validates Boolean keys and animation names",
		pose_errors.any(func(problem: String) -> bool: return "must be Boolean" in problem)
		and pose_errors.any(func(problem: String) -> bool: return "animation 'missing_pose'" in problem)) and ok
	var invalid_property := StageRestorationBinding.new()
	invalid_property.key = &"gifts_delivered"
	invalid_property.kind = StageRestorationBinding.Kind.PROPERTY
	invalid_property.target_path = NodePath("GarageDoor")
	invalid_property.property_name = &"rotation"
	var property_errors := invalid_property.validate(stage)
	var binding_roundtrip := StageRestorationBinding.from_dictionary(binding_choice.to_dictionary())
	ok = _check("typed child choices and generic property bindings validate types and serialize settings",
		property_errors.any(func(problem: String) -> bool: return "type does not match" in problem)
		and binding_roundtrip.kind == StageRestorationBinding.Kind.CHILD_INDEX
		and binding_roundtrip.child_choices == binding_choice.child_choices) and ok
	var invalid_audio_replay := StageRestorationBinding.new()
	invalid_audio_replay.key = &"ambience_playing"
	invalid_audio_replay.kind = StageRestorationBinding.Kind.AUDIO_PLAYBACK
	invalid_audio_replay.target_path = NodePath("Ambience")
	invalid_audio_replay.replay_audio_on_restore = true
	var invalid_particles := StageRestorationBinding.new()
	invalid_particles.key = &"dust_emitting"
	invalid_particles.kind = StageRestorationBinding.Kind.PARTICLE_EMITTING
	invalid_particles.target_path = NodePath("Dust")
	(stage.get_node("Dust") as CPUParticles3D).one_shot = true
	var invalid_audio_problems := invalid_audio_replay.validate(stage)
	var invalid_particle_problems := invalid_particles.validate(stage)
	var audio_binding_roundtrip := StageRestorationBinding.from_dictionary(invalid_audio_replay.to_dictionary())
	ok = _check("audio replay requires an explicit stream and particle restoration rejects one-shot effects",
		invalid_audio_problems.any(func(problem: String) -> bool: return "no stream" in problem)
		and invalid_particle_problems.any(func(problem: String) -> bool: return "one_shot" in problem)
		and audio_binding_roundtrip.replay_audio_on_restore) and ok
	(stage.get_node("Dust") as CPUParticles3D).one_shot = false
	binding_energy.apply(stage)
	binding_color.apply(stage)
	binding_audio.apply(stage)
	binding_particles.apply(stage)
	var restored_lamp := stage.get_node("Lamp") as OmniLight3D
	ok = _check("light state and continuous particles restore while transient audio remains stopped by default",
		is_equal_approx(restored_lamp.light_energy, 2.5)
		and restored_lamp.light_color.is_equal_approx(Color(0.25, 0.5, 0.75))
		and not (stage.get_node("Ambience") as AudioStreamPlayer).is_playing()
		and (stage.get_node("Dust") as CPUParticles3D).emitting) and ok
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
	stage.write_var(&"selected_variant", 0)
	stage.write_var(&"garage_rotation", Vector3(0.1, 0.3, 0.6))
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
	var completed_garage := all_gifts_restored.get_node("GarageDoor") as Node3D
	var completed_robot_variant := all_gifts_restored.get_node("GiftVariant/RobotVariant") as Node3D
	var completed_skateboard_variant := all_gifts_restored.get_node("GiftVariant/SkateboardVariant") as Node3D
	ok = _check("each gift restores its own visual and the saved counter after the next reload",
		completed_robot_window.visible and completed_skateboard_window.visible
		and all_gifts_restored.get_var(&"gifts_delivered") == 2
		and completed_robot_variant.visible and not completed_skateboard_variant.visible
		and completed_garage.rotation.is_equal_approx(Vector3(0.1, 0.3, 0.6))
		and is_equal_approx((all_gifts_restored.get_node("Buster/Visual") as Node3D).position.y, 0.1875)
		and not (all_gifts_restored.get_node("Buster/AnimationPlayer") as AnimationPlayer).is_playing()) and ok
	store.unload_stage(all_gifts_restored)
	await process_frame
	return ok

func _test_cross_stage_event_bus() -> bool:
	var store := StageStateStore.new()
	var received: Dictionary = {&"stage_a": [], &"stage_b": [], &"stage_dormant": []}
	var received_paths: Dictionary = {&"stage_a": [], &"stage_b": [], &"stage_dormant": []}
	var delivery_order: Array[StringName] = []
	var stages: Dictionary = {}
	for instance_id: StringName in [&"stage_b", &"stage_a", &"stage_dormant"]:
		var definition := StageDefinition.new()
		definition.managed_lifecycle = true
		definition.external_calls = PackedStringArray(["sensor:activated", "system_overload"])
		definition.payload_fields = [
			PayloadFieldData.from_dictionary({"event_id": "sensor:activated", "key": "sensor_id", "type": "String"}),
			PayloadFieldData.from_dictionary({"event_id": "system_overload", "key": "severity", "type": "int"}),
		]
		if instance_id == &"stage_a":
			definition.external_calls.append(&"launch")
			definition.payload_fields.append(PayloadFieldData.from_dictionary({
				"event_id": "launch", "key": "sensor_id", "type": "String"}))
			var route_rule := RuleData.new()
			route_rule.id = &"route_sensor_activation"
			route_rule.trigger = &"launch"
			var route_step := StepData.new()
			route_step.verb = &"emit_cross_stage"
			route_step.args = PackedStringArray([
				'&"sensor:activated"',
				'{"sensor_id": callboard_payload(&"sensor_id")}',
				'&"stage_b"',
			])
			route_rule.steps.append(route_step)
			definition.rules = [route_rule]
		var stage := Stage.new()
		stage.definition = definition
		if not store.attach(stage, instance_id):
			return _check("cross-Stage events can be tested with attached Stages", false)
		stage.build()
		stage.is_active = instance_id != &"stage_dormant"
		for event_id: StringName in [&"sensor:activated", &"system_overload"]:
			var listener := Rule.new(StringName("listen_" + String(instance_id) + "_" + String(event_id)), event_id)
			listener.steps.append(Step.new(func(context: Dictionary) -> void:
				received[instance_id].append(context.get("payload", {}).duplicate(true))
				received_paths[instance_id].append(context["_callboard"]["run"]["context"]["path"].duplicate())
				delivery_order.append(instance_id)))
			stage.engine.rules.append(listener)
		stages[instance_id] = stage
	var stage_a: Stage = stages[&"stage_a"]
	var stage_b: Stage = stages[&"stage_b"]
	var target_delivery_count := store.broadcast_event(&"sensor:activated",
		{"sensor_id": "west"}, &"stage_b")
	var targeted_delivery: bool = target_delivery_count == 1 \
		and received[&"stage_a"].is_empty() \
		and received[&"stage_b"] == [{"sensor_id": "west"}] \
		and received[&"stage_dormant"].is_empty()
	var broadcast_count := store.broadcast_event(&"system_overload", {"severity": 3})
	var broadcast_delivery: bool = broadcast_count == 2 \
		and received[&"stage_a"] == [{"severity": 3}] \
		and received[&"stage_b"].size() == 2 \
		and received[&"stage_b"][1] == {"severity": 3} \
		and received[&"stage_dormant"].is_empty()
	var wrong_type_count := store.broadcast_event(&"system_overload", {"severity": "high"}, &"stage_b")
	var bad_payload_rejected: bool = wrong_type_count == 0 and received[&"stage_b"].size() == 2
	var cross_stage_traces: Array[Dictionary] = []
	stage_a.engine.trace_event.connect(func(entry: Dictionary) -> void:
		if entry.get("kind") == "cross_stage_sent":
			cross_stage_traces.append(entry))
	stage_a.fire(&"launch", {"sensor_id": "east"})
	var authored_verb_delivered: bool = received[&"stage_b"].size() == 3 \
		and received[&"stage_b"][2] == {"sensor_id": "east"} \
		and received_paths[&"stage_b"][2] == ["launch", "sensor:activated"] \
		and cross_stage_traces.size() == 1 \
		and cross_stage_traces[0].get("detail", "").contains("target=stage_b; recipients=1")
	store._cross_stage_dispatch_frame = Engine.get_process_frames()
	store._cross_stage_dispatches_this_frame = StageStateStore.MAX_CROSS_STAGE_DISPATCHES_PER_FRAME
	var budget_rejected: bool = store.broadcast_event(&"sensor:activated",
		{"sensor_id": "over_budget"}, &"stage_b") == 0 and received[&"stage_b"].size() == 3
	store.release_stage(stage_b)
	var unloaded_is_not_queued: bool = store.broadcast_event(&"sensor:activated",
		{"sensor_id": "late"}, &"stage_b") == 0 and received[&"stage_b"].size() == 3
	var ok := _check("store routes a typed event to its requested loaded Stage and skips dormant recipients",
		targeted_delivery) \
		and _check("store broadcasts in stable ID order to active Stages only",
			broadcast_delivery and received[&"stage_a"][0] == {"severity": 3}
			and delivery_order[1] == &"stage_a" and delivery_order[2] == &"stage_b") \
		and _check("cross-Stage delivery rejects fields that violate the recipient payload contract",
			bad_payload_rejected) \
		and _check("emit_cross_stage sends its payload through the source Stage's store",
			authored_verb_delivered) \
		and _check("store cross-Stage delivery obeys its per-frame dispatch budget",
			budget_rejected) \
		and _check("unloaded recipients do not receive or queue cross-Stage events",
			unloaded_is_not_queued)
	for instance_id: StringName in stages:
		var stage: Stage = stages[instance_id]
		store.unregister_blackboard(stage.bb)
		store.release_stage(stage)
		stage.free()
	return ok

func _test_cross_stage_route_validation() -> bool:
	var scanned_definitions: Array[StageDefinition] = CrossStageValidator._load_project_definitions()
	var configured_stage_found := scanned_definitions.any(func(definition: StageDefinition) -> bool:
		return definition.resource_path.ends_with("demo/stages/stage_01/stage_01.tres"))
	var source := StageDefinition.new()
	source.cross_stage_instance_ids = PackedStringArray(["sensor_source"])
	var input_field := PayloadFieldData.from_dictionary({
		"event_id": "launch", "key": "sensor_id", "type": "String"})
	var output_field := PayloadFieldData.from_dictionary({
		"event_id": "sensor:activated", "key": "sensor_id", "type": "String"})
	var target := StageDefinition.new()
	target.cross_stage_instance_ids = PackedStringArray(["sensor_west"])
	target.external_calls = PackedStringArray(["sensor:activated"])
	target.payload_fields = [output_field]
	var route := StepData.new()
	route.verb = &"emit_cross_stage"
	route.args = PackedStringArray([
		'&"sensor:activated"',
		'{"sensor_id": callboard_payload(&"sensor_id")}',
		'&"sensor_west"',
	])
	var rule := RuleData.new()
	rule.id = &"send_sensor_activation"
	rule.trigger = &"launch"
	rule.steps = [route]
	var data := GraphDraft.new()
	data.definition = source
	data.rules = [rule]
	data.external_calls = ["launch"]
	data.payload_fields = [input_field]
	var good_report: Dictionary = CrossStageValidator.validate(data, [target])
	var accepted_registered_route: bool = good_report.errors.is_empty() and good_report.warnings.is_empty()
	target.payload_fields = [PayloadFieldData.from_dictionary({
		"event_id": "sensor:activated", "key": "sensor_id", "type": "int"})]
	var bad_report: Dictionary = CrossStageValidator.validate(data, [target])
	var incompatible_payload_rejected: bool = bad_report.errors.any(
		func(problem: String) -> bool: return "expects int" in problem)
	route.args.remove_at(2)
	target.payload_fields = [output_field]
	var broadcast_report: Dictionary = CrossStageValidator.validate(data, [target])
	var broadcast_uses_declared_recipients: bool = broadcast_report.errors.is_empty()
	route.args.append('&"unregistered_sensor"')
	var missing_route_report: Dictionary = CrossStageValidator.validate(data, [target])
	var missing_route_is_actionable: bool = missing_route_report.errors.any(
		func(problem: String) -> bool: return "cross_stage_instance_ids" in problem)
	var saved_definition := RuleGraphReader.make_definition(data)
	var route_ids_survive_callboard_save := saved_definition.cross_stage_instance_ids == PackedStringArray(["sensor_source"])
	return _check("cross-Stage schema scanning discovers configured, unloaded StageDefinitions",
		configured_stage_found) \
		and _check("StageDefinition target IDs survive Callboard save preparation",
			route_ids_survive_callboard_save) \
		and _check("resource-only cross-Stage validation resolves registered targets and typed runtime payload references",
		accepted_registered_route) \
		and _check("resource-only cross-Stage validation catches destination schema mismatches",
			incompatible_payload_rejected) \
		and _check("resource-only cross-Stage validation checks all declared broadcast recipients",
			broadcast_uses_declared_recipients) \
		and _check("unregistered exact targets explain how to enable offline validation",
			missing_route_is_actionable)

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
	var restart_decisions: Array[Dictionary] = []
	engine.trace_event.connect(func(entry: Dictionary) -> void:
		if entry.get("kind") == "reentry_decision":
			restart_decisions.append(entry.duplicate(true)))
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
	var restart_trace_valid := restart_decisions.size() == 2
	for decision: Dictionary in restart_decisions:
		restart_trace_valid = restart_trace_valid and decision.get("decision") == "restart" \
			and decision.get("order") == 1 and decision.get("reentry_policy") == "Restart"
	var ok := _check("restart releases the old wait and starts the latest run immediately",
		starts == [1, 3] and engine.pending_snapshot().size() == 1
		and restart_trace_valid)
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
	var queue_decisions: Array[Dictionary] = []
	engine.trace_event.connect(func(entry: Dictionary) -> void:
		if entry.get("kind") == "reentry_decision":
			queue_decisions.append(entry.duplicate(true)))
	queued.steps.append(Step.new(func(c: Dictionary) -> void: received.append(c["id"])).after(1.0))
	engine.rules.append(queued)

	engine.fire(&"start", {"id": 1})
	var payload := {"id": 2}
	engine.fire(&"start", payload)
	payload["id"] = 99
	engine.fire(&"start", {"id": 3})
	clock_tick.emit()
	var ok := _check("queued triggers wait for the active run", received == [1])
	var queue_trace_valid := queue_decisions.size() == 2
	for decision: Dictionary in queue_decisions:
		queue_trace_valid = queue_trace_valid and decision.get("decision") == "queue" \
			and decision.get("order") == 1 and decision.get("trigger_rule_count") == 1 \
			and decision.get("reentry_policy") == "Queue"
	ok = _check("queued re-entry traces decisions and authored trigger order",
		queue_trace_valid) and ok
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

	var parallel_engine := RuleEngine.new(Blackboard.new(), {}, func(_seconds: float) -> Signal: return clock_tick)
	var serialized_group := StepData.new()
	serialized_group.verb = &"parallel"
	serialized_group.join_parallel = false
	var serialized_child := StepData.new()
	serialized_child.verb = &"say"
	serialized_child.args = PackedStringArray(["prop", "\"hello\""])
	var nested_group := StepData.new()
	nested_group.verb = &"parallel"
	var nested_child := StepData.new()
	nested_child.verb = &"score"
	nested_group.parallel_branches.append([nested_child])
	serialized_group.parallel_branches = [[serialized_child, nested_group], []]
	var restored_group := StepData.from_dictionary(serialized_group.to_dictionary())
	ok = _check("parallel StepData serializes join mode and recursively restores ordered branches",
		not restored_group.join_parallel and restored_group.parallel_branches.size() == 2
		and restored_group.parallel_branches[0].size() == 2
		and restored_group.parallel_branches[0][0].verb == &"say"
		and restored_group.parallel_branches[0][1].parallel_branches[0][0].verb == &"score"
		and restored_group.parallel_branches[1].is_empty()) and ok
	var serialized_conditional := StepData.new()
	serialized_conditional.verb = &"conditional"
	serialized_conditional.branch_conditions = [&"ready", &"count >= 2", &""]
	serialized_conditional.default_branch_index = 2
	serialized_conditional.parallel_branches = [[], [], []]
	var restored_conditional := StepData.from_dictionary(serialized_conditional.to_dictionary())
	ok = _check("conditional StepData preserves guard order and the explicit default branch",
		restored_conditional.branch_conditions.size() == 3
		and restored_conditional.branch_conditions[0] == &"ready"
		and restored_conditional.branch_conditions[1] == &"count >= 2"
		and restored_conditional.branch_conditions[2].is_empty()
		and restored_conditional.default_branch_index == 2
		and restored_conditional.parallel_branches.size() == 3) and ok
	var parallel_order: Array[String] = []
	var parallel_rule := Rule.new(&"parallel_join", &"parallel_start")
	var slow_branch: Array[Step] = [Step.new(func(_c: Dictionary) -> void:
		parallel_order.append("slow-start")),
		Step.new(func(_c: Dictionary) -> void: parallel_order.append("slow-end")).after(1.0)]
	var fast_branch: Array[Step] = [Step.new(func(_c: Dictionary) -> void:
		parallel_order.append("fast"))]
	parallel_rule.steps = [Step.parallel([slow_branch, fast_branch]),
		Step.new(func(_c: Dictionary) -> void: parallel_order.append("parent"))]
	parallel_engine.rules.append(parallel_rule)
	parallel_engine.fire(&"parallel_start")
	await process_frame
	var parallel_started_concurrently := parallel_order == ["slow-start", "fast"]
	clock_tick.emit()
	await process_frame
	await process_frame
	ok = _check("joined parallel branches start in authored order and parent resumes after all finish",
		parallel_started_concurrently and parallel_order == ["slow-start", "fast", "slow-end", "parent"]
		) and ok

	var detached_engine := RuleEngine.new(Blackboard.new(), {}, func(_seconds: float) -> Signal: return clock_tick)
	var detached_order: Array[String] = []
	var detached_rule := Rule.new(&"parallel_detached", &"detached_start")
	var detached_branch: Array[Step] = [Step.new(func(_c: Dictionary) -> void:
		detached_order.append("started")),
		Step.new(func(_c: Dictionary) -> void: detached_order.append("cancelled-work-ran")).after(1.0)]
	detached_rule.steps = [Step.parallel([detached_branch], false),
		Step.new(func(_c: Dictionary) -> void: detached_order.append("parent"))]
	detached_engine.rules.append(detached_rule)
	detached_engine.fire(&"detached_start")
	await process_frame
	var parent_did_not_join := detached_order == ["started", "parent"]
	detached_engine.cancel_all()
	clock_tick.emit()
	await process_frame
	ok = _check("unjoined branch remains run-owned and deactivation cancels its later steps",
		parent_did_not_join and detached_order == ["started", "parent"]
		) and ok

	bb.write(&"enabled", true)
	engine.fire(&"start", {"id": 6})
	engine.fire(&"start", {"id": 7})
	engine.cancel_all()
	engine.fire(&"start", {"id": 8})
	engine.fire(&"start", {"id": 9})
	clock_tick.emit()
	clock_tick.emit()
	ok = _check("deactivation drops pending triggers and leaves later runs intact",
		received == [1, 2, 3, 4, 8, 9]) and ok

	var ignore_engine := RuleEngine.new(Blackboard.new(), {}, func(_seconds: float) -> Signal: return clock_tick)
	var ignored_rule := Rule.new(&"ignored_reentry", &"ignore_start")
	ignored_rule.steps.append(Step.new(func(_context: Dictionary) -> void: pass).after(1.0))
	ignore_engine.rules.append(ignored_rule)
	var ignore_decisions: Array[Dictionary] = []
	ignore_engine.trace_event.connect(func(entry: Dictionary) -> void:
		if entry.get("kind") == "reentry_decision":
			ignore_decisions.append(entry.duplicate(true)))
	ignore_engine.fire(&"ignore_start")
	await process_frame
	ignore_engine.fire(&"ignore_start")
	var ignored_and_traced: bool = ignore_decisions.size() == 1 \
		and ignore_decisions[0].get("decision") == "ignore" \
		and ignore_decisions[0].get("reentry_policy") == "Ignore"
	ignore_engine.cancel_all()
	ok = _check("ignored re-entry is visible in the live trace", ignored_and_traced) and ok
	return ok

func _test_conditional_groups() -> bool:
	var bb := Blackboard.new()
	bb.define(&"ready", &"local", false)
	bb.define(&"count", &"local", 0)
	var engine := RuleEngine.new(bb, {}, Callable())
	var chosen: Array[String] = []
	var conditional := Step.conditional([&"ready", &"count >= 2", &""], [
		[Step.new(func(_c: Dictionary) -> void: chosen.append("ready"))],
		[Step.new(func(_c: Dictionary) -> void: chosen.append("quota"))],
		[Step.new(func(_c: Dictionary) -> void: chosen.append("default"))],
	], 2)
	var rule := Rule.new(&"conditional_route", &"choose")
	rule.steps = [conditional]
	engine.rules = [rule]
	var selections: Array[String] = []
	engine.trace_event.connect(func(entry: Dictionary) -> void:
		if entry.get("kind") == "branch_selected":
			selections.append(entry.get("detail", "")))
	bb.write(&"ready", true)
	engine.fire(&"choose")
	await process_frame
	await process_frame
	bb.write(&"ready", false)
	bb.write(&"count", 3)
	engine.fire(&"choose")
	await process_frame
	await process_frame
	bb.write(&"count", 0)
	engine.fire(&"choose")
	await process_frame
	await process_frame
	var selected_expected := chosen == ["ready", "quota", "default"] \
		and selections == ["branch=1; ready", "branch=2; count >= 2", "branch=3; Otherwise"]
	var missing_default := Step.conditional([&"ready"], [[Step.new()]], -1)
	var invalid_rule := Rule.new(&"missing_default", &"choose")
	invalid_rule.steps = [missing_default]
	var validation := RuleValidator.check([invalid_rule], bb, [&"choose"], [], {})
	var wrong_type_group := Step.conditional([&"count == true", &""], [[], []], 1)
	var wrong_type_rule := Rule.new(&"wrong_condition_type", &"choose")
	wrong_type_rule.steps = [wrong_type_group]
	var type_validation := RuleValidator.check([wrong_type_rule], bb, [&"choose"], [], {})
	var definition := StageDefinition.new()
	definition.external_calls = PackedStringArray(["choose"])
	var authored_rule := RuleData.new()
	authored_rule.id = &"authored_conditional"
	authored_rule.trigger = &"choose"
	var authored_group := StepData.new()
	authored_group.verb = &"conditional"
	authored_group.branch_conditions = [&"ready", &""]
	authored_group.default_branch_index = 1
	var first_branch := StepData.new()
	first_branch.verb = &"score"
	first_branch.args = PackedStringArray(["1"])
	var default_branch := StepData.new()
	default_branch.verb = &"score"
	default_branch.args = PackedStringArray(["2"])
	authored_group.parallel_branches = [[first_branch], [default_branch]]
	authored_rule.steps = [authored_group]
	definition.rules = [authored_rule]
	var compiled_stage := Stage.new()
	compiled_stage.definition = definition
	compiled_stage.build()
	var resource_compiles := compiled_stage.graph_errors.is_empty() \
		and compiled_stage.engine.rules[0].steps[0].verb == &"conditional"
	compiled_stage.free()
	return _check("conditional groups execute the first matching branch or Otherwise and trace the selection",
		selected_expected) and _check("conditional groups validate defaults and guard value types",
		validation.any(func(problem: String) -> bool: return "Otherwise branch" in problem)
		and type_validation.any(func(problem: String) -> bool: return "numeric Blackboard key and literal" in problem)) \
		and _check("StageDefinition compiles serialized conditional branches into runtime steps",
		resource_compiles)

func _test_random_groups() -> bool:
	var state: Dictionary = {}
	var selected: Array[String] = []
	var bb := Blackboard.new()
	var engine := RuleEngine.new(bb, {}, Callable())
	engine.random_group_states = state
	var noop := func(_context: Dictionary) -> void: pass
	var random_step := Step.random_choice([
		[Step.new(noop)], [Step.new(noop)], [Step.new(noop)],
	], PackedFloat32Array([1.0, 1.0, 1.0]), 4921, &"test_group")
	var rule := Rule.new(&"random_test", &"choose")
	rule.steps = [random_step]
	engine.rules = [rule]
	engine.trace_event.connect(func(entry: Dictionary) -> void:
		if entry.get("kind") == "branch_selected":
			selected.append(entry.get("detail", "")))
	for _i in 12:
		engine.fire(&"choose")
		await process_frame
		await process_frame
	var repeat_selected: Array[String] = []
	var repeat_engine := RuleEngine.new(Blackboard.new(), {}, Callable())
	var repeat_step := Step.random_choice([
		[Step.new(noop)], [Step.new(noop)], [Step.new(noop)],
	], PackedFloat32Array([1.0, 1.0, 1.0]), 4921, &"test_group")
	var repeat_rule := Rule.new(&"random_test", &"choose")
	repeat_rule.steps = [repeat_step]
	repeat_engine.random_group_states = {}
	repeat_engine.rules = [repeat_rule]
	repeat_engine.trace_event.connect(func(entry: Dictionary) -> void:
		if entry.get("kind") == "branch_selected":
			repeat_selected.append(entry.get("detail", "")))
	for _i in 12:
		repeat_engine.fire(&"choose")
		await process_frame
		await process_frame
	var weighted := Step.random_choice([[], [], []], PackedFloat32Array([0.0, 5.0, 0.0]),
		77, &"weighted_test", 1)
	var weighted_rule := Rule.new(&"weighted_test", &"choose")
	weighted_rule.steps = [weighted]
	var weighted_validation := RuleValidator.check([weighted_rule], Blackboard.new(),
		[&"choose"], [], {})
	var random_data := StepData.new()
	random_data.verb = &"random"
	random_data.group_id = &"stable_authoring_id"
	random_data.random_seed = -31
	random_data.random_selection = 1
	random_data.branch_weights = PackedFloat32Array([0.0, 4.5])
	random_data.parallel_branches = [[], []]
	var random_round_trip := StepData.from_dictionary(random_data.to_dictionary())
	var weighted_selected: Array[String] = []
	var weighted_engine := RuleEngine.new(Blackboard.new(), {}, Callable())
	weighted_engine.random_group_states = {}
	weighted_engine.rules = [weighted_rule]
	weighted_engine.trace_event.connect(func(entry: Dictionary) -> void:
		if entry.get("kind") == "branch_selected":
			weighted_selected.append(entry.get("detail", "")))
	weighted_engine.fire(&"choose")
	await process_frame
	await process_frame
	var store := StageStateStore.new()
	var first_stage := Stage.new()
	store.attach(first_stage, &"random_reload_test")
	first_stage.random_group_states[&"random:test_group"] = {"seed": 4921, "state": 123456}
	var retained_state: Dictionary = store.state_for(&"random_reload_test")["random_groups"]
	first_stage.free()
	var reloaded_stage := Stage.new()
	var restored: bool = store.attach(reloaded_stage, &"random_reload_test") \
		and reloaded_stage.random_group_states.get(&"random:test_group", {}).get("state", -1) == 123456
	reloaded_stage.free()
	return _check("seeded random groups replay the same uniform branch sequence", selected == repeat_selected) \
		and _check("random group resources preserve their seed, mode, weights, and stable ID",
			random_round_trip.group_id == &"stable_authoring_id"
			and random_round_trip.random_seed == -31 and random_round_trip.random_selection == 1
			and random_round_trip.branch_weights == PackedFloat32Array([0.0, 4.5])) \
		and _check("weighted random groups accept zero-weight paths and validate their configuration",
		weighted_validation.is_empty() and weighted.random_selection == 1
		and weighted_selected == ["branch=2; weighted"]) \
		and _check("managed Stage reload restores per-group random state", restored
		and retained_state.get(&"random:test_group", {}).get("state", -1) == 123456)

func _test_core_verb_branch_factories() -> bool:
	var bb := Blackboard.new()
	bb.define(&"knows_answer", &"local", false)
	bb.define(&"has_hint", &"local", false)
	var engine := RuleEngine.new(bb, {}, Callable())
	var verbs := CoreVerbs.new(StepContext.new(bb, engine, null, Callable()))
	var dialogue: Array[String] = []
	var conditional := verbs.branch_if([&"knows_answer", &"has_hint", &""], [
		[Step.new(func(_c: Dictionary) -> void: dialogue.append("answer"))],
		[Step.new(func(_c: Dictionary) -> void: dialogue.append("hint"))],
		[Step.new(func(_c: Dictionary) -> void: dialogue.append("ask"))],
	], 2)
	var dialogue_rule := Rule.new(&"dialogue_branch_api", &"dialogue")
	dialogue_rule.steps = [conditional]
	engine.rules = [dialogue_rule]
	bb.write(&"knows_answer", true)
	bb.write(&"has_hint", true)
	engine.fire(&"dialogue")
	await process_frame
	await process_frame
	bb.write(&"knows_answer", false)
	engine.fire(&"dialogue")
	await process_frame
	await process_frame
	bb.write(&"has_hint", false)
	engine.fire(&"dialogue")
	await process_frame
	await process_frame
	var dialogue_order_ok := dialogue == ["answer", "hint", "ask"] \
		and conditional.verb == &"conditional" \
		and conditional.branch_conditions == [&"knows_answer", &"has_hint", &""]

	var idle_engine := RuleEngine.new(Blackboard.new(), {}, Callable())
	var idle_verbs := CoreVerbs.new(StepContext.new(idle_engine.bb, idle_engine, null, Callable()))
	var idle_choices: Array[String] = []
	var idle_branches: Array[Array] = []
	for index in 8:
		var animation_name := "idle_%02d" % (index + 1)
		idle_branches.append([Step.new(func(_c: Dictionary) -> void:
			idle_choices.append(animation_name))])
	var idle_step := idle_verbs.choose_random(idle_branches, PackedFloat32Array(),
		28411, &"eight_idle_animations")
	var idle_rule := Rule.new(&"idle_animation_pool", &"idle")
	idle_rule.steps = [idle_step]
	idle_engine.rules = [idle_rule]
	for _i in 16:
		idle_engine.fire(&"idle")
		await process_frame
		await process_frame
	var replay_engine := RuleEngine.new(Blackboard.new(), {}, Callable())
	var replay_verbs := CoreVerbs.new(StepContext.new(replay_engine.bb, replay_engine, null, Callable()))
	var replay_choices: Array[String] = []
	var replay_branches: Array[Array] = []
	for index in 8:
		var animation_name := "idle_%02d" % (index + 1)
		replay_branches.append([Step.new(func(_c: Dictionary) -> void:
			replay_choices.append(animation_name))])
	var replay_rule := Rule.new(&"idle_animation_pool", &"idle")
	replay_rule.steps = [replay_verbs.choose_random(replay_branches, PackedFloat32Array(),
		28411, &"eight_idle_animations")]
	replay_engine.rules = [replay_rule]
	for _i in 16:
		replay_engine.fire(&"idle")
		await process_frame
		await process_frame
	var seen_idle_animations: Array[String] = []
	for animation_name in idle_choices:
		if not animation_name in seen_idle_animations:
			seen_idle_animations.append(animation_name)
	var idle_sequence_ok := idle_choices.size() == 16 and seen_idle_animations.size() == 8 \
		and idle_choices == replay_choices \
		and idle_choices.all(func(name: String) -> bool: return name in [
			"idle_01", "idle_02", "idle_03", "idle_04", "idle_05", "idle_06", "idle_07", "idle_08"])

	var cancel_engine := RuleEngine.new(Blackboard.new(), {}, func(_seconds: float) -> Signal: return clock_tick)
	var cancelled_branch_work: Array[String] = []
	var cancel_verbs := CoreVerbs.new(StepContext.new(cancel_engine.bb, cancel_engine, null, Callable()))
	var delayed_branch: Array[Array] = [[Step.new(func(_c: Dictionary) -> void:
		cancelled_branch_work.append("ran")).after(1.0)]]
	var cancel_rule := Rule.new(&"cancelled_script_branch", &"cancel_branch")
	cancel_rule.steps = [cancel_verbs.choose_random(delayed_branch, PackedFloat32Array(),
		77, &"cancelled_group")]
	cancel_engine.rules = [cancel_rule]
	cancel_engine.fire(&"cancel_branch")
	await process_frame
	cancel_engine.cancel_all()
	clock_tick.emit()
	await process_frame
	await process_frame
	return _check("CoreVerbs.branch_if routes conditional dialogue in authored first-match order",
		dialogue_order_ok) \
		and _check("CoreVerbs.choose_random reproducibly selects from eight ordered idle animation branches",
			idle_sequence_ok) \
		and _check("script-created random branches remain cancellable with their owning rule",
			cancelled_branch_work.is_empty())

func _test_async_stage_loading() -> bool:
	const SCENE := "res://addons/callboard/tests/fixtures/assigned_prop_stage.tscn"
	var store := StageStateStore.new()
	var parent := Node.new()
	root.add_child(parent)
	var timings: Dictionary = {}
	store.stage_load_profiled.connect(func(id: StringName, resource: int, instantiate: int, attach: int) -> void:
		timings[id] = [resource, instantiate, attach])
	store.state_for(&"first")["saved"][&"marker"] = 17

	var cancelled: Array[Stage] = []
	var start_cancelled := func() -> void:
		cancelled.append(await store.load_stage_async(SCENE, &"first", parent))
	start_cancelled.call()
	var duplicate := await store.load_stage_async(SCENE, &"first", parent)
	var ok := _check("pending Stage loads reserve the stable ID before yielding",
		duplicate == null and parent.get_child_count() == 0
		and store.cancel_stage_load(&"first") and not store.cancel_stage_load(&"first"))

	# Retry the cancelled ID immediately and share one path with another instance.
	var concurrent: Array[Stage] = []
	var start_neighbor := func() -> void:
		concurrent.append(await store.load_stage_async(SCENE, &"neighbor", parent))
	start_neighbor.call()
	var stage := await store.load_stage_async(SCENE, &"first", parent)
	var deadline := Time.get_ticks_msec() + 5000
	while concurrent.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	ok = _check("cancellation leaves the replacement and concurrent same-path load intact",
		cancelled == [null] and concurrent.size() == 1 and concurrent[0] != null
		and stage != null and stage != concurrent[0] and parent.get_child_count() == 2) and ok
	ok = _check("asynchronous attachment injects state and reports each phase",
		stage != null and stage.is_built and stage.saved_vars.get(&"marker") == 17
		and timings.has(&"first") and timings.has(&"neighbor")) and ok
	var loaded_duplicate := await store.load_stage_async(SCENE, &"first", parent)
	ok = _check("an already loaded Stage ID is rejected", loaded_duplicate == null) and ok

	var missing := await store.load_stage_async("res://nonexistent.tscn", &"retry", parent)
	var prewarmed := await store.prewarm_stage_scene(SCENE, self)
	ok = _check("a missing scene creates no state, and prewarming creates no instance",
		missing == null and not store.stage_states.has(&"retry")
		and prewarmed != null and parent.get_child_count() == 2) and ok
	var retry := store.load_stage(prewarmed, &"retry", parent)
	ok = _check("a failed request releases its ID for a prewarmed load", retry != null) and ok

	var departing := Node.new()
	root.add_child(departing)
	var abandoned: Array[Stage] = []
	var start_abandoned := func() -> void:
		abandoned.append(await store.load_stage_async(SCENE, &"departing", departing))
	start_abandoned.call()
	departing.free()
	await process_frame
	ok = _check("a freed parent cancels mounting and releases the reservation",
		abandoned == [null] and not store.stage_states.has(&"departing")
		and not store.cancel_stage_load(&"departing")) and ok
	parent.queue_free()
	await process_frame
	return ok

func _check(label: String, condition: bool) -> bool:
	print(("  ok   " if condition else "  FAIL ") + label)
	return condition

func _expect_error(message_fragment: String) -> void:
	print("CALLBOARD_EXPECTED_DIAGNOSTIC:ERROR:", message_fragment)
