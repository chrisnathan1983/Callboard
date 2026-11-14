@tool
class_name CoreVerbs extends RefCounted
## Blackboard writes, scoring and repeatable relays.

var context: StepContext

func _init(p_context: StepContext) -> void:
	context = p_context

func set_var(key: StringName, value: Variant = true) -> Step:
	var bb := context.bb
	var step := Step.new(func(c: Dictionary) -> void: bb.write(key, value, _rule_writer(c)))
	step.sets = [key]
	return step

## Add to a declared numeric Blackboard value when this step executes.
func add_var(key: StringName, delta: float) -> Step:
	var bb := context.bb
	var step := Step.new(func(_c: Dictionary) -> void:
		var resolved := bb.resolve_key(key)
		if not bb.schema.has(resolved):
			push_warning("Callboard add_var skipped: Blackboard key '%s' is not declared." % key)
			return
		var key_type: int = bb.schema[resolved].get("type", TYPE_NIL)
		if key_type == TYPE_INT:
			if not is_equal_approx(delta, roundf(delta)):
				push_warning("Callboard add_var skipped: fractional delta for integer key '%s'." % key)
				return
			bb.write(key, int(bb.get_var(key)) + int(delta), _rule_writer(_c))
		elif key_type == TYPE_FLOAT:
			bb.write(key, float(bb.get_var(key)) + delta, _rule_writer(_c))
		else:
			push_warning("Callboard add_var skipped: Blackboard key '%s' must be int or float." % key))
	step.reads = [key]
	step.sets = [key]
	return step

func _rule_writer(context_data: Dictionary) -> StringName:
	var callboard: Dictionary = context_data.get("_callboard", {})
	var rule: Rule = callboard.get("rule") as Rule
	return StringName("rule:" + String(rule.id)) if rule != null else &"rule"

func score(points: int) -> Step:
	var emit_score := context.score
	return Step.new(func(_c: Dictionary) -> void: emit_score.call(points))

## Stops when the running rule is cancelled or its engine deactivates.
func repeat_emit(interval: float, tick: StringName) -> Step:
	var ctx := context
	var run := func(c: Dictionary) -> void:
		var callboard: Dictionary = c["_callboard"]
		var rule: Rule = callboard["rule"]
		var authored_payload: Dictionary = c["payload"]
		var engine := ctx.engine_ref.get_ref() as RuleEngine
		if not engine:
			return
		var gen := engine.token()
		while engine.alive(rule, gen):
			var timeout := engine.interruptible(engine.wait_tracked(interval, rule.id, "repeat_emit loop"))
			engine = null
			await timeout
			engine = ctx.engine_ref.get_ref() as RuleEngine
			if not engine or not engine.alive(rule, gen):
				return
			engine.fire("relay:" + tick, authored_payload)
	var step := Step.new(run)
	step.emits = tick
	step.emit_arg = 1
	return step
