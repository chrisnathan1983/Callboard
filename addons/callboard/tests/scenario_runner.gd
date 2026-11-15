extends RefCounted
## Runs declarative Callboard scenarios against a built Stage.

const ScenarioClockScript := preload("res://addons/callboard/tests/scenario_clock.gd")

static func create_stage(definition: StageDefinition, clock: RefCounted = null) -> Dictionary:
	if definition == null:
		return {"ok": false, "error": "Scenario requires a StageDefinition."}
	var stage := definition.instantiate()
	if stage == null:
		return {"ok": false, "error": "StageDefinition could not instantiate its Stage script."}
	stage.build()
	if not stage.graph_errors.is_empty():
		var graph_errors := stage.graph_errors.duplicate()
		stage.free()
		return {"ok": false, "error": "Stage graph failed to build: %s" % "; ".join(graph_errors)}
	if clock != null:
		stage.engine.wait = clock.wait
	return {"ok": true, "stage": stage, "clock": clock}

## Actions are Dictionaries with an `action` key. Supported actions:
## activate, deactivate, call, advance, frames, assert, teardown.
## Assertion dictionaries support var, latch, trace_count, rule_covered, and branch_covered.
static func run(stage: Stage, actions: Array[Dictionary], clock: RefCounted = null) -> Dictionary:
	var result := {
		"ok": true,
		"errors": [],
		"trace": [],
		"rule_coverage": {},
		"branch_coverage": {},
		"gameplay_outcomes": [],
		"torn_down": false,
	}
	if stage == null or not is_instance_valid(stage) or not stage.is_built or stage.engine == null:
		return _fail(result, "Scenario requires a built Stage.")
	if clock != null:
		stage.engine.wait = clock.wait
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return _fail(result, "Scenario runner requires a SceneTree main loop.")
	var trace: Array = result["trace"]
	var rules: Dictionary = result["rule_coverage"]
	var branches: Dictionary = result["branch_coverage"]
	var gameplay_outcomes: Array = result["gameplay_outcomes"]
	var on_trace := func(entry: Dictionary) -> void:
		trace.append(entry.duplicate(true))
		if entry.get("kind") == "rule_started":
			rules[StringName(entry.get("rule", ""))] = true
		if entry.get("kind") == "branch_selected":
			var group := StringName("%s:%d" % [entry.get("rule", ""), entry.get("step", 0)])
			var branch := _branch_number(String(entry.get("detail", "")))
			if branch > 0:
				if not branches.has(group):
					branches[group] = {}
				branches[group][branch] = true
	var on_gameplay_outcome := func(request_id: int, event_id: StringName,
			outcome: StringName, data: Dictionary) -> void:
		gameplay_outcomes.append({"request_id": request_id, "event_id": event_id,
			"outcome": outcome, "data": data.duplicate(true)})
	stage.engine.trace_event.connect(on_trace)
	stage.gameplay_request_finished.connect(on_gameplay_outcome)
	for index in actions.size():
		var step: Dictionary = actions[index]
		match StringName(step.get("action", "")):
			&"activate":
				stage.activate()
			&"deactivate":
				stage.deactivate()
			&"call":
				stage.fire(StringName(step.get("event", "")), step.get("payload", {}).duplicate(true))
			&"host":
				var callback: Callable = step.get("callback", Callable())
				if callback.is_valid():
					callback.call(stage, step.get("arguments", {}).duplicate(true))
				else:
					_fail(result, "Host action %d requires a valid callback." % (index + 1))
			&"advance":
				if clock == null or not stage.engine.advance_test_time(float(step.get("seconds", 0.0))):
					_fail(result, "Action %d advances time but no advanceable clock was supplied." % (index + 1))
				else:
					await _frames(tree, int(step.get("frames", 2)))
			&"frames":
				await _frames(tree, int(step.get("count", 1)))
			&"assert":
				_assert(stage, step, result)
			&"teardown":
				stage.deactivate()
				await _frames(tree, int(step.get("frames", 2)))
				if clock != null and clock.has_method("cancel_all"):
					clock.call("cancel_all")
				result["torn_down"] = true
			_:
				_fail(result, "Unknown scenario action '%s' at index %d." % [step.get("action", ""), index + 1])
	stage.engine.trace_event.disconnect(on_trace)
	stage.gameplay_request_finished.disconnect(on_gameplay_outcome)
	return result

static func _assert(stage: Stage, assertion: Dictionary, result: Dictionary) -> void:
	var kind := StringName(assertion.get("check", ""))
	var passed := false
	var detail := ""
	match kind:
		&"var":
			var key := StringName(assertion.get("key", ""))
			passed = stage.bb.has(key) and stage.get_var(key) == assertion.get("equals")
			detail = "Blackboard '%s' expected %s, got %s." % [key, assertion.get("equals"), stage.get_var(key) if stage.bb.has(key) else "<undeclared>"]
		&"latch":
			var rule_id := StringName(assertion.get("rule", ""))
			var latch_key := rule_id
			for rule: Rule in stage.engine.rules:
				if rule.id == rule_id:
					latch_key = rule.latch_key()
					break
			passed = stage.fired.get(latch_key, false) == bool(assertion.get("equals", true))
			detail = "One-shot latch '%s' expected %s." % [rule_id, assertion.get("equals", true)]
		&"pending_remaining":
			var pending := stage.engine.pending_snapshot()
			var found := false
			var actual := -1.0
			for entry: Dictionary in pending:
				if entry.get("rule") == str(assertion.get("rule", "")):
					found = true
					actual = float(entry.get("remaining", -1.0))
					break
			var expected := float(assertion.get("equals", 0.0))
			passed = found and is_equal_approx(actual, expected)
			detail = "Pending wait for '%s' expected %.2fs remaining, got %.2fs." % [assertion.get("rule", ""), expected, actual]
		&"trace_count":
			var matches := 0
			for entry: Dictionary in result["trace"]:
				if entry.get("kind") == assertion.get("kind") \
						and (not assertion.has("rule") or entry.get("rule") == str(assertion["rule"])):
					matches += 1
			passed = matches == int(assertion.get("equals", 0))
			detail = "Trace kind '%s' expected %d entries, got %d." % [assertion.get("kind"), assertion.get("equals", 0), matches]
		&"gameplay_outcome":
			var matches := 0
			for outcome: Dictionary in result["gameplay_outcomes"]:
				if outcome.get("event_id") == StringName(assertion.get("event_id", "")) \
						and outcome.get("outcome") == StringName(assertion.get("outcome", "")):
					matches += 1
			passed = matches == int(assertion.get("count", 1))
			detail = "Gameplay outcome '%s' for '%s' expected %d occurrences, got %d." % [assertion.get("outcome", ""), assertion.get("event_id", ""), assertion.get("count", 1), matches]
		&"rule_covered":
			passed = result["rule_coverage"].has(StringName(assertion.get("rule", ""))) == bool(assertion.get("equals", true))
			detail = "Rule coverage for '%s' did not match expectation." % assertion.get("rule", "")
		&"branch_covered":
			var group := StringName(assertion.get("group", ""))
			var branch := int(assertion.get("branch", 0))
			var covered: bool = result["branch_coverage"].get(group, {}).has(branch)
			passed = covered == bool(assertion.get("equals", true))
			detail = "Branch %d coverage for '%s' did not match expectation." % [branch, group]
		_:
			_fail(result, "Unknown assertion check '%s'." % kind)
			return
	if not passed:
		_fail(result, detail)

static func _branch_number(detail: String) -> int:
	var regex := RegEx.new()
	if regex.compile("branch=([0-9]+)") != OK:
		return 0
	var found := regex.search(detail)
	return int(found.get_string(1)) if found != null else 0

static func _frames(tree: SceneTree, count: int) -> void:
	for _frame in maxi(1, count):
		await tree.process_frame

static func _fail(result: Dictionary, message: String) -> Dictionary:
	result["ok"] = false
	result["errors"].append(message)
	return result
