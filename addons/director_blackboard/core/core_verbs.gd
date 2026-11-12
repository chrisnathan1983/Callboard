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
		var rule: Rule = c["_rule"]
		var engine := ctx.engine_ref.get_ref() as RuleEngine
		if not engine:
			return
		var gen := engine.token()
		while engine.alive(rule, gen):
			engine = null
			await ctx.wait.call(interval)
			engine = ctx.engine_ref.get_ref() as RuleEngine
			if not engine or not engine.alive(rule, gen):
				return
			engine.fire("relay:" + tick, c)
	var step := Step.new(run)
	step.emits = tick
	step.emit_arg = 1
	return step
