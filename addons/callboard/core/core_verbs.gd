@tool
class_name CoreVerbs extends RefCounted
## Blackboard writes, scoring and repeatable relays.

var context: StepContext

func _init(p_context: StepContext) -> void:
	context = p_context

func set_var(key: StringName, value: Variant = true) -> Step:
	var bb := context.bb
	var step := Step.new(func(_c: Dictionary) -> void: bb.write(key, value))
	step.sets = [key]
	return step

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
