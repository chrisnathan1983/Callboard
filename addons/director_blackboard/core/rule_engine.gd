@tool
class_name RuleEngine extends RefCounted

signal rule_fired(rule_id: StringName, event: StringName)

var rules: Array[Rule] = []
var fired: Dictionary                 # injected, latches `once`
var bb: Blackboard
var wait: Callable                    # func(seconds: float) -> Signal; tests swap this
var _gen := 0

func _init(p_bb: Blackboard, p_fired: Dictionary, p_wait: Callable) -> void:
	bb = p_bb
	fired = p_fired
	wait = p_wait

func token() -> int: return _gen
func cancel_all() -> void: _gen += 1

func fire(event: StringName, ctx := {}) -> void:
	var gen := _gen
	for r in rules:
		if gen != _gen:
			return
		if r.trigger == event and passes(r):
			_run(r, event, ctx)

func _run(r: Rule, event: StringName, ctx: Dictionary) -> void:
	var gen := _gen
	if r.once:
		fired[r.latch_key()] = true
	rule_fired.emit(r.id, event)
	if gen != _gen:
		return
	var c := ctx.merged({"_rule": r}, true)
	for s in r.steps:
		if s.delay > 0.0:
			await wait.call(s.delay)
			if not alive(r, gen): return
		await s.fn.call(c)
		if not alive(r, gen): return
	if r.emits != &"":
		fire("relay:" + r.emits, ctx)

func passes(r: Rule) -> bool:
	if r.once and fired.has(r.latch_key()): return false
	return r.requires.all(bb.is_set) and not r.forbids.any(bb.is_set)

func alive(r: Rule, gen: int) -> bool:
	return gen == _gen and not r.cancel_if.any(bb.is_set)
