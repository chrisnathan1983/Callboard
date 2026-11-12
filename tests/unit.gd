extends SceneTree
## Deterministic parser, validator, router and clock-injection tests.

func _initialize() -> void:
	var ok := true

	var source := """extends Zone
func _build_blackboard() -> void:
	define_local(&"armed", false)   # local note

func _build_rules() -> void:
	# @group: "Flow" rect=Rect2(10, 20, 600, 300)
	var r: Rule
	# @node: pos=Vector2(80, 90) group="Flow"
	r = rule(&"first", &"arrive")
	r.requires = [&"armed"]
	r.once = true
	r.emits = &"done"
	r.steps = [
		say(guard, "hello, world", 1.0).after(0.25),
	]
"""
	var parsed := ZoneSource.parse(source)
	var generated := ZoneSource.generate(source, parsed)
	var reparsed := ZoneSource.parse(generated)
	ok = _check("ZoneSource parses round-trip fixture", parsed["ok"] and reparsed["ok"]) and ok
	ok = _check("ZoneSource round-trips vars, groups and rules",
		reparsed["vars"] == parsed["vars"]
		and reparsed["groups"] == parsed["groups"]
		and reparsed["rules"] == parsed["rules"]) and ok
	ok = _check("ZoneSource generation is stable",
		ZoneSource.generate(generated, reparsed) == generated) and ok

	var bb := Blackboard.new()
	bb.define(&"lamp_on", &"local", false)

	var cycle_a := Rule.new(&"loop_a", &"relay:a")
	var cycle_step := Step.new()
	cycle_step.emits = &"b"
	cycle_a.steps.append(cycle_step)
	var cycle_b := Rule.new(&"loop_b", &"relay:b")
	cycle_b.emits = &"a"
	var cycle_rules: Array[Rule] = [cycle_a, cycle_b]
	var cycle_problems := RuleValidator.validate(
		cycle_rules, bb, [&"relay:a", &"relay:b"], [])
	ok = _check("validator detects relay cycles",
		cycle_problems.any(func(p): return "relay cycle" in p and "'loop_a'" in p and "'loop_b'" in p)) and ok

	var shared_a := Rule.new(&"shared_a", &"alarm")
	var shared_b := Rule.new(&"shared_b", &"alarm")
	var shared_rules: Array[Rule] = [shared_a, shared_b]
	var shared_problems := RuleValidator.validate(shared_rules, bb, [&"alarm"], [])
	ok = _check("validator flags potentially overlapping shared triggers",
		shared_problems.any(func(p): return "share trigger 'alarm'" in p)) and ok

	var exclusive_a := Rule.new(&"exclusive_a", &"alarm")
	exclusive_a.requires = [&"lamp_on"]
	var exclusive_b := Rule.new(&"exclusive_b", &"alarm")
	exclusive_b.forbids = [&"lamp_on"]
	var exclusive_rules: Array[Rule] = [exclusive_a, exclusive_b]
	var exclusive_problems := RuleValidator.validate(
		exclusive_rules, bb, [&"alarm"], [&"lamp_on"])
	ok = _check("validator accepts mutually exclusive shared triggers",
		not exclusive_problems.any(func(p): return "share trigger 'alarm'" in p)) and ok

	var route_bb := Blackboard.new()
	route_bb.define(&"armed", &"local", false)
	route_bb.define(&"blocked", &"local", false)
	route_bb.define(&"cancelled", &"local", false)
	var zone := Zone.new()
	zone.bb = route_bb
	var guarded := zone.rule(&"guarded", &"attempt")
	guarded.requires = [&"armed"]
	guarded.forbids = [&"blocked"]
	guarded.cancel_if = [&"cancelled"]
	guarded.once = true
	var fired: Array[StringName] = []
	zone.rule_fired.connect(func(id: StringName, _event: StringName) -> void: fired.append(id))

	zone.fire(&"attempt")
	route_bb.write(&"armed", true)
	route_bb.write(&"blocked", true)
	zone.fire(&"attempt")
	route_bb.write(&"blocked", false)
	zone.fire(&"attempt")
	zone.fire(&"attempt")
	ok = _check("router applies requires, forbids and once guards",
		fired == [&"guarded"] and zone.fired.has(&"guarded")) and ok
	ok = _check("router honors cancel_if while a rule is alive", zone.alive(guarded, 0)) and ok
	route_bb.write(&"cancelled", true)
	ok = _check("router cancels a rule after cancel_if is set", not zone.alive(guarded, 0)) and ok
	zone.free()

	var wait_requests: Array[float] = []
	var fake_wait := func(seconds: float) -> Signal:
		wait_requests.append(seconds)
		return process_frame
	var engine_bb := Blackboard.new()
	var state := {"step_ran": false}
	var engine := RuleEngine.new(engine_bb, {}, fake_wait)
	var delayed := Rule.new(&"delayed", &"go")
	var delayed_step := Step.new(func(_ctx: Dictionary) -> void: state["step_ran"] = true)
	delayed_step.delay = 12.5
	delayed.steps.append(delayed_step)
	engine.rules.append(delayed)
	engine.fire(&"go")
	var delay_was_injected: bool = wait_requests == [12.5] and not state["step_ran"]
	for _frame in 3:
		await process_frame
	ok = _check("RuleEngine delay uses injected, non-realtime wait",
		delay_was_injected and state["step_ran"]) and ok

	print("UNIT: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)

func _check(label: String, condition: bool) -> bool:
	print(("  ok   " if condition else "  FAIL ") + label)
	return condition
